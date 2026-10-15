// Actual UI, fake native boundary. No model inference is required to inspect activity or launch apps.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {setup}=require('./application-fixtures.cjs');
const base=process.env.DIGUP_UI_URL||'http://127.0.0.1:8765';
let browser;
(async()=>{
  browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||'/usr/bin/chromium',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
  const page=await browser.newPage({viewport:{width:1440,height:1024}}),errors=[];
  page.on('pageerror',e=>{errors.push(e.message);console.error(e.stack);});
  await setup(page);
  await page.addInitScript(()=>{
    const old=window.__TAURI__.core.invoke;
    const time=Date.now()/1000;
    window.fixtureActivity={schemaVersion:1,capturedAt:time,
      files:{schemaVersion:1,phase:'discovering',knownFiles:0,searchable:0,pending:0,unfinished:0,done:null,total:null,
        entriesChecked:443831,candidates:107857,candidatesFinal:false,root:'C:/Users/Test/Desktop',path:'C:/Users/Test/Desktop/Projects',
        lastEventAt:time,lastProgressAt:time,phaseStartedAt:time-50,paused:false,skipped:{},skippedFolders:{},missing:[],unreadable:[]},
      applications:{schemaVersion:1,catalog:{supported:true,enabled:true,semanticEnabled:true,count:663,sourceErrors:{}},
        purpose:{state:'ready',embedded:663,total:663,encoder:'ready'}},
      inference:{schemaVersion:1,configured:{backend:'vulkan'},verified:{device:'AMD Radeon RX 7900 XTX',at:time,executionPolicy:'accelerator-only'},encoder:'ready',model:{state:'ready'}},
      helpers:{schemaVersion:1,index:{pid:123},search:{pid:456,pending:0}},events:[]};
    window.activityError=false;
    window.__TAURI__.core.invoke=async(command,args={})=>{
      if(command==='activity_snapshot'){
        window.calls.push({command,args}); if(window.activityError)throw 'Native status temporarily unavailable';
        return structuredClone(window.fixtureActivity);
      }
      if(command==='indexing_diagnostics'){
        window.calls.push({command,args});
        return JSON.stringify({build:'fixture',folders:['C:/Users/Test/Documents العربية'],index:'C:/Users/Test/AppData/index',
          error:'database is locked',unc:'\\\\server\\private share\\notes.txt'},null,2)+'\n\n--- worker.log ---\nCould not open C:\\Users\\Test\\Documents العربية\\file.txt\n';
      }
      if(command==='export_diagnostics'){window.calls.push({command,args});return {saved:true};}
      if(command==='pause_indexing'){
        window.calls.push({command,args});window.fixtureActivity.files.paused=args.paused;
        window.fixtureActivity.files.phase=args.paused?'pausing':'discovering';return;
      }
      return old(command,args);
    };
  });
  await page.goto(base+'/window.html');
  assert.equal(await page.title(),'DigUp');
  await page.fill('#query','apps: photo');await page.waitForSelector('.app-row');
  await page.evaluate(()=>{window.calls=[];window.fileMode='blocked';});
  await page.click('#status-line');
  await page.waitForFunction(()=>document.querySelector('[data-key="first-value"]').textContent==='443,831');
  assert.match(await page.locator('.activity-view').textContent(),/Discovering files/);
  assert.match(await page.locator('.activity-view').textContent(),/107,857/);
  assert.match(await page.locator('[data-key="purpose"]').textContent(),/663 \/ 663 ready/);
  assert.equal(await page.locator('.activity-meter').getAttribute('aria-valuenow'),null);
  assert.equal(await page.evaluate(()=>window.calls.some(c=>c.command==='indexing_diagnostics'||c.command==='ask')),false);
  assert.equal(await page.locator('#side .app-details').count(),0);
  await page.press('#query','Enter');
  assert.equal(await page.evaluate(()=>window.calls.some(c=>c.command==='launch_app')),true);
  await page.locator('[data-tab="diagnostics"]').click();
  assert.equal(await page.evaluate(()=>window.calls.some(c=>c.command==='indexing_diagnostics')),false,'Opening diagnostics loaded logs');
  await page.locator('.activity-technical summary').click();
  await page.getByRole('button',{name:'Preview diagnostic report…'}).click();
  await page.waitForFunction(()=>document.querySelector('#index-diagnostics-text').value.includes('database is locked'));
  const redacted=await page.locator('#index-diagnostics-text').inputValue();
  assert.ok(!redacted.includes('Documents العربية')&&!redacted.includes('private share'));
  await page.click('#index-diagnostics-export');
  assert.equal(await page.evaluate(()=>window.calls.find(c=>c.command==='export_diagnostics').args.report),redacted);
  await page.uncheck('#diagnostics-redact');
  assert.match(await page.locator('#index-diagnostics-text').inputValue(),/Documents العربية/);
  await page.click('#index-diagnostics-copy');
  await page.waitForFunction(()=>document.querySelector('#index-diagnostics-message').textContent.length>0);
  await page.press('#index-diagnostics-text','ArrowDown');
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='launch_app').length),1,'Report keys reached launcher');
  await page.click('#index-diagnostics-close');
  await page.locator('[data-tab="overview"]').click();
  await page.locator('[data-key="pause"]').click();
  await page.waitForFunction(()=>document.querySelector('[data-key="phase"]').textContent==='Pausing indexing…');
  assert.equal(await page.locator('[data-key="pause"]').isDisabled(),true);
  await page.evaluate(async()=>{window.fixtureActivity.files.phase='paused';window.fixtureActivity.helpers.index={running:false};await ActivityUI.refresh();});
  assert.match(await page.locator('[data-key="pause"]').textContent(),/Resume indexing/);
  await page.locator('[data-key="pause"]').click();
  await page.waitForFunction(()=>document.querySelector('[data-key="phase"]').textContent==='Discovering files');
  await page.evaluate(async()=>{Object.assign(window.fixtureActivity.files,{phase:'indexing',knownFiles:108,searchable:8,pending:100,done:8,total:108,candidatesFinal:true});await ActivityUI.refresh();});
  assert.equal(await page.locator('.activity-meter').getAttribute('aria-valuenow'),'8');
  await page.evaluate(async()=>{Object.assign(window.fixtureActivity.files,{phase:'discovering',done:null,total:null});await ActivityUI.refresh();});
  await page.locator('[data-key="file-details"] summary').click();
  assert.equal(await page.locator('[data-key="searchable"]').textContent(),'8','Rescan lost existing searchable count');
  await page.evaluate(async()=>{window.activityError=true;await ActivityUI.refresh();});
  assert.match(await page.locator('[data-key="connection"]').textContent(),/last received snapshot/);
  assert.equal(await page.locator('[data-key="searchable"]').textContent(),'8');
  await page.evaluate(async()=>{window.activityError=false;Object.assign(window.fixtureActivity.files,{phase:'failed',error:'database is locked'});
    window.fixtureActivity.applications.catalog.sourceErrors={commonPrograms:'access denied'};await ActivityUI.refresh();});
  await page.locator('[data-tab="diagnostics"]').click();
  assert.match(await page.locator('[data-key="health-detail"]').textContent(),/database is locked/);
  assert.match(await page.locator('[data-key="health-detail"]').textContent(),/access denied/);
  assert.match(await page.locator('[data-key="health-catalog"]').textContent(),/663/);
  await page.locator('[data-key="close"]').click();
  assert.equal(await page.locator('body').evaluate(el=>el.classList.contains('activity-open')),false);
  assert.equal(await page.locator('#side .app-details').count(),1);

  await page.goto(base+'/settings.html?tab=folders');
  await page.waitForFunction(()=>window.calls.some(c=>c.command==='settings_info'));
  await page.evaluate(()=>window.emit('state',{activity:'scanning',line:'Scanning folders…',searchable:0,files:0,model:{state:'ready'},scan:{event:'scan_progress',visited:443831,candidates:107857}}));
  assert.match(await page.locator('#status-detail').textContent(),/Preparing the first file index/);
  assert.ok(!(await page.locator('#status-detail').textContent()).includes('0 of 0'));
  await page.click('#index-diagnostics');
  await page.waitForFunction(()=>document.querySelector('[data-key="health-purpose"]').textContent.includes('663'));
  await page.locator('[data-tab="overview"]').click();
  if(process.env.DIGUP_ACTIVITY_SCREENSHOTS){
    const dir=process.env.DIGUP_ACTIVITY_SCREENSHOTS;fs.mkdirSync(dir,{recursive:true});
    await page.setViewportSize({width:660,height:620});await page.screenshot({path:dir+'/activity-settings.png'});
    await page.goto(base+'/window.html');await page.fill('#query','apps: photo');await page.waitForSelector('.app-row');await page.click('#status-line');
    await page.waitForFunction(()=>document.querySelector('[data-key="first-value"]').textContent==='443,831');
    await page.setViewportSize({width:1440,height:1024});await page.screenshot({path:dir+'/activity-desktop.png'});
    await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:dir+'/activity-dark.png'});
    await page.setViewportSize({width:800,height:650});await page.screenshot({path:dir+'/activity-narrow.png'});
    assert.equal(await page.locator('#content').isVisible(),false);
  }
  assert.deepEqual(errors,[]);
  console.log('PASS: activity is independent of helpers; discovery/rescan/pause/error states, on-demand logs, redaction/export, keyboard isolation and Settings integration');
  await browser.close();
})().catch(async e=>{console.error(e);if(browser)await browser.close();process.exit(1)});
