const {chromium}=require("playwright"),assert=require("node:assert/strict"),fs=require("node:fs");
const {setup}=require("./application-fixtures.cjs");
const base=process.env.DIGUP_UI_URL||"http://127.0.0.1:8765";
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||"/usr/bin/chromium",headless:true,args:["--no-sandbox"]});
 try{
  const page=await browser.newPage({viewport:{width:1160,height:920}}),errors=[];
  page.on("pageerror",error=>errors.push(error.message));await setup(page);
  await page.addInitScript(()=>{
   const old=window.__TAURI__.core.invoke,now=Date.now()/1000;
   window.drives={version:2,supported:true,running:true,options:{enabled:true,volumes:["a","b","c"],included:[],hidden:[]},
    progress:{phase:"enumerating",records:443831,candidates:107857,total:null},
    volumes:[{id:"a",paths:["C:\\"],name:"Local SSD",filesystem:"NTFS",available:true,topology:{known:true,disks:[0],media:"ssd"}},
     {id:"b",paths:["D:\\"],name:"Data partition",filesystem:"NTFS",available:true,topology:{known:true,disks:[0],media:"ssd"}},
     {id:"c",paths:["E:\\"],name:"Archive",filesystem:"NTFS",available:true,topology:{known:true,disks:[1],media:"hdd"}}],
    byVolume:{a:{phase:"enumerating",records:443831,candidates:107857,accepted:12,serviceTimings:{version:1,stages:{enumeration:{milliseconds:1250},pathResolution:{milliseconds:80}}},timings:{version:1,stages:{metadataReads:{milliseconds:430},databaseCommit:{milliseconds:45}}}},
     b:{phase:"waiting",records:null,candidates:null,message:"Waiting for another volume on this disk."},
     c:{phase:"metadata",records:8000,candidates:40,accepted:20}},sourceErrors:{}};
   window.online={options:{enabled:false,publisherPages:true},progress:{state:"disabled",enriched:0}};
   window.settingsCatalog={supported:true,enabled:true,semanticEnabled:true,ordinarySearches:true,count:38};
   window.purpose={state:"ready",embedded:38,total:38};
   window.settingsPending=null;window.appearance="system";window.emptyCandidates=false;
   window.__TAURI__.core.invoke=async(command,args={})=>{
    if(command==="appearance")return{schemaVersion:1,appearance:window.appearance};
    if(command==="set_appearance"){window.calls.push({command,args});window.appearance=args.appearance;emit("appearance",{appearance:window.appearance});return{schemaVersion:1,appearance:window.appearance};}
    if(command==="settings_info")return{...await old(command,args),discovery:drives,enrichment:online,windowsSettings:settingsCatalog,
     windowsSettingsSemantic:purpose,acceleration:{backend:"amd-vulkan",gpu:"VK-fixture",jobs:0,python:"",models:""}};
    if(command==="activity_snapshot")return{...await old(command,args),discovery:drives,enrichment:online,windowsSettings:{catalog:settingsCatalog,purpose},
     inference:{schemaVersion:2,configured:{backend:"amd-vulkan",jobs:0},encoder:"ready",model:{state:"ready"},
      verified:{backend:"amd-vulkan",device:"Fixture GPU",executionPolicy:"accelerator-only",at:now},
      jobs:{"1":{profile:"multimodal2048",phase:"running"},"2":{profile:"text512",phase:"waiting"}}}};
    if(["set_discovery_options","refresh_discovery","install_discovery_component","set_app_enrichment_options","set_windows_settings_options","discovery_candidates","set_discovery_candidate","refresh_app_descriptions","clear_app_descriptions","prepare_windows_settings"].includes(command)){
     calls.push({command,args});
     if(command==="set_discovery_options"){drives.options=args.options;return structuredClone(drives);}
     if(command==="set_windows_settings_options")return new Promise(resolve=>{window.settingsPending=()=>{Object.assign(settingsCatalog,args.options);resolve(structuredClone(settingsCatalog));};});
     if(command==="set_app_enrichment_options"){online.options=args.options;return structuredClone(online);}
     if(command==="clear_app_descriptions"){online.options.enabled=false;return structuredClone(online);}
     if(command==="prepare_windows_settings"){purpose={state:"preparing",embedded:0,total:38};return purpose;}
     if(command==="discovery_candidates"){
      if(args.q==="slow")await new Promise(resolve=>setTimeout(resolve,350));
      return{generation:args.generation,hits:window.emptyCandidates?[]:[{id:"exe:fixture",name:args.q||"Portable editor",path:"C:\\Portable\\Editor.exe",publisher:"Fixture publisher",portable:true,reason:"application_identity_uncertain"}],total:window.emptyCandidates?0:1,catalogTotal:4};
     }
     if(command==="set_discovery_candidate")return structuredClone(drives);
     if(command.includes("descriptions"))return structuredClone(online);
     return structuredClone(drives);
    }
    return old(command,args);
   };
  });
  await page.goto(base+"/settings.html?tab=apps");await page.locator("#extra-app-sources").waitFor({state:"visible"});
  await page.locator(".source-section").nth(1).locator("summary").click();
  assert.equal(await page.locator("#drive-progress-list .pipeline-drive").count(),3);
  assert.match(await page.locator('#drive-progress-list [data-volume-id="a"]').innerText(),/443,831 entries checked/);
  assert.match(await page.locator('#drive-progress-list [data-volume-id="b"]').innerText(),/Waiting for disk capacity/);
  assert.ok(!(await page.locator('#drive-progress-list [data-volume-id="b"] .pipeline-drive-counts').innerText()).includes("0"));
  await page.locator('#drive-progress-list [data-volume-id="a"] summary').click();
  assert.match(await page.locator('#drive-progress-list [data-volume-id="a"]').innerText(),/1,250 ms/);
  await page.locator("#drive-volumes input").nth(1).uncheck();
  await page.evaluate(()=>{window.driveRow=document.querySelector('[data-volume-id="a"]');drives.byVolume.a.records++;emit("discovery",structuredClone(drives));window.dispatchEvent(new Event("focus"));});
  await page.waitForTimeout(100);
  assert.equal(await page.evaluate(()=>window.driveRow===document.querySelector('[data-volume-id="a"]')),true);
  assert.equal(await page.locator('#drive-progress-list [data-volume-id="a"] details').getAttribute("open"),"");
  assert.equal(await page.locator("#drive-volumes input").nth(1).isChecked(),false);
  await page.locator("#drive-revert").click();
  assert.equal(await page.locator("#drive-volumes input").nth(1).isChecked(),true);
  await page.locator("#drive-volumes input").nth(1).uncheck();await page.locator("#drive-save").click();
  await page.waitForFunction(()=>calls.some(call=>call.command==="set_discovery_options"));
  await page.evaluate(()=>{drives.running=false;emit("discovery",structuredClone(drives));});
  await page.locator("#drive-refresh").click();await page.locator("#drive-install").click();
  await page.locator(".source-section").nth(0).locator("summary").click();
  await page.locator("#win-settings-ordinary").uncheck();
  await page.waitForFunction(()=>Boolean(window.settingsPending));
  assert.equal(await page.locator("#drive-install").isEnabled(),true);
  await page.locator(".source-section").nth(2).locator("summary").click();
  await page.locator("#descriptions-enabled").check();
  await page.waitForFunction(()=>calls.some(call=>call.command==="set_app_enrichment_options"));
  assert.equal(await page.locator("#win-settings-ordinary").isDisabled(),true);
  await page.evaluate(()=>settingsPending());await page.waitForFunction(()=>!document.querySelector("#win-settings-ordinary").disabled);
  await page.locator("#descriptions-refresh").click();await page.locator("#descriptions-clear").click();
  await page.locator("#drive-filter").fill("slow");await page.waitForTimeout(150);
  await page.locator("#drive-filter").fill("fast");await page.waitForTimeout(600);
  assert.equal(await page.locator("#drive-candidates strong").innerText(),"fast");
  await page.locator("#drive-candidates button").first().focus();
  await page.evaluate(()=>{window.candidateRow=document.querySelector(".source-candidate");emit("discovery",structuredClone(drives));});
  assert.equal(await page.evaluate(()=>window.candidateRow===document.querySelector(".source-candidate")),true);
  assert.equal(await page.locator("#drive-candidates button").first().evaluate(element=>element===document.activeElement),true);
  await page.locator("#drive-candidates button").first().click();
  await page.evaluate(()=>window.emptyCandidates=true);
  await page.locator("#drive-filter").fill("");await page.waitForTimeout(300);
  assert.match(await page.locator("#drive-list-state").innerText(),/No executables need review/);
  await page.locator('[data-tab="general"]').click();
  await page.locator("#gpu-jobs").selectOption("2");
  await page.evaluate(()=>window.dispatchEvent(new Event("focus")));await page.waitForTimeout(100);
  assert.equal(await page.locator("#gpu-jobs").inputValue(),"2");
  await page.locator("#apply-accelerator").click();
  assert.equal(await page.evaluate(()=>calls.find(call=>call.command==="set_acceleration").args.acceleration.jobs),2);
  await page.locator("#appearance").selectOption("dark");
  await page.waitForFunction(()=>document.documentElement.dataset.theme==="dark");
  await page.emulateMedia({colorScheme:"light"});
  assert.equal(await page.locator("body").evaluate(element=>getComputedStyle(element).backgroundColor),"rgb(31, 31, 33)");
  await page.locator("#appearance").selectOption("light");
  await page.emulateMedia({colorScheme:"dark"});
  assert.equal(await page.locator("body").evaluate(element=>getComputedStyle(element).backgroundColor),"rgb(251, 251, 251)");
  await page.locator('[data-tab="activity"]').first().click();await page.waitForTimeout(500);
  assert.match(await page.locator('[data-key="gpu-work"]').innerText(),/1 running · 1 waiting/);
  await page.locator('[data-key="source-settings"]').click();
  await page.locator("#apps").waitFor({state:"visible"});
  await page.goto(base+"/window.html");
  await page.fill("#query","apps: photo");await page.locator(".app-row").first().waitFor();
  await page.locator("#status-line").click();await page.locator('[data-key="drive-list"]').waitFor();
  await page.locator('[data-key="drive-list"]').scrollIntoViewIfNeeded();
  await page.evaluate(()=>{
   const label=document.createElement("div");label.textContent="UI test fixture · No hardware measurements";
   label.style.cssText="position:fixed;bottom:8px;left:8px;z-index:9999;padding:4px 8px;background:#fbfbfb;color:#1d1d1f;border:1px solid #aaa;font:12px sans-serif";
   document.body.append(label);
  });
  const output=process.env.DIGUP_ACTIVITY_SCREENSHOTS;
  if(output)fs.mkdirSync(output,{recursive:true});
  if(output)await page.screenshot({path:output+"/concurrency-activity.png",fullPage:true});
  if(process.env.DIGUP_CONCURRENCY_SCREENSHOT_LOG)console.log("CONCURRENCY_SCREENSHOT_BASE64="+(await page.screenshot({type:"jpeg",quality:55})).toString("base64"));
  await page.emulateMedia({colorScheme:"dark"});await page.evaluate(()=>AppearanceUI.apply("dark"));
  if(output)await page.screenshot({path:output+"/concurrency-dark.png",fullPage:true});
  for(const width of [1040,800,540]){
   await page.setViewportSize({width,height:760});
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
   if(output)await page.screenshot({path:output+"/concurrency-"+width+".png",fullPage:true});
  }
  assert.deepEqual(errors,[]);
  console.log("PASS: per-drive progress and measurements, unknown counts, stable expanded rows, independent source actions, drafts, stale candidates, GPU cap, appearance, source navigation and window scaling. Native boundary mocked.");
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});
