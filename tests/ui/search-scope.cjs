// Production pages with a synthetic native boundary; no model or physical drive is exercised.
const {chromium}=require("playwright");
const assert=require("node:assert/strict");
const {setup}=require("./application-fixtures.cjs");
const base=process.env.DIGUP_UI_URL||"http://127.0.0.1:8765";
let browser;
(async()=>{
  browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||"/usr/bin/chromium",headless:true,args:["--no-sandbox","--disable-dev-shm-usage"]});
  for(const view of ["window.html","index.html"]){
    const page=await browser.newPage({viewport:{width:view==="window.html"?1120:700,height:800}}),errors=[];
    page.on("pageerror",error=>errors.push(error.message));
    await setup(page);
    await page.addInitScript(()=>{
      window.selectedFolders=["C:/docs"];window.codeSelected=true;window.delayedFiles=[];
      window.releaseOldFiles=()=>window.delayedFiles.splice(0).forEach(resolve=>resolve());
      const old=window.__TAURI__.core.invoke;
      const app={id:"app:"+"1".repeat(64),resultType:"application",kind:"app",name:"Scope App",reason:"prefix",publisher:"Fixture",description:"Open local documents",aliases:[]};
      const setting={id:"setting:display",resultType:"windows_setting",kind:"windows_setting",name:"Display",reason:"prefix",publisher:"Windows",description:"Change display settings",aliases:[],availability:"available"};
      const catalog={supported:true,enabled:true,semanticEnabled:false,revision:"scope-fixture",count:1};
      const settingsCatalog={...catalog,ordinarySearches:true,version:1};
      window.__TAURI__.core.invoke=async(command,args={})=>{
        if(command==="window_info")return {...await old(command,args),folders:window.selectedFolders,hasCode:window.codeSelected,applications:catalog,windowsSettings:settingsCatalog};
        if(command==="search_apps"){window.calls.push({command,args});return {hits:[app],total:1,generation:args.generation,catalog,semantic:{state:"disabled"}};}
        if(command==="search_windows_settings"){window.calls.push({command,args});return {hits:[setting],total:1,generation:args.generation,catalog:settingsCatalog,semantic:{state:"disabled"}};}
        if(command==="ask"&&args.request.op==="search"){
          window.calls.push({command,args});
          const r=args.request;
          if(r.code?!window.codeSelected:!window.selectedFolders.length)return {hits:[],strong:0,meaning:false,scope_empty:true,generation:r.generation};
          const path=r.code?"C:/code/main.py":"C:/docs/retained.txt";
          if(r.meaning)await new Promise(resolve=>window.delayedFiles.push(resolve));
          return {hits:[{path,kind:r.code?"code":"doc",segment:r.code?"lines":"chunk",segment_id:1,
            score:4,keyword_rank:1,size:20,modified:1,info:{},excerpt:"Scope fixture",loc:r.code?1:null}],
            strong:1,meaning:r.meaning,generation:r.generation,facets:r.code?{}:{doc:1}};
        }
        return old(command,args);
      };
    });
    await page.goto(base+"/"+view);await page.fill("#query","scope");
    const fileRows=view==="window.html"?".cell":".row";
    await page.waitForSelector(fileRows);await page.waitForSelector('[data-result-key^="app:"]');
    await page.locator('[data-result-key^="app:"]').first().click();
    if(view==="index.html"){await page.press("#query","Space");await page.waitForFunction(()=>!document.querySelector("#big").hidden);}
    await page.waitForTimeout(170);
    assert.ok(await page.evaluate(()=>window.delayedFiles.length>0));
    const selected=await page.evaluate(()=>state.selection);
    const namesBefore=await page.evaluate(()=>window.calls.filter(c=>c.command==="search_apps").length);
    await page.evaluate(()=>{window.selectedFolders=[];window.emit("search-scope",{folders:[],hasCode:true});});
    await page.waitForFunction(()=>!document.querySelector(".cell")&&!document.querySelector(".row"));
    assert.equal(await page.evaluate(()=>state.selection),selected,"Scope change moved the selected application");
    if(view==="index.html")assert.equal(await page.locator("#big").isVisible(),true,"File scope change closed app details");
    assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==="search_apps").length),namesBefore,"File scope restarted app discovery");
    await page.evaluate(()=>window.releaseOldFiles());await page.waitForTimeout(160);
    assert.equal(await page.locator(fileRows).count(),0,"A delayed old-index reply restored removed files");
    assert.ok(await page.locator('[data-result-key^="app:"]').count()>0);
    assert.ok(await page.locator('[data-result-key^="setting:"]').count()>0);
    await page.press("#query","Enter");
    assert.ok(await page.evaluate(()=>window.calls.some(c=>c.command==="launch_app")),"No-folder scope disabled app launching");
    await page.fill("#query","code: scope");await page.waitForSelector(".row");
    assert.match(await page.locator(".row").first().textContent(),/main\.py/,"Regular folder scope disabled separate code roots");
    await page.evaluate(()=>{window.codeSelected=false;window.emit("search-scope",{folders:[],hasCode:false});window.releaseOldFiles();});
    await page.waitForFunction(()=>!document.querySelector(".cell")&&!document.querySelector(".row"));
    await page.fill("#query","apps:");await page.waitForSelector('[data-result-key^="app:"]');
    await page.fill("#query","settings:");await page.waitForSelector('[data-result-key^="setting:"]');
    const searches=await page.evaluate(()=>window.calls.filter(c=>c.command==="ask"&&c.args.request.op==="search").length);
    await page.fill("#query","");await page.waitForTimeout(180);
    assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==="ask"&&c.args.request.op==="search").length),searches,"Empty query searched retained files");
    assert.equal(await page.locator(fileRows).count(),0);
    await page.emulateMedia({colorScheme:"dark"});await page.setViewportSize({width:700,height:700});
    await page.fill("#query","scope");await page.waitForSelector('[data-result-key^="app:"]');
    assert.equal(await page.locator(fileRows).count(),0);
    assert.deepEqual(errors,[]);
    await page.close();
  }
  await browser.close();
  console.log("PASS: explicit empty file scope, in-flight removal, retained native providers/selection/launch, separate code roots, empty prefixes, both views and dark/narrow rendering");
})().catch(async error=>{console.error(error);if(browser)await browser.close();process.exit(1);});
