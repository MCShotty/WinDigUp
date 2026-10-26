"use strict";
const {chromium}=require("playwright");
const assert=require("node:assert/strict");
const fs=require("node:fs"),path=require("node:path");
const {setup}=require("./application-fixtures.cjs");
const base=process.env.DIGUP_UI_URL||"http://127.0.0.1:8765";
let browser;
(async()=>{
  browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||"/usr/bin/chromium",
    headless:true,args:["--no-sandbox","--disable-dev-shm-usage"]});
  const page=await browser.newPage({viewport:{width:760,height:800}});
  const errors=[];
  page.on("pageerror",error=>errors.push(error.message));
  await setup(page);
  await page.addInitScript(()=>{
    window.pipelineFixture={schemaVersion:2,epoch:"synthetic-fixture",capturedAt:1,blockedBy:"publication_backpressure",
      capacity:8,preparationWorkers:2,inferenceWorkers:3,readyJobs:3,runningJobs:2,completedJobs:2,
      queueBuildMs:10,queueFetchMs:5,preparationMs:100,inferenceInputWaitMs:20,inferenceMs:250,
      commitMs:30,cleanupMs:5,notificationMs:1,queueRows:256,peakBufferedRecords:128,
      peakResidentJobs:8,peakPreparedBytes:1048576,peakScratchBytes:2097152};
    const old=window.__TAURI__.core.invoke;
    window.__TAURI__.core.invoke=async(command,args={})=>{
      const reply=await old(command,args);
      if(command==="activity_snapshot"){
        reply.files.phase=window.pipelinePhase||"indexing";reply.files.pipeline={files:structuredClone(window.pipelineFixture)};
        reply.files.paused=Boolean(window.pausedFixture);
        reply.inference.model={state:"ready"};
      }
      return reply;
    };
  });
  await page.goto(base+"/settings.html?tab=activity");
  assert.equal(await page.title(),"DigUp Settings");
  const section=page.locator('[data-key="indexing-work"]');
  await section.waitFor({state:"visible"});
  assert.match(await section.innerText(),/Waiting for earlier results to be saved/);
  assert.match(await section.innerText(),/3 ready · 2 inference requests · 2 awaiting publication/);
  const detail=section.locator("details");
  await detail.locator("summary").click();
  await detail.locator("summary").focus();
  await page.evaluate(()=>{
    window.savedPipelineDetails=document.querySelector('[data-key="indexing-work"] details');
    window.pipelineFixture.readyJobs=2;window.pipelineFixture.blockedBy="preparing";
    emit("helper",{from:"index",event:{event:"index_pipeline"}});
  });
  await page.waitForFunction(()=>document.querySelector('[data-key="indexing-work"]').textContent.includes("2 ready"));
  assert.equal(await detail.getAttribute("open"),"");
  assert.equal(await page.evaluate(()=>window.savedPipelineDetails===document.querySelector('[data-key="indexing-work"] details')),true);
  assert.equal(await detail.locator("summary").evaluate(node=>node===document.activeElement),true);
  assert.match(await section.innerText(),/Metadata records loaded/);
  assert.match(await section.innerText(),/256/);
  for(const theme of ["light","dark"])for(const width of [440,760,1120]){
    await page.setViewportSize({width,height:800});
    await page.evaluate(theme=>AppearanceUI.apply(theme),theme);
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  }
  await page.evaluate(()=>{window.pausedFixture=true;emit("state",{});});
  await page.waitForFunction(()=>document.querySelector('[data-key="indexing-work"]').textContent.includes("Indexing paused"));
  await page.evaluate(()=>{window.pausedFixture=false;window.pipelineFixture.blockedBy="failed";emit("state",{});});
  await page.waitForFunction(()=>document.querySelector('[data-key="indexing-work"]').textContent.includes("Indexing needs attention"));
  await page.evaluate(()=>{window.pipelineFixture.schemaVersion=1;emit("state",{});});
  await section.waitFor({state:"hidden"});
  await page.evaluate(()=>{window.pipelineFixture.schemaVersion=2;emit("state",{});});
  await section.waitFor({state:"visible"});
  for(const [phase,label] of [["failed","Indexing failed"],["stopped","File worker stopped"],["unavailable","File inference unavailable"]]){
    await page.evaluate(phase=>{window.pipelinePhase=phase;window.pipelineFixture.blockedBy="running";emit("state",{});},phase);
    await page.waitForFunction(label=>document.querySelector('[data-key="indexing-work"]').textContent.includes(label),label);
    assert.match(await section.locator(":scope > p").nth(1).innerText(),/Last reported:/);
    assert.ok(!(await section.locator(":scope > p").first().innerText()).includes("Inference requests in progress"));
  }
  await page.evaluate(()=>{window.pipelinePhase="unavailable";window.pipelineFixture.runningJobs=null;emit("state",{});});
  await page.waitForFunction(()=>document.querySelector('[data-key="indexing-work"]').textContent.includes("Not reported inference requests"));
  await page.evaluate(()=>{window.pipelinePhase="indexing";window.pipelineFixture.runningJobs=2;emit("state",{});});
  await page.emulateMedia({forcedColors:"active",reducedMotion:"reduce"});
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  await page.emulateMedia({forcedColors:"none",reducedMotion:"no-preference"});
  const directory=process.env.DIGUP_ACTIVITY_SCREENSHOTS;
  if(directory){
    await page.setViewportSize({width:760,height:1000});
    await page.evaluate(()=>{
      window.pipelineFixture.blockedBy="running";
      const label=document.createElement("p");label.textContent="Synthetic UI fixture; no hardware measurements.";
      document.querySelector('[data-key="indexing-work"]').prepend(label);emit("state",{});
    });
    await page.waitForFunction(()=>document.querySelector('[data-key="indexing-work"]').textContent.includes("Inference requests in progress"));
    await section.scrollIntoViewIfNeeded();
    fs.mkdirSync(directory,{recursive:true});
    await section.screenshot({path:path.join(directory,"indexing-pipeline.png")});
  }
  assert.deepEqual(errors,[]);
  await browser.close();
  console.log("PASS: pipeline reasons, measured fields, stable expanded details and focus, pause/failure, schema compatibility, themes, scaling and contrast mode.");
})().catch(async error=>{console.error(error);if(browser)await browser.close();process.exit(1);});
