const {chromium}=require("playwright");
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path");
const {setup}=require("./application-fixtures.cjs");
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||"/usr/bin/chromium",headless:true,args:["--no-sandbox"]});
 try{
  const page=await browser.newPage({viewport:{width:720,height:700}}),errors=[];page.on("pageerror",e=>errors.push(e.message));await setup(page);
  await page.addInitScript(()=>{
   const old=window.__TAURI__.core.invoke;
   window.launcherFixture={pinned:["app:editor"],showRecent:true,hits:[
    {id:"app:editor",name:"Editor",resultType:"application",publisher:"Fixture",description:"Edit documents",pinned:true},
    {id:"app:photos",name:"Photos",resultType:"application",publisher:"Fixture",description:"View photos",pinned:false}]};
   window.__TAURI__.core.invoke=async(command,args={})=>{
    if(command==="launcher_apps")return window.launcherFixture;
    if(command==="launch_app"){window.calls.push({command,args});if(window.failShortcut)throw {message:"Application is unavailable"};return {accepted:true};}
    if(command==="app_icon")return "app-generic.svg";
    if(command==="panel_config")return {maxHeight:640,nativeSized:false};
    return old(command,args);
   };
  });
  const base=process.env.DIGUP_UI_URL||"http://127.0.0.1:8765";await page.goto(base+"/index.html");
  await page.waitForSelector(".launcher-shortcut");
  assert.equal(await page.locator(".launcher-shortcut").count(),2);
  assert.equal(await page.locator("#panel").evaluate(e=>Math.round(e.getBoundingClientRect().height)),120);
  await page.focus("#query");await page.keyboard.press("ArrowDown");
  assert.equal(await page.evaluate(()=>document.activeElement.dataset.launcherId),"app:editor");
  await page.keyboard.press("ArrowRight");assert.equal(await page.evaluate(()=>document.activeElement.dataset.launcherId),"app:photos");
  await page.keyboard.press("Enter");assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==="launch_app").at(-1).args.appId),"app:photos");
  await page.evaluate(()=>window.failShortcut=true);
  await page.locator('[data-launcher-id="app:editor"]').click();
  await page.waitForSelector(".launcher-error");
  assert.match(await page.locator(".launcher-error").textContent(),/Application is unavailable/);
  assert.equal(await page.locator(".launcher-retry").getAttribute("aria-label"),"Retry launching Editor");
  await page.getByRole("button",{name:"Dismiss",exact:true}).click();
  assert.equal(await page.evaluate(()=>document.activeElement.dataset.launcherId),"app:editor");
  await page.evaluate(()=>window.failShortcut=false);
  await page.fill("#query","apps:");await page.waitForFunction(()=>document.getElementById("launcher-shortcuts").hidden);
  await page.fill("#query","");await page.waitForFunction(()=>!document.getElementById("launcher-shortcuts").hidden);
  for(const theme of ["dark","light"]){
   await page.evaluate(t=>AppearanceUI.apply(t),theme);
   assert.equal(await page.locator(".launcher-shortcut .app-generic").first().evaluate(e=>getComputedStyle(e).filter),theme==="dark"?"invert(0.85)":"none");
   for(const width of [360,720]){
    await page.setViewportSize({width,height:700});
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
    const png=await page.locator("#panel").screenshot();
    if(process.env.DIGUP_ACTIVITY_SCREENSHOTS){const dir=process.env.DIGUP_ACTIVITY_SCREENSHOTS;fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,"launcher-home-"+theme+"-"+width+".png"),png);}
    console.log("LAUNCHER_SCREENSHOT_BASE64 "+theme+(width===720?"":"-"+width)+" "+png.toString("base64"));
   }
  }
  assert.deepEqual(errors,[]);console.log("PASS: pinned/recent home, keyboard launch, empty/results transition, themes and narrow layout");
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
