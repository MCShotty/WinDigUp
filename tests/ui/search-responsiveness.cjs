// Real pages, synthetic native boundary. Scheduling/UX evidence only; no model or physical GPU is exercised.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {setup}=require('./application-fixtures.cjs');
const base=process.env.DIGUP_UI_URL||'http://127.0.0.1:8765';
let browser;
(async()=>{
  browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||'/usr/bin/chromium',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
  const page=await browser.newPage({viewport:{width:1120,height:800}}),errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await setup(page);
  await page.addInitScript(()=>{
    window.mixed='smart';window.collision=false;window.blockMeaning=true;window.delayed=[];
    window.releaseMeaning=()=>{window.blockMeaning=false;window.delayed.splice(0).forEach(done=>done());};
    const old=window.__TAURI__.core.invoke;
    const catalog=()=>({enabled:true,supported:true,semanticEnabled:true,count:4,revision:'search-fixture',mixedSearch:window.mixed});
    const app=(id,name,reason='prefix')=>({id:`app:${id.repeat(64)}`,resultType:'application',kind:'app',name,reason,
      publisher:'Example Software',description:'A browser for websites and online documents',aliases:[],hidden:false});
    const file=(q,meaning)=>({...{path:window.collision?'C:/docs/Firefox.txt':'C:/docs/Project notes.txt',kind:'doc',segment:'chunk',segment_id:1,
      modified:1,size:50,info:{},excerpt:`Project notes for ${q}`,score:5,keyword_rank:1},
      ...(q==='page test'?{path:'C:/docs/report.pdf',kind:'pdf',segment:'page',loc:2}:{}),...(meaning?window.replacement||{}:{})});
    window.__TAURI__.core.invoke=async(command,args={})=>{
      if(command==='window_info')return {...await old(command,args),applications:catalog()};
      if(command==='search_apps'){
        window.calls.push({command,args});
        const q=args.q.toLowerCase();
        const reply=()=>{
          const hits=!q?[app('1','Firefox'),app('2','Photos'),app('3','Studio'),app('4','Studio')]
            :q==='edit photos'?(args.meaning?[{...app('5','Portrait Editor','semantic'),description:'Retouch portraits and correct color'}]:[])
            :q==='studio'?[app('3','Studio','exact'),app('4','Studio','exact')]
            :[app('1',q==='photos'?'Photos':'Firefox',q==='firefox'||q==='photos'?'exact':'prefix')];
          return {generation:args.generation,hits:window.mixed==='apps-only'&&args.limit===3?[]:hits,total:hits.length,
            catalog:catalog(),semantic:{state:'ready',encoder:'ready',total:4,embedded:4}};
        };
        if(args.meaning&&window.blockMeaning)await new Promise(resolve=>window.delayed.push(resolve));
        return reply();
      }
      if(command==='ask'&&args.request.op==='search'){
        window.calls.push({command,args});
        if(args.request.meaning&&window.blockMeaning)await new Promise(resolve=>window.delayed.push(resolve));
        else await new Promise(resolve=>setTimeout(resolve,5));
        return {hits:[file(args.request.q,args.request.meaning)],strong:1,meaning:args.request.meaning,generation:args.request.generation,
          ms:{queue:1,encode:args.request.meaning?4:0,scoring:1,metadata:1},facets:{doc:1}};
      }
      return old(command,args);
    };
  });
  await page.goto(base+'/window.html');
  assert.match(await page.title(),/DigUp/);
  await page.fill('#query','invoice');await page.waitForSelector('.cell');await page.waitForSelector('.app-row');
  assert.equal(await page.locator('.best-matches .cell').count(),1);
  assert.equal(await page.evaluate(()=>window.calls.some(call=>call.command==='ask'&&call.args.request.op==='embed_ahead')),false);
  await page.waitForTimeout(160);assert.ok(await page.evaluate(()=>window.delayed.length>=1));
  await page.locator('.cell').click();
  await page.evaluate(()=>{window.savedCell=document.querySelector('.cell');window.savedPreview=document.querySelector('#side').firstChild;
    for(let n=0;n<5;n++)window.emit('applications-progress',{state:'preparing',encoder:'ready',revision:'search-fixture',total:4,embedded:n});});
  await page.waitForTimeout(100);
  assert.equal(await page.evaluate(()=>window.savedCell===document.querySelector('.cell')),true,'App progress rebuilt file results');
  assert.equal(await page.evaluate(()=>window.savedPreview===document.querySelector('#side').firstChild),true,'App progress reset the selected preview');
  await page.press('#query','Enter');assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='open_path').length),1);
  await page.evaluate(()=>{window.replacement={path:'C:/docs/Other note.txt'};window.releaseMeaning();});
  await page.waitForFunction(()=>document.querySelector('.cell .name')?.textContent.includes('Other note.txt'));
  await page.press('#query','Enter');
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='open_path').length),1,'A delayed replacement redirected Enter to another file');
  await page.evaluate(()=>{window.replacement=null;window.blockMeaning=true;});
  await page.fill('#query','page test');await page.waitForSelector('.cell');await page.locator('.cell').click();
  await page.press('#query','Enter');
  await page.evaluate(()=>{window.replacement={loc:7};window.releaseMeaning();});
  await page.waitForFunction(()=>state.meaning===true&&state.ranked[0]?.loc===7);
  await page.press('#query','Enter');
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='open_path').at(-1).args.page),2,'A delayed segment update redirected the selected PDF page');
  await page.evaluate(()=>{window.replacement=null;window.blockMeaning=true;});
  await page.fill('#query','Firefox');await page.waitForFunction(()=>document.querySelector('.app-group-title')?.textContent==='Best matches');
  await page.waitForSelector('.cell');
  assert.ok(await page.evaluate(()=>document.querySelector('.app-row').compareDocumentPosition(document.querySelector('.cell'))&Node.DOCUMENT_POSITION_FOLLOWING));
  await page.evaluate(()=>{window.collision=true;});await page.fill('#query','Firefox ');
  await page.waitForFunction(()=>document.querySelector('.cell .name')?.textContent.includes('Firefox.txt'));
  assert.equal(await page.locator('.best-matches .cell').count(),1,'Exact filenames must remain alongside exact apps');
  assert.equal(await page.locator('.best-matches .app-row').count(),1);
  await page.evaluate(()=>{window.collision=false;});await page.fill('#query','photos');await page.waitForSelector('.cell');
  assert.match(await page.locator('.best-matches .app-row').first().textContent(),/Photos/,'A bare category term must not suppress an exact app');
  await page.fill('#query','Studio');await page.waitForFunction(()=>document.querySelectorAll('.app-row').length===2);
  assert.equal(await page.locator('.best-matches .app-row').count(),2,'Ambiguous exact names must remain together');
  await page.fill('#query','Firefox');await page.waitForFunction(()=>state.lexicalReady&&document.querySelector('.app-group-title')?.textContent==='Best matches');
  await page.evaluate(()=>{window.mixed='files-first';window.emit('applications',{enabled:true,supported:true,semanticEnabled:true,mixedSearch:'files-first',revision:'search-fixture'});});
  await page.waitForFunction(()=>document.querySelector('.app-group:not(.best-matches) .app-group-title')?.textContent==='Apps');
  await page.evaluate(()=>{window.mixed='apps-only';window.emit('applications',{enabled:true,supported:true,semanticEnabled:true,mixedSearch:'apps-only',revision:'search-fixture'});});
  await page.waitForFunction(()=>state.lexicalReady&&document.querySelectorAll('.app-row').length===0);
  assert.equal(await page.locator('.cell').count(),1);
  await page.getByRole('button',{name:/^Apps/}).click();await page.waitForSelector('.app-row');
  await page.fill('#query','apps:');await page.waitForFunction(()=>document.querySelectorAll('.app-row').length===4);
  assert.match(await page.locator('.app-row').first().textContent(),/Firefox/);
  await page.evaluate(()=>{window.releaseMeaning();window.mixed='smart';window.emit('applications',{enabled:true,supported:true,semanticEnabled:true,mixedSearch:'smart',revision:'search-fixture'});});
  await page.fill('#query','apps: edit photos');await page.waitForFunction(()=>document.querySelector('.app-row')?.textContent.includes('Portrait Editor'));
  assert.match(await page.locator('.app-row').textContent(),/Purpose match/);
  await page.getByRole('button',{name:'All',exact:false}).first().click();
  await page.waitForSelector('.cell');await page.waitForSelector('.app-row');
  assert.equal(await page.locator('.best-matches .cell').count(),1);
  await page.waitForFunction(()=>window.calls.some(c=>c.command==='record_search_timing'));
  assert.ok(await page.evaluate(()=>window.calls.filter(c=>c.command==='record_search_timing').every(c=>!('q' in c.args.sample))));
  if(process.env.DIGUP_SEARCH_SCREENSHOTS){
    fs.mkdirSync(process.env.DIGUP_SEARCH_SCREENSHOTS,{recursive:true});
    await page.screenshot({path:process.env.DIGUP_SEARCH_SCREENSHOTS+'/mixed-light.png'});
    await page.emulateMedia({colorScheme:'dark'});await page.setViewportSize({width:760,height:720});
    await page.screenshot({path:process.env.DIGUP_SEARCH_SCREENSHOTS+'/mixed-dark-small.png'});
  }
  await page.evaluate(async()=>{
    const old=window.__TAURI__.core.invoke,calls=[];let release;
    window.__TAURI__.core.invoke=(command,args)=>{
      if(command==='ask'&&args.request.op==='render'){
        calls.push(args.request);
        return calls.length===1?new Promise(resolve=>{release=resolve;}):Promise.resolve({image:'C:/cache/current.jpg'});
      }
      return old(command,args);
    };
    const first=rendered('C:/fixture.pdf','pdf',1,240).catch(error=>error.superseded);
    await new Promise(resolve=>setTimeout(resolve,0));
    SearchTiming.begin(SearchTiming.generation+1);
    const current=await rendered('C:/fixture.pdf','pdf',1,240,true);
    release({status:'superseded'});
    if(await first!==true||current!=='C:/cache/current.jpg'||calls.length!==2||calls[0].generation===calls[1].generation||calls[1].foreground!==true)
      throw new Error('Obsolete preview promise leaked into the current generation');
    if(await rendered('C:/fixture.pdf','pdf',1,240)!==current||calls.length!==2)
      throw new Error('Obsolete preview completion evicted the current cached image');
    window.__TAURI__.core.invoke=old;
    await SearchTiming.measure('app_purpose',async()=>({ms:9,semantic:{id:777,meaning:true,ms:{queue:2,encode:7,cache_hit:true}}}));
  });
  await page.waitForFunction(()=>window.calls.some(c=>c.command==='record_search_timing'&&c.args.sample.nativeRequestId===777));
  assert.equal(await page.evaluate(()=>{
    const sample=window.calls.find(c=>c.command==='record_search_timing'&&c.args.sample.nativeRequestId===777).args.sample;
    return sample.encode===7&&sample.queue===2&&sample.native===9&&sample.cacheHit&&sample.semantic;
  }),true,'Purpose timing lost the encoder breakdown or native request correlation');
  await page.goto(base+'/index.html');await page.fill('#query','Firefox');await page.waitForSelector('.row');
  await page.waitForFunction(()=>document.querySelector('.group-title')?.textContent==='Best matches');
  await page.press('#query','ArrowDown');await page.press('#query','Enter');
  assert.ok(await page.evaluate(()=>window.calls.some(c=>c.command==='open_path')),'Panel keyboard order did not follow visible rows');
  const opened=await page.evaluate(()=>window.calls.filter(c=>['open_path','launch_app'].includes(c.command)).length);
  await page.evaluate(()=>{window.replacement={path:'C:/docs/Other note.txt'};window.releaseMeaning();});
  await page.waitForFunction(()=>state.strong[0]?.path==='C:/docs/Other note.txt');await page.press('#query','Enter');
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>['open_path','launch_app'].includes(c.command)).length),opened,'Panel refinement redirected the chosen target');
  await page.evaluate(()=>{window.replacement=null;window.blockMeaning=true;});
  await page.fill('#query','page test');await page.waitForSelector('.row');await page.locator('.row').first().click();
  await page.press('#query','Enter');
  await page.evaluate(()=>{window.replacement={loc:7};window.releaseMeaning();});
  await page.waitForFunction(()=>state.strong[0]?.loc===7);await page.press('#query','Enter');
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='open_path').at(-1).args.page),2,'Panel refinement changed the selected PDF page');
  assert.deepEqual(errors,[]);
  console.log('PASS: immediate keywords under blocked meaning; shared best matches, filename/category/ambiguous-name handling, placement modes, purpose suggestions, stable DOM/preview, timing privacy, dark/scaled views and panel ordering');
  await browser.close();
})().catch(async error=>{console.error(error);if(browser)await browser.close();process.exit(1);});
