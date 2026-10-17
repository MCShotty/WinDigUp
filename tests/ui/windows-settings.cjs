// Actual production pages with synthetic native boundaries; no neural execution is claimed.
const {chromium}=require("playwright");
const assert=require("node:assert/strict");
const {setup}=require("./application-fixtures.cjs");
const fs=require("node:fs");
const base=process.env.DIGUP_UI_URL||"http://127.0.0.1:8765";
let browser;
(async()=>{
  browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||"/usr/bin/chromium",headless:true,args:["--no-sandbox","--disable-dev-shm-usage"]});
  const page=await browser.newPage({viewport:{width:1120,height:800}}),errors=[];
  page.on("pageerror",error=>errors.push(error.message));
  await setup(page);
  await page.addInitScript(()=>{
    window.settingDelayed=[];window.blockSettings=true;
    window.releaseSettings=()=>{window.blockSettings=false;window.settingDelayed.splice(0).forEach(resolve=>resolve());};
    const old=window.__TAURI__.core.invoke;
    const hit=(id,name,reason="exact")=>({id:"setting:"+id,resultType:"windows_setting",kind:"windows_setting",name,reason,
      publisher:"Windows",description:"Open this Windows settings page",availability:"available",aliases:[]});
    const catalog=()=>({version:1,enabled:true,supported:true,semanticEnabled:true,ordinarySearches:true,revision:"settings-fixture"});
    window.__TAURI__.core.invoke=async(command,args={})=>{
      if(command==="window_info")return {...await old(command,args),windowsSettings:catalog()};
      if(command==="search_windows_settings"){
        window.calls.push({command,args});
        const q=args.q.toLowerCase();
        const selected=!q?[hit("bluetooth","Bluetooth"),hit("display","Display"),hit("night-light","Night light")]
          :q==="bluetooth"?[hit("bluetooth","Bluetooth")]
          :q==="display"?[hit("display","Display")]
          :q==="warm screen"&&args.meaning?[hit("night-light","Night light","semantic")]:[];
        if(args.meaning&&window.blockSettings)await new Promise(resolve=>window.settingDelayed.push(resolve));
        return {hits:selected,total:selected.length,generation:args.generation,catalog:catalog(),semantic:{state:"ready",encoder:"ready"}};
      }
      if(["open_windows_setting","cancel_windows_settings_search"].includes(command)){
        window.calls.push({command,args});return {accepted:true};
      }
      if(command==="ask"&&args.request.op==="search"){
        window.calls.push({command,args});
        if(args.request.meaning)await new Promise(resolve=>window.settingDelayed.push(resolve));
        return {hits:[{path:"C:/docs/Bluetooth notes.txt",kind:"doc",segment:"chunk",segment_id:1,score:4,excerpt:"Device notes",
          size:100,modified:1,info:{}}],strong:1,meaning:false,facets:{doc:1},generation:args.request.generation};
      }
      return old(command,args);
    };
  });
  await page.goto(base+"/window.html");await page.fill("#query","settings: bluetooth");
  await page.waitForSelector('.windows-settings-group [data-result-key="setting:bluetooth"]');
  assert.equal(await page.locator(".cell").count(),0);
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==="ask"&&c.args.request.op==="search").length),0);
  await page.locator('.windows-settings-group .app-row').click();await page.press("#query","Enter");
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==="open_windows_setting").at(-1).args.settingId),"setting:bluetooth");
  assert.equal(await page.locator("#side").getByRole("button",{name:"Open settings",exact:true}).count(),1);
  await page.fill("#query","settings: display");
  await page.waitForSelector('[data-result-key="setting:display"]');
  await page.evaluate(()=>window.releaseSettings());
  await page.waitForTimeout(150);
  assert.equal(await page.locator('[data-result-key="setting:bluetooth"]').count(),0,"Old settings reply leaked into new query");
  await page.fill("#query","settings:");
  await page.waitForFunction(()=>document.querySelectorAll(".windows-settings-group .app-row").length===3);
  assert.match(await page.locator(".windows-settings-group .app-row").first().textContent(),/Bluetooth/);
  await page.getByRole("button",{name:"All",exact:false}).first().click();
  assert.equal(await page.locator("#query").inputValue(),"");
  await page.fill("#query","Bluetooth");await page.waitForSelector(".cell");
  await page.waitForSelector('.best-matches [data-result-key="setting:bluetooth"]');
  assert.equal(await page.locator('.best-matches [data-result-key]').first().getAttribute('data-result-key'),"setting:bluetooth");
  await page.locator(".cell").click();
  await page.evaluate(()=>{window.savedCell=document.querySelector(".cell");window.savedSide=document.querySelector("#side").firstChild;
    window.emit("windows-settings-progress",{state:"preparing",encoder:"ready",embedded:1,total:3});});
  await page.waitForTimeout(100);
  assert.equal(await page.evaluate(()=>window.savedCell===document.querySelector(".cell")),true);
  assert.equal(await page.evaluate(()=>window.savedSide===document.querySelector("#side").firstChild),true);
  await page.press("#query","Control+9");await page.waitForSelector(".windows-settings-group");
  assert.equal(await page.locator(".cell").count(),0);
  await page.fill("#query","settings: warm screen");
  await page.waitForSelector('[data-result-key="setting:night-light"]');
  assert.match(await page.locator(".windows-settings-group").textContent(),/Purpose match/);
  if(process.env.DIGUP_SEARCH_SCREENSHOTS){
    fs.mkdirSync(process.env.DIGUP_SEARCH_SCREENSHOTS,{recursive:true});
    await page.screenshot({path:process.env.DIGUP_SEARCH_SCREENSHOTS+"/windows-settings-light.png"});
    await page.emulateMedia({colorScheme:"dark"});await page.setViewportSize({width:760,height:720});
    await page.screenshot({path:process.env.DIGUP_SEARCH_SCREENSHOTS+"/windows-settings-dark.png"});
  }
  await page.goto(base+"/index.html");await page.fill("#query","settings: bluetooth");
  await page.waitForSelector('[data-result-key="setting:bluetooth"]');
  await page.press("#query","Enter");
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==="open_windows_setting").at(-1).args.settingId),"setting:bluetooth");
  assert.match(await page.locator("#keys").textContent(),/Windows settings/);
  assert.deepEqual(errors,[]);
  await browser.close();console.log("PASS: Windows settings routing, native names, lexical/semantic separation, stale replies, shared best-match placement, stable file DOM, keyboard opening, dark/scaled views and panel handoff");
})().catch(async error=>{console.error(error);if(browser)await browser.close();process.exit(1);});
