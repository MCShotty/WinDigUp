"use strict";
const {chromium} = require("playwright");
const assert = require("node:assert/strict");
const {setup} = require("./application-fixtures.cjs");
const base = process.env.DIGUP_UI_URL || "http://127.0.0.1:8765";
(async () => {
  const browser = await chromium.launch({executablePath:process.env.DIGUP_CHROME || "/usr/bin/chromium",
    headless:true,args:["--no-sandbox","--disable-dev-shm-usage"]});
  try {
    for (const view of ["window.html","index.html"]) {
      const page = await browser.newPage({viewport:{width:1120,height:800}});
      const errors=[]; page.on("pageerror",error=>errors.push(error.message));
      await setup(page);
      await page.addInitScript(() => {
        const old=window.__TAURI__.core.invoke;
        window.personalizationEnabled=true;window.feedbackFailure=false;
        window.__TAURI__.core.invoke=async(command,args={})=>{
          if(command==="useful_result"){
            window.calls.push({command,args});
            if(window.feedbackFailure)throw new Error("This result is no longer current");
            return {saved:true};
          }
          const reply=await old(command,args);
          if(command==="search_apps"||command==="ask"&&args.request.op==="search") {
            for(const hit of reply.hits||[]) {
              hit.matchSource=hit.resultType==="application"?(hit.reason==="semantic"?"purpose":"alias"):"name";
              if(window.personalizationEnabled)hit.feedbackToken="fixture-"+(hit.id||hit.path);
              else delete hit.feedbackToken;
              if(hit.path){hit.availability="unknown";hit.availability_stale=true;}
            }
          }
          return reply;
        };
      });
      await page.goto(base+"/"+view);
      await page.fill("#query","photos");
      await page.waitForSelector('[data-result-key^="app:"]');
      const root=view==="window.html"?"#content":"#list";
      await page.locator(root+' [data-result-key^="app:"]').first().click();
      if(view==="index.html")await page.click("#details-action");
      const details=view==="window.html"?"#side":"#result-preview";
      const useful=page.locator(details+" .relevance-feedback").first();
      await useful.waitFor();
      assert.equal(await useful.textContent(),"Useful result");
      assert.ok((await page.locator(details).textContent()).includes("Alias match"));
      const selected=await page.evaluate(()=>state.selection);
      await useful.click();
      assert.equal(await useful.textContent(),"Feedback saved");
      assert.equal(await useful.isDisabled(),true);
      assert.equal(await page.evaluate(()=>state.selection),selected);
      assert.equal(await page.evaluate(()=>window.calls.filter(call=>call.command==="useful_result").length),1);
      await page.waitForTimeout(850);
      assert.equal(await page.evaluate(()=>state.selection),selected,"Delayed purpose reply changed the chosen result");
      if(view==="index.html")await page.click(".preview-back");
      await page.fill("#query","portrait");
      await page.waitForSelector(root+' [data-result-key^="app:"]');
      await page.locator(root+' [data-result-key^="app:"]').first().click();
      if(view==="index.html")await page.click("#details-action");
      await page.evaluate(()=>{window.feedbackFailure=true;});
      const failure=page.locator(details+" .relevance-feedback").first();
      await failure.click();
      assert.equal(await failure.isDisabled(),false);
      assert.equal(await page.evaluate(()=>state.selection),await page.locator(root+" .selected").first().getAttribute("data-result-key"));
      if(view==="index.html")await page.click(".preview-back");
      await page.evaluate(()=>{window.feedbackFailure=false;window.personalizationEnabled=false;});
      await page.fill("#query","photos");
      await page.waitForSelector(root+' [data-result-key^="app:"]');
      await page.locator(root+' [data-result-key^="app:"]').first().click();
      if(view==="index.html")await page.click("#details-action");
      assert.equal(await page.locator(details+" .relevance-feedback").count(),0);
      assert.deepEqual(errors,[]);
      await page.close();
    }
    console.log("PASS: both search views show structured match reasons, accept explicit feedback once, preserve selection through delayed replies, recover feedback errors and hide feedback when disabled");
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
