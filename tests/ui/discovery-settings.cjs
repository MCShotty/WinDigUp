// Actual settings and Activity pages. Fixtures exercise independent provider states and draft safety.
const {chromium}=require("playwright"),assert=require("node:assert/strict");
const {setup}=require("./application-fixtures.cjs"),fs=require("node:fs");
const base=process.env.DIGUP_UI_URL||"http://127.0.0.1:8765";
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||"/usr/bin/chromium",headless:true,args:["--no-sandbox"]});
 try{
 const page=await browser.newPage({viewport:{width:1160,height:960}}),errors=[];
 page.on("pageerror",e=>errors.push(e.message));await setup(page);
 await page.addInitScript(()=>{
  const old=window.__TAURI__.core.invoke;
  window.drive={version:1,supported:true,options:{enabled:false,paused:false,volumes:[],included:["exe:existing"],hidden:[]},
    volumes:[{id:"volume-a",name:"Local SSD",paths:["C:\\"],filesystem:"NTFS",available:true},{id:"volume-b",name:"USB",paths:["D:\\"],filesystem:"exFAT",available:true}],
    progress:{phase:"enumerating",records:443831,candidates:107857,accepted:663,total:null}};
  window.descriptions={options:{enabled:false,publisherPages:true},progress:{state:"disabled",enriched:12}};
  window.winSettings={enabled:true,semanticEnabled:true,ordinarySearches:true,count:38,supported:true};
  window.enrichedHit={id:"app:"+("1".repeat(64)),name:"Photo Studio",publisher:"Example",description:"A description",aliases:[],purpose:"",hidden:false,
    descriptionSource:{provider:"WinGet",url:"https://example.com/product"}};
  window.__TAURI__.core.invoke=async(command,args={})=>{
   if(command==="settings_info")return {...await old(command,args),discovery:window.drive,enrichment:window.descriptions,windowsSettings:window.winSettings,windowsSettingsSemantic:{state:"ready",embedded:38,total:38}};
   if(command==="activity_snapshot")return {...await old(command,args),discovery:window.drive,enrichment:window.descriptions,windowsSettings:{catalog:window.winSettings,purpose:{state:"ready"}}};
   if(["set_discovery_options","set_app_enrichment_options","set_windows_settings_options","refresh_discovery","install_discovery_component","refresh_app_descriptions","clear_app_descriptions","discovery_candidates","set_discovery_candidate","open_app_description_source"].includes(command)){
    window.calls.push({command,args});
    if(command==="set_discovery_options"){window.drive.options=args.options;return window.drive;}
    if(command==="set_app_enrichment_options"){window.descriptions.options=args.options;return window.descriptions;}
    if(command==="set_windows_settings_options"){Object.assign(window.winSettings,args.options);return window.winSettings;}
    if(command==="clear_app_descriptions"){window.descriptions={options:{enabled:false,publisherPages:true},progress:{state:"disabled",enriched:0}};return window.descriptions;}
    if(command==="discovery_candidates")return {generation:args.generation,hits:[{id:"exe:test",name:"Portable العربية",publisher:"Unknown",path:"D:\\Portable العربية.exe",portable:true,classification:"review",reason:"application_identity_uncertain"}],total:1};
    if(command==="set_discovery_candidate"){window.drive.options.included.push(args.candidateId);return window.drive;}
    return window.drive;
   }
   return old(command,args);
  };
 });
 await page.goto(base+"/settings.html?tab=apps");await page.locator("#apps").waitFor({state:"visible"});
 await page.locator("#extra-app-sources").waitFor({state:"visible"});
 await page.getByRole("tab",{name:"Drives",exact:true}).click();
 await page.locator("#drive-enabled").check();await page.locator("#drive-volumes input[data-source=applications]").nth(0).check();
 assert.match(await page.locator("#drive-draft").innerText(),/Unsaved/);
 await page.evaluate(()=>{drive.progress.records=500000;emit("discovery",drive);window.dispatchEvent(new Event("focus"));});
 await page.waitForTimeout(150);
 assert.equal(await page.locator("#drive-enabled").isChecked(),true);
 assert.equal(await page.locator("#drive-volumes input[data-source=applications]").nth(0).isChecked(),true);
 await page.locator("#drive-save").click();await page.waitForFunction(()=>calls.some(c=>c.command==="set_discovery_options"));
 const saved=await page.evaluate(()=>calls.find(c=>c.command==="set_discovery_options").args.options);
 assert.deepEqual(saved.volumes,["volume-a"]);assert.deepEqual(saved.included,["exe:existing"]);
 await page.getByRole("tab",{name:"Review apps",exact:true}).click();
 await page.locator("#drive-candidates button").first().click();await page.waitForFunction(()=>calls.some(c=>c.command==="set_discovery_candidate"));
 await page.getByRole("tab",{name:"Apps",exact:true}).click();
 await page.locator(".source-section").filter({has:page.locator("summary", {hasText:"Enhance app descriptions online"})}).locator(":scope > summary").click();await page.locator("#descriptions-enabled").check();
 await page.waitForFunction(()=>calls.some(c=>c.command==="set_app_enrichment_options"));
 await page.locator("#descriptions-clear").click();await page.waitForFunction(()=>calls.some(c=>c.command==="clear_app_descriptions"));
 assert.equal(await page.locator("#descriptions-enabled").isChecked(),false);
 await page.getByRole("tab",{name:"Windows settings",exact:true}).click();await page.locator("#win-settings-ordinary").uncheck();
 await page.waitForFunction(()=>calls.some(c=>c.command==="set_windows_settings_options"));
 await page.locator('[data-tab="activity"]').first().click();await page.waitForTimeout(450);
 assert.match(await page.locator('[data-key="drive-status"]').innerText(),/500,000 records checked/);
 assert.match(await page.locator('[data-key="drive-status"]').innerText(),/107,857 executable candidates/);
 assert.match(await page.locator('[data-key="drive-status"]').innerText(),/663 accepted/);
 if(process.env.DIGUP_ACTIVITY_SCREENSHOTS){fs.mkdirSync(process.env.DIGUP_ACTIVITY_SCREENSHOTS,{recursive:true});await page.screenshot({path:process.env.DIGUP_ACTIVITY_SCREENSHOTS+"/discovery-activity.png",fullPage:true});}
 assert.deepEqual(errors,[]);console.log("PASS: source controls, persistent drafts, review, opt-in descriptions, measured Activity");
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
