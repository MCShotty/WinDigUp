"use strict";
const {chromium}=require("playwright"),assert=require("node:assert/strict"),fs=require("node:fs");
const {setup}=require("./application-fixtures.cjs");
const base=process.env.DIGUP_UI_URL||"http://127.0.0.1:8765";
let browser;
(async()=>{
  browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||"/usr/bin/chromium",headless:true,args:["--no-sandbox"]});
  const page=await browser.newPage({viewport:{width:660,height:800}}),errors=[];
  page.on("pageerror",error=>errors.push(error.message));await setup(page);
  await page.addInitScript(()=>{
    const old=window.__TAURI__.core.invoke,time=Date.now()/1000;
    window.personalization={version:1,enabled:true,entries:3};
    window.activityMode="indexing";window.activityPaused=false;
    window.holdSettings=false;window.settingsWaiters=[];
    window.sourceDrive={version:2,supported:true,catalogEnabled:true,options:{enabled:true,paused:false,revision:1,volumes:["volume-a"],included:[],hidden:[]},
      volumes:[{id:"volume-a",name:"Local SSD",paths:["C:\\"],filesystem:"NTFS",available:true},
        {id:"volume-b",name:"Offline backup",paths:["E:\\"],filesystem:"NTFS",available:false}],
      volumeCatalog:{state:"ready",revision:1},running:true,progress:{phase:"enumerating",volume:"volume-a"},
      byVolume:{"volume-a":{phase:"enumerating",records:443831,candidates:107857,accepted:663}}};
    window.windowsCatalog={supported:true,enabled:true,semanticEnabled:true,ordinarySearches:true,count:38};
    window.telemetry={schemaVersion:1,state:"unavailable",utilizationPercent:null,memoryUsedBytes:null,memoryTotalBytes:null,message:"Provider not available"};
    window.__TAURI__.core.invoke=async(command,args={})=>{
      if(command==="settings_info"){const snapshot={...await old(command,args),personalization:window.personalization,discovery:sourceDrive,
        windowsSettings:windowsCatalog,windowsSettingsSemantic:{state:"ready",embedded:38,total:38},
        acceleration:{backend:"amd-vulkan",jobs:2,resourceProfile:"balanced",gpu:"fixture-device"},folders:["C:\\"]};
        if(window.holdSettings){const held=structuredClone(snapshot);return new Promise(resolve=>settingsWaiters.push(()=>resolve(held)));}
        return snapshot;
      }
      if(command==="activity_snapshot"){
        const reply=await old(command,args);
        reply.files={...reply.files,schemaVersion:2,phase:window.activityMode,paused:window.activityPaused,knownFiles:83,searchable:17,pending:66,total:100,done:17,
          discoveryActive:true,entriesChecked:443831,candidates:107857,candidatesFinal:false,lastProgressAt:time};
        reply.discovery=structuredClone(sourceDrive);reply.windowsSettings={catalog:windowsCatalog,purpose:{state:"ready"}};
        reply.inference.configured={backend:"amd-vulkan",jobs:2,resourceProfile:"balanced"};
        reply.inference.telemetry=structuredClone(window.telemetry);
        if(window.activityMode==="unavailable"){reply.inference.error="Fixture accelerator unavailable";reply.inference.encoder="unavailable";}
        return reply;
      }
      if(["refresh_discovery_volumes","discovery_candidates","set_discovery_options","set_windows_settings_options","set_personalization","clear_personalization","set_acceleration","index_folder_first"].includes(command)){
        calls.push({command,args});
        if(command==="refresh_discovery_volumes")return structuredClone(sourceDrive);
        if(command==="discovery_candidates")return {generation:args.generation,hits:[],total:0,catalogTotal:0};
        if(command==="set_discovery_options"){sourceDrive.options=args.options;return structuredClone(sourceDrive);}
        if(command==="set_windows_settings_options"){Object.assign(windowsCatalog,args.options);return structuredClone(windowsCatalog);}
        if(command==="set_personalization"){personalization.enabled=args.enabled;return structuredClone(personalization);}
        if(command==="clear_personalization"){personalization.entries=0;return structuredClone(personalization);}
        if(command==="index_folder_first")return {queued:true,active:false};
        return {};
      }
      return old(command,args);
    };
  });
  await page.goto(base+"/settings.html?tab=drives");
  await page.locator("#drives").waitFor({state:"visible"});
  const first=page.locator("#drive-volumes .source-volume").first();
  assert.match(await first.innerText(),/Whole drive selected for files/);
  assert.match(await first.innerText(),/443,831 entries checked/);
  const choice=first.locator('input[data-source="applications"]');
  await choice.focus();await page.keyboard.press("Space");
  assert.match(await first.innerText(),/Unsaved choices/);
  await page.evaluate(()=>{window.originalDrive=document.querySelector("#drive-volumes .source-volume");sourceDrive.byVolume["volume-a"].records++;emit("discovery",structuredClone(sourceDrive));});
  assert.equal(await first.evaluate(node=>node===window.originalDrive),true);
  assert.equal(await choice.evaluate(node=>node===document.activeElement),true);
  assert.equal(await choice.isChecked(),false);
  await page.locator("#drive-revert").click();assert.equal(await choice.isChecked(),true);
  await first.getByRole("button",{name:/View activity/}).click();
  await page.waitForFunction(()=>document.activeElement?.classList.contains("pipeline-drive-name")&&document.activeElement.textContent.includes("Local SSD"));
  assert.equal(await page.locator("#activity").isVisible(),true);
  assert.match(await page.locator('[data-key="phase"]').innerText(),/Discovering and indexing/);
  assert.equal(await page.locator(".activity-stages [aria-current=step]").count(),1);
  assert.match(await page.locator(".activity-stages").getAttribute("aria-label"),/overlap/);
  assert.equal(await page.locator('[data-key="meter"]').getAttribute("aria-valuenow"),null);
  assert.match(await page.locator('[data-key="progress-label"]').innerText(),/not known/);
  await page.locator('[data-key="file-details"] > summary').click();
  assert.equal(await page.locator('[data-key="known-files"]').innerText(),"83");
  assert.equal(await page.locator('[data-key="searchable"]').innerText(),"17");
  await page.evaluate(()=>{activityMode="discovering";emit("helper",{});});
  await page.waitForFunction(()=>document.querySelector('[data-key="phase"]').textContent==="Discovering files");
  assert.equal(await page.locator(".activity-stages .current").count(),1,"Discovery alone must not claim inference");
  await page.evaluate(()=>{activityMode="unavailable";emit("helper",{});});
  await page.waitForFunction(()=>document.querySelector('[data-key="phase"]').textContent==="Discovering file names");
  assert.match(await page.locator('[data-key="explanation"]').innerText(),/waiting for the selected accelerator/);
  await page.evaluate(()=>{activityMode="paused";activityPaused=true;emit("helper",{});});
  await page.waitForFunction(()=>document.querySelector('[data-key="phase"]').textContent==="Indexing paused");
  assert.equal(await page.locator(".activity-stages").isVisible(),false);
  await page.evaluate(()=>{activityMode="indexing";activityPaused=false;emit("helper",{});});
  await page.waitForFunction(()=>document.querySelector('[data-key="phase"]').textContent==="Discovering and indexing files");
  assert.match(await page.locator(".pipeline-device-measurements").innerText(),/Device utilization not reported/);
  assert.ok(!(await page.locator(".pipeline-device-measurements").innerText()).includes("0%"));
  await page.evaluate(()=>{telemetry={schemaVersion:1,state:"ready",source:"Synthetic UI fixture",deviceId:"fixture-device",scope:"device",
    intervalMs:1000,utilizationPercent:37.2,memoryUsedBytes:1073741824,memoryTotalBytes:8589934592};emit("helper",{});});
  await page.waitForFunction(()=>document.querySelector(".pipeline-device-measurements").textContent.includes("37%"));
  assert.match(await page.locator(".pipeline-device-measurements").innerText(),/include other applications/);
  await page.locator('[data-key="windows-settings"]').click();
  assert.equal(await page.locator("#windows-settings").isVisible(),true);
  assert.equal(await page.locator("#apps").isVisible(),false);
  assert.equal(await page.locator("#win-settings-prepare").isDisabled(),true);
  await page.locator("#win-settings-ordinary").uncheck();
  await page.waitForFunction(()=>calls.some(call=>call.command==="set_windows_settings_options"));
  await page.getByRole("tab",{name:"Drives",exact:true}).click();
  await page.locator("#open-app-review").click();assert.equal(await page.locator("#executable-review").isVisible(),true);
  await page.waitForFunction(()=>document.querySelector("#drive-list-state").textContent.includes("No executables"));
  await page.locator("#review-drive-settings").click();assert.equal(await page.locator("#drives").isVisible(),true);
  await page.getByRole("tab",{name:"General",exact:true}).click();
  await page.evaluate(()=>{holdSettings=true;window.dispatchEvent(new Event("focus"));});
  await page.waitForFunction(()=>settingsWaiters.length>0);
  await page.locator("#personalization-enabled").uncheck();
  await page.waitForFunction(()=>calls.some(call=>call.command==="set_personalization"));
  await page.evaluate(()=>{holdSettings=false;settingsWaiters.splice(0).forEach(resolve=>resolve());});await page.waitForTimeout(100);
  assert.equal(await page.locator("#personalization-enabled").isChecked(),false,"An older focus refresh reverted the preference");
  await page.locator("#clear-personalization").click();
  await page.waitForFunction(()=>document.querySelector("#personalization-status").textContent.includes("cleared"));
  assert.equal(await page.locator("#clear-personalization").isDisabled(),true);
  await page.locator("#resource-profile").selectOption("quiet");
  await page.evaluate(()=>window.dispatchEvent(new Event("focus")));await page.waitForTimeout(100);
  assert.equal(await page.locator("#resource-profile").inputValue(),"quiet");
  assert.equal(await page.locator("#gpu-jobs").inputValue(),"2");
  await page.locator("#accelerator").selectOption("openvino-npu");
  assert.equal(await page.locator("#resource-profile").isDisabled(),true);
  assert.equal(await page.locator("#resource-profile").inputValue(),"quiet");
  await page.locator("#accelerator").selectOption("amd-vulkan");
  assert.equal(await page.locator("#resource-profile").isEnabled(),true);
  await page.locator("#apply-accelerator").click();
  const sent=await page.evaluate(()=>calls.find(call=>call.command==="set_acceleration").args.acceleration);
  assert.equal(sent.resourceProfile,"quiet");assert.equal(sent.jobs,2);
  const general=page.getByRole("tab",{name:"General",exact:true});await general.focus();await page.keyboard.press("ArrowRight");
  assert.equal(await page.locator("#folders").isVisible(),true);
  assert.equal(await page.locator('[role="tab"][aria-selected="true"]').evaluate(node=>node===document.activeElement),true);
  await page.locator("#folder-rows .folder-priority").first().click();
  await page.waitForFunction(()=>document.querySelector("#folder-priority-status").textContent.includes("Pause and schedule"));
  assert.deepEqual(await page.evaluate(()=>calls.find(call=>call.command==="index_folder_first").args),{path:"C:"+String.fromCharCode(92),code:false});
  assert.equal(await page.locator("#toggle-preview").count(),0);
  await page.evaluate(()=>{const label=document.createElement("p");label.className="note";label.textContent="Synthetic UI fixture. No hardware measurements.";
    label.style.cssText="position:fixed;bottom:0;right:0;background:var(--surface);color:var(--text);z-index:50;padding:4px 8px;margin:0";document.body.append(label);});
  for(const [theme,width]of [["light",660],["dark",660],["light",520]]){
    await page.emulateMedia({colorScheme:theme});await page.setViewportSize({width,height:800});
    for(const tab of ["drives","windows-settings","executable-review"]){
      await page.evaluate(tab=>showTab(tab),tab);
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),tab+" overflow at "+width);
      if(process.env.DIGUP_EXPERIENCE_SCREENSHOT_LOG&&theme==="light"&&width===660)
        console.log("EXPERIENCE_SCREENSHOT_"+tab+"="+(await page.screenshot({type:"jpeg",quality:65})).toString("base64"));
      if(process.env.DIGUP_ACTIVITY_SCREENSHOTS){
        fs.mkdirSync(process.env.DIGUP_ACTIVITY_SCREENSHOTS,{recursive:true});
        await page.screenshot({path:process.env.DIGUP_ACTIVITY_SCREENSHOTS+"/experience-"+tab+"-"+theme+"-"+width+".png",fullPage:true});
      }
    }
  }
  await page.emulateMedia({forcedColors:"active"});await page.evaluate(()=>showTab("drives"));
  await page.locator("#drive-save").focus();
  assert.ok(await page.locator("#drive-save").evaluate(node=>getComputedStyle(node).outlineStyle!=="none"||getComputedStyle(node).borderStyle!=="none"));
  await page.goto(base+"/window.html");
  assert.equal(await page.getByRole("button",{name:"Toggle result details",exact:true}).count(),1);
  assert.deepEqual(errors,[]);
  console.log("PASS: source navigation, stable drive rows/drafts, overlap counts, truthful device counters, resource/personalization controls, keyboard tabs, themes and scaling");
})().finally(async()=>{await browser?.close();}).catch(error=>{console.error(error);process.exit(1);});
