// Production UI with a synthetic native boundary. This does not exercise DWM or physical accelerators.
"use strict";
const {chromium} = require("playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path");
const {setup} = require("./application-fixtures.cjs");
const base = process.env.DIGUP_UI_URL || "http://127.0.0.1:8765";
const baseline = process.argv.includes("--baseline");
const directory = process.env.DIGUP_FLOATING_SCREENSHOTS;
let browser;
(async () => {
  browser = await chromium.launch({executablePath:process.env.DIGUP_CHROME || "/usr/bin/chromium",
    headless:true,args:["--no-sandbox","--disable-dev-shm-usage"]});
  const errors = [], samples = [], evidence = [];
  async function fixture(view = "index.html", viewport = {width:640,height:760}, options = {}) {
    const page = await browser.newPage({viewport});
    page.on("pageerror",error => errors.push(error.message));
    await setup(page);
    await page.addInitScript(({options,baseline}) => {
      const old = window.__TAURI__.core.invoke;
      window.appearanceValue = "system"; window.materialValue = "automatic";
      window.searchDelay = 0; window.blockPurpose = true; window.releaseQueries = [];
      window.handoff = null; window.saveFailure = false;
      const file = (i,kind="doc") => ({path:"C:/Documents/Synthetic note " + i + ".txt",kind,segment:"chunk",segment_id:i+1,
        modified:1,size:80,info:{},excerpt:"Clearly labelled synthetic UI fixture",keyword_rank:1,score:10-i/100});
      const panel = () => ({supported:true,material:window.materialValue === "solid" ? "solid" : "acrylic",
        reason:window.materialValue === "solid" ? "Solid panel selected." : "",dark:window.appearanceValue === "dark"});
      const appearance = () => ({schemaVersion:2,appearance:window.appearanceValue,panelMaterial:window.materialValue,panel:panel()});
      const benches = Array.from({length:2000},(_,i) => ({
        id:"app:bench-" + i,name:"Bench " + String(i).padStart(4,"0"),kind:"app",resultType:"application",
        publisher:"Synthetic fixture",description:"Catalog rendering fixture",reason:"exact",aliases:[]}));
      window.__TAURI__.core.invoke = async (command,args={}) => {
        if (command === "appearance") return appearance();
        if (command === "set_appearance" || command === "set_panel_material") {
          window.calls.push({command,args});
          if (window.saveFailure) throw new Error("Synthetic settings write failure");
          if (command === "set_appearance") window.appearanceValue = args.appearance;
          else window.materialValue = args.material;
          const reply = appearance(); window.emit("appearance",reply); window.emit("panel-appearance",reply.panel); return reply;
        }
        if (command === "panel_config") return {schemaVersion:1,width:640,fieldHeight:64,maxHeight:640,nativeSized:false,material:panel()};
        if (command === "panel_height") {
          window.calls.push({command,args});
          if (baseline) { const node=document.getElementById("panel"); if(node)node.style.height=args.height+"px"; }
          return {width:640,height:args.height,maxHeight:640,nativeSized:false};
        }
        if (command === "window_info") return {...await old(command,args),
          search:options.handoff || window.handoff,applications:{supported:true,enabled:true,semanticEnabled:true,mixedSearch:"smart"}};
        if (command === "search_apps" && args.q.startsWith("Bench ")) {
          window.calls.push({command,args});
          const hits = benches.filter(hit => hit.name === args.q);
          return {hits,total:hits.length,generation:args.generation,catalog:{supported:true,enabled:true,revision:"bench"},
            semantic:{state:"ready",encoder:"ready"}};
        }
        if (command === "ask" && args.request.op === "search" && ["notes","many","images","nothing"].includes(args.request.q)) {
          window.calls.push({command,args});
          if (args.request.meaning && window.blockPurpose) await new Promise(resolve => window.releaseQueries.push(resolve));
          if (window.searchDelay) await new Promise(resolve => setTimeout(resolve,window.searchDelay));
          const count = args.request.q === "nothing" ? 0 : args.request.q === "notes" ? 3 : 28;
          return {hits:Array.from({length:count},(_,i)=>file(i,args.request.q === "images" ? "image" : "doc")),
            strong:count,meaning:args.request.meaning,generation:args.request.generation};
        }
        if (command === "ask" && args.request.op === "text") {
          window.calls.push({command,args}); return {text:"Synthetic preview text with Unicode: 写真 العربية."};
        }
        if (command === "ask" && args.request.op === "render") {
          window.calls.push({command,args}); return new Promise(() => {});
        }
        return old(command,args);
      };
    },{options,baseline});
    await page.goto(base + "/" + view);
    assert.equal(await page.title(),view.startsWith("settings.html") ? "DigUp Settings" : "DigUp");
    return page;
  }
  async function capture(page,name,selector) {
    if (!directory) return;
    fs.mkdirSync(directory,{recursive:true});
    const target = selector ? page.locator(selector) : page;
    await target.screenshot({path:path.join(directory,name + ".png")});
    evidence.push(name + ".png");
    if (process.env.DIGUP_FLOATING_SCREENSHOT_LOG === "1" && ["capsule-dark","results-light"].includes(name)) {
      const image = await target.screenshot();
      console.log("FLOATING_SCREENSHOT_BASE64 " + name + " " + image.toString("base64"));
    }
  }
  const page = await fixture();
  await page.waitForFunction(() => document.documentElement.dataset.theme === "system");
  if (!baseline) {
    assert.equal(await page.locator("#panel").evaluate(node => Math.round(node.getBoundingClientRect().height)),64);
    assert.equal(await page.locator("#query").getAttribute("role"),"combobox");
    assert.equal(await page.locator("#query").getAttribute("aria-expanded"),"false");
    assert.equal(await page.getByRole("button",{name:"Open full search",exact:true}).count(),1);
    await page.evaluate(() => {window.emit("state",{badge:"Indexing",line:"Discovery in progress",indexing:{done:0,total:null}});});
    assert.equal(await page.locator("#panel").evaluate(node => Math.round(node.getBoundingClientRect().height)),64,
      "Background progress expanded an empty search");
    assert.equal(await page.locator("#activity").isVisible(),false);
    await capture(page,"capsule-light","#panel");
    await page.emulateMedia({colorScheme:"dark"});
    await capture(page,"capsule-dark","#panel");
    await page.emulateMedia({colorScheme:"light"});
  }
  await page.fill("#query","notes");
  await page.waitForSelector('#list [data-result-key="file:C:/Documents/Synthetic note 0.txt"]');
  await page.waitForTimeout(120);
  const height = await page.locator("#panel").evaluate(node => Math.round(node.getBoundingClientRect().height));
  const automaticPreviews = await page.evaluate(() => window.calls.filter(call=>call.command==="ask"&&call.args.request.op==="text").length);
  console.log(JSON.stringify({fixture:"notes",baseline,height,automaticPreviews}));
  await capture(page,baseline ? "baseline-results" : "results-light","#panel");
  if (!baseline) {
    assert.ok(height > 64 && height < 480,"A short result set should determine the panel height");
    assert.equal(automaticPreviews,0,"Selecting a result rendered a full preview without being asked");
    assert.equal(await page.locator("#query").getAttribute("aria-expanded"),"true");
    const selectedId = await page.locator('#list [aria-selected="true"]').first().getAttribute("id");
    assert.equal(await page.locator("#query").getAttribute("aria-activedescendant"),selectedId);
    await page.locator('#list [data-result-key="file:C:/Documents/Synthetic note 1.txt"]').click();
    await page.getByRole("button",{name:"Preview",exact:true}).click();
    await page.waitForSelector(".big .passage");
    assert.match(await page.locator(".big").textContent(),/写\u771f|写真|العربية/);
    assert.ok(await page.evaluate(()=>window.calls.some(call=>call.command==="ask"&&call.args.request.op==="text")));
    await capture(page,"preview-light","#panel");
    await page.keyboard.press("Escape");
    assert.equal(await page.locator(".big").isVisible(),false);
    assert.equal(await page.locator("#query").evaluate(node=>document.activeElement===node),true);
    assert.match(await page.locator('#list [aria-selected="true"]').textContent(),/Synthetic note 1/);
    await page.getByRole("button",{name:"Open full search",exact:true}).click();
    assert.equal(await page.evaluate(()=>window.calls.filter(call=>call.command==="open_window").at(-1).args.selected),
      "file:C:/Documents/Synthetic note 1.txt");
    await page.fill("#query","many");
    await page.waitForFunction(()=>document.querySelectorAll("#list .row").length===18);
    await page.waitForTimeout(80);
    assert.ok(await page.locator("#panel").evaluate(node=>node.getBoundingClientRect().height<=640));
    await page.locator("#list").evaluate(node=>node.scrollTop=100);
    await page.locator("#list .row").nth(5).click();
    await page.evaluate(()=>{
      window.savedPanelRow=document.querySelector("#list .row.selected");
      window.savedScroll=document.querySelector("#list").scrollTop;
      window.emit("applications-progress",{state:"preparing",encoder:"starting",embedded:663,total:800});
      window.emit("state",{badge:"Preparing",line:"443,831 entries checked",indexing:{done:0,total:null}});
    });
    await page.waitForTimeout(100);
    assert.equal(await page.evaluate(()=>window.savedPanelRow===document.querySelector("#list .row.selected")),true);
    assert.equal(await page.locator("#list").evaluate(node=>node.scrollTop),await page.evaluate(()=>window.savedScroll));
    await page.locator("#activity").click();
    assert.equal(await page.evaluate(()=>window.calls.filter(call=>call.command==="open_settings").at(-1).args.tab),"activity");
    await page.fill("#query","images"); await page.waitForSelector("#list img.thumb");
    await page.waitForTimeout(180);
    const requests = await page.evaluate(()=>window.calls.filter(call=>call.command==="ask"&&call.args.request.op==="render"));
    assert.ok(requests.length<18,"Offscreen rows eagerly requested every thumbnail");
    assert.ok(!requests.some(call=>(call.args.request.pixels||call.args.request.size)>512),
      "An automatic full-resolution preview was requested");
    await page.evaluate(()=>window.fileMode="blocked");
    await page.fill("#query","photo"); await page.waitForSelector("#list .app-row");
    await page.locator("#list .app-row").first().click();
    await page.getByRole("button",{name:"Details",exact:true}).click();
    assert.match(await page.locator(".big").textContent(),/Photo Studio/);
    await capture(page,"app-details","#panel");
    await page.keyboard.press("Escape"); await page.press("#query","Enter");
    assert.ok(await page.evaluate(()=>window.calls.some(call=>call.command==="launch_app")));
    await page.evaluate(()=>{window.fileMode="failed";});
    await page.fill("#query","no applications");
    await page.waitForFunction(()=>document.querySelector("#summary").textContent.includes("File helper unavailable"));
    assert.equal(await page.locator("#activity").isVisible(),true);
    await capture(page,"error-light","#panel");
    await page.fill("#query","apps:");
    await page.waitForFunction(()=>document.querySelectorAll("#list .app-row").length===6);
    const names = await page.locator("#list .app-name").allTextContents();
    assert.deepEqual(names,[...names].sort());
    await page.press("#query","ArrowDown"); const chosen = await page.locator("#list .selected").getAttribute("data-result-key");
    await page.evaluate(()=>window.emit("applications-progress",{state:"preparing",encoder:"starting",embedded:1,total:150}));
    await page.press("#query","Enter");
    assert.equal(await page.evaluate(()=>window.calls.filter(call=>call.command==="launch_app").at(-1).args.appId),chosen);
    await page.fill("#query","notes"); await page.waitForSelector("#list .row");
    await page.waitForTimeout(80);
    assert.ok(await page.locator("#panel").evaluate(node=>node.getBoundingClientRect().height<480),
      "A new short query did not shrink a previously long list");
    for (const theme of ["light","dark"]) for (const width of [320,440,640]) {
      await page.setViewportSize({width,height:720});
      await page.evaluate(theme=>AppearanceUI.apply(theme),theme);
      await page.fill("#query","notes");
      await page.waitForSelector("#list .row");
      await page.waitForTimeout(50);
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
      assert.ok(await page.locator("#panel").evaluate(node=>node.getBoundingClientRect().right<=innerWidth+.5));
      const actions = await page.locator("#primary-action").boundingBox();
      assert.ok(actions.x>=0&&actions.x+actions.width<=width+.5,"Primary action is clipped");
      await capture(page,"panel-"+theme+"-"+width,"#panel");
    }
    await page.emulateMedia({forcedColors:"active",reducedMotion:"reduce"});
    assert.equal(await page.locator("#panel").evaluate(node=>getComputedStyle(node).backgroundColor),
      await page.evaluate(()=>{const node=document.createElement("div");node.style.background="Canvas";document.body.append(node);
        const value=getComputedStyle(node).backgroundColor;node.remove();return value;}));
    const selectedContrast = await page.locator("#list .row.selected").evaluate(node => ({
      background:getComputedStyle(node).backgroundColor,color:getComputedStyle(node.querySelector(".row-title")).color}));
    const systemContrast = await page.evaluate(() => {
      const node=document.createElement("div");node.style.cssText="background:Highlight;color:HighlightText";document.body.append(node);
      const value={background:getComputedStyle(node).backgroundColor,color:getComputedStyle(node).color};node.remove();return value;
    });
    assert.deepEqual(selectedContrast,systemContrast,"Forced-colour selection must retain contrasting system text");
    await capture(page,"panel-contrast","#panel");
    await page.emulateMedia({forcedColors:"none",reducedMotion:"no-preference"});
    await page.close();

    const windowPage = await fixture("window.html",{width:1120,height:800},{
      handoff:{query:"notes",kind:null,selected:"file:C:/Documents/Synthetic note 1.txt"}});
    await windowPage.waitForSelector('.selected[data-result-key="file:C:/Documents/Synthetic note 1.txt"]');
    await windowPage.press("#query","Enter");
    assert.equal(await windowPage.evaluate(()=>window.calls.filter(call=>call.command==="open_path").at(-1).args.path),
      "C:/Documents/Synthetic note 1.txt");
    await capture(windowPage,"window-light");
    await windowPage.close();

    const settings = await fixture("settings.html?tab=general",{width:660,height:620});
    assert.equal(await settings.getByRole("combobox",{name:"Search panel appearance"}).isVisible(),true);
    await settings.selectOption("#appearance","dark");
    await settings.waitForFunction(()=>document.documentElement.dataset.theme==="dark");
    await settings.selectOption("#panel-material","solid");
    await settings.waitForFunction(()=>document.querySelector("#panel-material-note").textContent.includes("Solid"));
    await settings.evaluate(()=>window.dispatchEvent(new Event("focus")));
    assert.equal(await settings.inputValue("#panel-material"),"solid");
    await settings.evaluate(()=>window.saveFailure=true);
    await settings.selectOption("#panel-material","automatic");
    await settings.waitForFunction(()=>document.querySelector("#appearance-message").textContent.includes("write failure"));
    assert.equal(await settings.inputValue("#panel-material"),"solid","A failed save lost the committed choice");
    await capture(settings,"settings-dark");
    await settings.close();
  }

  const bench = baseline ? page : await fixture();
  await bench.fill("#query","apps: Bench 0000");
  await bench.waitForSelector('[data-result-key="app:bench-0"]');
  for (let i=1;i<=100;i++) {
    const duration = await bench.evaluate(i=>new Promise(resolve=>{
      const start=performance.now(), input=document.getElementById("query");
      const observer=new MutationObserver(()=>{
        const node=document.querySelector('[data-result-key="app:bench-'+i+'"]');
        if(node){observer.disconnect();requestAnimationFrame(()=>resolve(performance.now()-start));}
      });
      observer.observe(document.getElementById("list"),{childList:true,subtree:true});
      input.value="apps: Bench "+String(i).padStart(4,"0"); input.dispatchEvent(new Event("input",{bubbles:true}));
    }),i);
    samples.push(duration);
  }
  samples.sort((a,b)=>a-b);
  const metrics={schemaVersion:1,baseline,samples:samples.length,medianMs:samples[49],p95Ms:samples[94],
    environment:"Hosted Chromium; synthetic native replies; 2,000-entry fixture; excludes OS hotkey and inference",
    notesHeight:height,automaticPreviews,evidence};
  console.log("FLOATING_UI_METRICS "+JSON.stringify(metrics));
  if(directory)fs.writeFileSync(path.join(directory,baseline?"baseline-metrics.json":"metrics.json"),JSON.stringify(metrics,null,2));
  assert.deepEqual(errors,[],"Unexpected production-page runtime errors");
  await browser.close();
  console.log("PASS: "+(baseline?"baseline render measurements":"capsule, progressive height, explicit previews, stable rows, independent app launching, selection handoff, appearance persistence, scaling, contrast mode and 100 render samples"));
})().catch(async error=>{console.error(error);if(browser)await browser.close();process.exit(1);});
