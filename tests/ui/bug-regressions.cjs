// Cross-feature regressions: real pages with a deterministic native boundary.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const {setup}=require('./application-fixtures.cjs');
const base=process.env.DIGUP_UI_URL||'http://127.0.0.1:8765';
let browser;
(async()=>{
  browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||'/usr/bin/chromium',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
  const errors=[],failures=[];
  async function check(name,body){
    const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));await setup(page);
    try{await body(page);console.log('PASS:',name);}catch(error){failures.push(name+': '+error.message);}finally{await page.close();}
  }
  await check('Keyboard activation belongs to the focused settings and pagination controls',async page=>{
    await page.goto(base+'/window.html');await page.fill('#query','apps:');await page.waitForSelector('.app-row');
    await page.locator('#settings').focus();await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='launch_app').length),0,'Settings launched the selected app');
    assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='open_settings').length),1);
    await page.getByRole('button',{name:'Show more applications',exact:true}).focus();await page.keyboard.press('Enter');
    await page.waitForFunction(()=>document.querySelectorAll('.app-row').length===150);
    assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='launch_app').length),0,'Pagination launched an app');
    await page.locator('#query').focus();await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='launch_app').length),1,'Query Enter must still launch');
  });
  await check('Code-only setup displays code results without requiring general folders',async page=>{
    await page.addInitScript(()=>{
      const old=window.__TAURI__.core.invoke;
      window.__TAURI__.core.invoke=async(c,a)=>{
        const result=await old(c,a);
        if(c==='window_info')return {...result,folders:[],hasCode:true};
        if(c==='ask'&&a.request.op==='search')return {...result,hits:result.hits.map(h=>({...h,kind:'code',segment:'lines',path:'C:/src/main.rs',loc:1,loc_end:4}))};
        return result;
      };
    });
    await page.goto(base+'/window.html');await page.fill('#query','code: photo');
    await page.waitForFunction(()=>window.calls.some(c=>c.command==='ask'&&c.args.request.op==='search'));
    await page.waitForTimeout(400);
    assert.match(await page.locator('#content').textContent(),/main.rs/,'Valid code results were hidden by folder setup');
  });
  await check('A failed obsolete file search cannot overwrite a newer app search',async page=>{
    await page.addInitScript(()=>{
      const old=window.__TAURI__.core.invoke;window.rejectSearches=[];
      window.__TAURI__.core.invoke=(c,a)=>c==='ask'&&a.request.op==='search'&&a.request.q==='obsolete'
        ?new Promise((_,reject)=>window.rejectSearches.push(reject)):old(c,a);
    });
    await page.goto(base+'/index.html');await page.fill('#query','obsolete');
    await page.waitForFunction(()=>window.rejectSearches.length>0);
    await page.fill('#query','apps: photo');await page.waitForSelector('.app-row');
    await page.evaluate(()=>window.rejectSearches.forEach(reject=>reject('Obsolete helper error')));
    await page.waitForTimeout(100);
    assert.ok(!(await page.locator('#footer').textContent()).includes('Obsolete helper error'));
    await page.press('#query','Enter');
    assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='launch_app').length),1);
  });
  await check('A failed file search ends its spinner and leaves app launching available',async page=>{
    await page.goto(base+'/window.html');await page.evaluate(()=>window.fileMode='failed');
    await page.fill('#query','no matching applications');
    await page.waitForFunction(()=>document.querySelector('#count').textContent.includes('File helper unavailable'));
    assert.equal(await page.locator('#content .spinner').count(),0,'A finished failure was still shown as loading');
    assert.match(await page.locator('#content').textContent(),/File search unavailable/);
    await page.fill('#query','photo');await page.waitForSelector('.app-row');
    await page.getByRole('button',{name:'Retry file search',exact:true}).waitFor();
    await page.press('#query','Enter');
    assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='launch_app').length),1);
    await page.evaluate(()=>window.fileMode='ready');
    await page.getByRole('button',{name:'Retry file search',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#content').textContent.includes('photos.txt'));
  });
  assert.deepEqual(errors,[]);assert.deepEqual(failures,[]);
  await browser.close();
})().catch(async error=>{console.error(error);if(browser)await browser.close();process.exit(1)});
