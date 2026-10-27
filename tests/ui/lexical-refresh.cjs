// Actual pages and helper events with a synthetic native boundary; no model or hardware is exercised.
"use strict";
const {chromium}=require("playwright"),assert=require("node:assert/strict");
const {setup}=require("./application-fixtures.cjs");
const base=process.env.DIGUP_UI_URL||"http://127.0.0.1:8765";
let browser;
(async()=>{
  browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||"/usr/bin/chromium",headless:true,args:["--no-sandbox","--disable-dev-shm-usage"]});
  for(const view of ["window.html","index.html"])for(const mode of ["unavailable","ready"]){
    const page=await browser.newPage({viewport:{width:view==="window.html"?1120:700,height:800}}),errors=[];
    page.on("pageerror",error=>errors.push(error.message));await setup(page);
    await page.addInitScript(({mode})=>{
      window.published=0;window.holdNextWords=false;window.heldWords=[];
      const old=window.__TAURI__.core.invoke;
      const app={id:"app:"+"1".repeat(64),resultType:"application",kind:"app",name:"Receipt",reason:"exact",
        aliases:[],publisher:"Synthetic fixture",description:"Local receipt application"};
      const catalog={supported:true,enabled:true,semanticEnabled:false,count:1,revision:"lexical-refresh",mixedSearch:"smart"};
      const setting={id:"setting:fixture-receipt",resultType:"windows_setting",kind:"windows_setting",name:"Receipt settings",reason:"prefix",
        aliases:[],publisher:"Synthetic fixture",description:"Synthetic local destination"};
      const settingsCatalog={...catalog,version:1,ordinarySearches:true};
      const file=(name,extra={})=>({path:"C:/docs/"+name,kind:"doc",segment:"name",segment_id:1,
        modified:1,size:32,info:{},keyword_rank:1,score:4,...extra});
      const words=(request,publication)=>{
        if(request.q!=="receipt")return [file("new-query.txt")];
        const hits=[file("receipt-plan.txt",publication>=2?{segment_id:11}:{})];
        if(publication===0)hits.push(file("receipt-initial-word.txt"));
        if(publication>=1)hits.push(file("receipt.txt",{score:4000}));
        if(publication>=2)hits.push(file("receipt-notes.txt"));
        if(publication===3)hits.push(file("receipt-obsolete-refresh.txt"));
        if(publication>=4)hits.push(file("receipt-latest-refresh.txt"));
        if(publication===5)hits.push(file("receipt-intermediate-refresh.txt"));
        if(publication===4)hits.push(file("receipt-current-publication.txt"));
        return hits;
      };
      window.__TAURI__.core.invoke=async(command,args={})=>{
        if(command==="window_info")return {...await old(command,args),applications:catalog,windowsSettings:settingsCatalog,hasCode:true};
        if(command==="search_apps"){
          window.calls.push({command,args});const hits=args.q==="receipt"?[app]:[];
          return {hits,total:hits.length,generation:args.generation,catalog,semantic:{state:"disabled"}};
        }
        if(command==="search_windows_settings"){window.calls.push({command,args});const hits=args.q==="receipt"?[setting]:[];
          return {hits,total:hits.length,generation:args.generation,catalog:settingsCatalog,semantic:{state:"disabled"}};}
        if(command==="ask"&&args.request.op==="search"){
          window.calls.push({command,args});const request=args.request,publication=window.published;
          const lexical=words(request,publication);
          const hits=request.meaning&&mode==="ready"&&request.q==="receipt"
            ? [file("unrelated-title.txt",{segment:"chunk",segment_id:8,keyword_rank:undefined,z:3.2,cosine:0.8}),
               file("receipt-plan.txt",{z:0.4,cosine:0.2}),file("receipt-initial-word.txt",{z:0.4,cosine:0.2})]
            : request.meaning?words(request,0):lexical;
          const reply={hits,strong:hits.length,meaning:request.meaning&&mode==="ready",generation:request.generation,
            facets:{doc:hits.length},count_scope:"ranked_candidates",exact_filename_known:true,exact_filename:publication>=1,
            ...(request.meaning&&mode==="unavailable"?{semantic_error:"Synthetic accelerator unavailable"}:{})};
          if(!request.meaning&&window.holdNextWords){window.holdNextWords=false;return new Promise(resolve=>window.heldWords.push(()=>resolve(reply)));}
          return reply;
        }
        return old(command,args);
      };
    },{mode});
    await page.goto(base+"/"+view);assert.match(await page.title(),/DigUp/);
    await page.fill("#query","receipt");
    await page.waitForFunction(()=>state.finalGeneration===state.generation);
    await page.waitForFunction(()=>applicationSearch.finalEpoch===applicationSearch.epoch&&settingsSearch.finalEpoch===settingsSearch.epoch);
    const row=key=>page.locator('[data-result-key="'+key+'"]');
    const appKey="app:"+"1".repeat(64),settingKey="setting:fixture-receipt",oldKey="file:C:/docs/receipt-plan.txt",exactKey="file:C:/docs/receipt.txt";
    await row(appKey).waitFor({state:"visible"});await row(settingKey).waitFor({state:"visible"});await row(appKey).click();
    if(view==="index.html"){await page.locator("#details-action").click();await page.locator("#result-preview").waitFor({state:"visible"});await page.locator(".preview-back").focus();}
    else await row(appKey).locator(".app-launch").focus();
    const generation=await page.evaluate(()=>state.generation),selected=await page.evaluate(()=>state.selection);
    const before=await page.evaluate(()=>({meaning:calls.filter(c=>c.command==="ask"&&c.args.request.op==="search"&&c.args.request.meaning).length,
      prewarm:calls.filter(c=>c.command==="ask"&&c.args.request.op==="prewarm").length,apps:calls.filter(c=>c.command==="search_apps").length,settings:calls.filter(c=>c.command==="search_windows_settings").length}));
    await page.evaluate(view=>{window.savedFocus=document.activeElement;window.savedPreview=document.querySelector(view==="window.html"?"#side":"#result-preview").firstChild;
      window.published=1;emit("helper",{from:"search",event:{event:"search_index",state:"words_ready"}});},view);
    await row(exactKey).waitFor({state:view==="index.html"?"attached":"visible"});
    assert.equal(await page.evaluate(key=>resultLayout().rows.some(hit=>resultKey(hit)===key),exactKey),true,"Fresh names were absent from displayed result data");
    if(view==="index.html")assert.equal(await page.locator("#result-preview").isVisible(),true,"A name refresh closed selected app details");
    assert.equal(await row("file:C:/docs/receipt-initial-word.txt").count(),0,"A former keyword-only vector hit survived after its lexical match was removed");
    assert.equal(await page.evaluate(()=>state.generation),generation,"A name refresh started a new generation");
    assert.equal(await page.evaluate(()=>state.selection),selected,"A new exact filename replaced the chosen app");
    assert.equal(await page.evaluate(()=>savedFocus===document.activeElement),true,"Name publication lost focused app/details control");
    assert.equal(await page.evaluate(view=>savedPreview===document.querySelector(view==="window.html"?"#side":"#result-preview").firstChild,view),true,"Name publication rebuilt app details");
    assert.equal(await page.locator(".best-matches [data-result-key='"+appKey+"']").count(),1);
    assert.equal(await page.locator(".best-matches [data-result-key='"+exactKey+"']").count(),1,"An exact filename collision was hidden");
    assert.equal(await row(settingKey).count(),1,"File publication removed Windows settings results");
    if(mode==="ready")assert.equal(await row("file:C:/docs/unrelated-title.txt").count(),1,"Lexical refresh erased a semantic-only hit");
    else assert.match(await page.evaluate(()=>state.error),/accelerator unavailable/,"Name results cleared the persistent inference error");
    if(view==="index.html"){await page.locator(".preview-back").click();await row(exactKey).waitFor({state:"visible"});await page.locator("#query").focus();}
    else await page.locator("#query").focus();
    assert.equal(await page.evaluate(()=>state.selection),selected,"Back changed the selected application");
    await row(oldKey).click();
    if(view==="index.html"){await page.locator("#details-action").click();await page.locator(".preview-back").focus();}
    else await page.locator("#side .actions button").first().focus();
    await page.evaluate(view=>{window.savedFocus=document.activeElement;window.savedPreview=document.querySelector(view==="window.html"?"#side":"#result-preview").firstChild;
      window.savedChosen=structuredClone(state.chosen);window.published=2;emit("helper",{from:"search",event:{event:"search_index",state:"words_ready"}});},view);
    await row("file:C:/docs/receipt-notes.txt").waitFor({state:view==="index.html"?"attached":"visible"});
    assert.equal(await page.evaluate(()=>resultLayout().rows.some(hit=>hit.path==="C:/docs/receipt-notes.txt")),true);
    if(view==="index.html")assert.equal(await page.locator("#result-preview").isVisible(),true,"A name refresh closed selected file details");
    assert.equal(await page.evaluate(()=>state.selection),oldKey);
    assert.deepEqual(await page.evaluate(()=>state.chosen),await page.evaluate(()=>savedChosen),"Fresh name metadata redirected the chosen file");
    assert.equal(await page.evaluate(()=>savedFocus===document.activeElement),true);
    assert.equal(await page.evaluate(view=>savedPreview===document.querySelector(view==="window.html"?"#side":"#result-preview").firstChild,view),true,"Name refresh rebuilt the selected file preview");
    await page.press("#query","Enter");
    assert.equal(await page.evaluate(()=>calls.filter(c=>c.command==="open_path").at(-1).args.path),"C:/docs/receipt-plan.txt");
    await row("file:C:/docs/receipt-notes.txt").waitFor({state:"visible"});
    await page.evaluate(()=>{window.holdNextWords=true;window.published=5;emit("helper",{from:"search",event:{event:"search_index",state:"words_ready"}});});
    await page.waitForFunction(()=>heldWords.length===1);
    await page.evaluate(()=>{window.holdNextWords=true;window.published=6;emit("helper",{from:"search",event:{event:"search_index",state:"words_ready"}});});
    await page.waitForFunction(()=>heldWords.length===2);
    await page.evaluate(()=>heldWords.shift()());
    await row("file:C:/docs/receipt-intermediate-refresh.txt").waitFor({state:"visible"});
    assert.equal(await page.evaluate(()=>heldWords.length),1,"The newer lexical request should remain pending");
    assert.equal(await page.evaluate(()=>state.selection),oldKey,"Continuous publication moved the chosen file");
    await page.evaluate(()=>heldWords.splice(0).forEach(release=>release()));
    await row("file:C:/docs/receipt-intermediate-refresh.txt").waitFor({state:"detached"});
    await page.evaluate(()=>{window.holdNextWords=true;window.published=3;emit("helper",{from:"search",event:{event:"search_index",state:"words_ready"}});});
    await page.waitForFunction(()=>heldWords.length===1);
    await page.evaluate(()=>{window.published=4;emit("helper",{from:"search",event:{event:"search_index",state:"words_ready"}});});
    await row("file:C:/docs/receipt-current-publication.txt").waitFor({state:"visible"});
    await page.evaluate(()=>heldWords.splice(0).forEach(release=>release()));await page.waitForTimeout(80);
    assert.equal(await row("file:C:/docs/receipt-obsolete-refresh.txt").count(),0,"An older lexical completion replaced the current index publication");
    assert.equal(await row("file:C:/docs/receipt-latest-refresh.txt").count(),1);
    await page.evaluate(()=>{window.published=2;emit("helper",{from:"search",event:{event:"search_index",state:"words_ready"}});});
    await row("file:C:/docs/receipt-latest-refresh.txt").waitFor({state:"detached"});
    assert.equal(await page.evaluate(()=>state.selection),oldKey,"A lexical removal moved an unaffected chosen file");
    if(mode==="ready")assert.equal(await row("file:C:/docs/unrelated-title.txt").count(),1,"Removing a lexical-only row erased semantic content");
    const after=await page.evaluate(()=>({meaning:calls.filter(c=>c.command==="ask"&&c.args.request.op==="search"&&c.args.request.meaning).length,
      prewarm:calls.filter(c=>c.command==="ask"&&c.args.request.op==="prewarm").length,apps:calls.filter(c=>c.command==="search_apps").length,settings:calls.filter(c=>c.command==="search_windows_settings").length}));
    assert.deepEqual(after,before,"A words-only index publication woke inference or restarted a native provider");
    const keys=await page.locator("[data-result-key]").evaluateAll(nodes=>nodes.map(node=>node.dataset.resultKey));
    assert.equal(keys.length,new Set(keys).size,"A file was displayed twice after merging providers");
    if(view==="window.html"){
      await page.evaluate(()=>{window.published=0;});await page.locator('#kinds [data-title="Documents"]').click();
      await page.waitForFunction(()=>state.finalGeneration===state.generation&&state.filter==="documents");
      await row(oldKey).click();await page.locator('#kinds [data-title="Documents"]').focus();
      const meaning=await page.evaluate(()=>calls.filter(c=>c.command==="ask"&&c.args.request.op==="search"&&c.args.request.meaning).length);
      await page.evaluate(()=>{window.published=2;emit("helper",{from:"search",event:{event:"search_index",state:"words_ready"}});});
      await row("file:C:/docs/receipt-notes.txt").waitFor({state:"visible"});
      assert.equal(await page.evaluate(()=>state.filter),"documents");
      assert.equal(await page.locator('#kinds [data-title="Documents"]').getAttribute("aria-pressed"),"true");
      assert.equal(await page.evaluate(()=>document.activeElement.dataset.title),"Documents","Updated counts lost the focused filter");
      assert.equal(await page.evaluate(()=>state.selection),oldKey);
      const expected=await page.evaluate(()=>state.ranked.filter(hit=>["doc","pdf"].includes(hit.kind)).length);
      assert.equal(Number(await page.locator('#kinds [data-title="Documents"] .number').textContent()),expected);
      if(mode==="ready")assert.match(await page.locator('#kinds [data-title="Documents"]').getAttribute("title"),/displayed matching files/);
      assert.equal(await page.evaluate(()=>calls.filter(c=>c.command==="ask"&&c.args.request.op==="search"&&c.args.request.meaning).length),meaning);
      assert.ok(await page.evaluate(()=>calls.some(c=>c.command==="ask"&&c.args.request.op==="search"&&!c.args.request.meaning&&c.args.request.kinds?.includes("pdf"))));
    }
    await page.evaluate(()=>{window.holdNextWords=true;window.published=3;emit("helper",{from:"search",event:{event:"search_index",state:"words_ready"}});});
    await page.waitForFunction(()=>heldWords.length===1);await page.fill("#query","new phrase");
    await page.waitForFunction(()=>state.finalGeneration===state.generation);
    await page.evaluate(()=>heldWords.splice(0).forEach(release=>release()));await page.waitForTimeout(80);
    assert.equal(await row("file:C:/docs/receipt-obsolete-refresh.txt").count(),0,"A previous generation restored its files");
    assert.equal(await row("file:C:/docs/new-query.txt").count(),1);
    await page.emulateMedia({colorScheme:"dark"});await page.setViewportSize({width:700,height:700});
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
    assert.deepEqual(errors,[]);await page.close();
  }
  console.log("PASS: words_ready publishes fresh names after semantic success/unavailability; semantic hits, exact collisions, selected app/file details, focus, filters, deduplication and stale guards survive without encoding");
})().finally(async()=>{await browser?.close();}).catch(error=>{console.error(error);process.exit(1);});
