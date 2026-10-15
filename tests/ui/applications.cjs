// Actual panel/window/settings integration. The native boundary is mocked, not the rendered UI.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const base = process.env.DIGUP_UI_URL || 'http://127.0.0.1:8765';
let browser;
const app = (id,name) => ({id:`app:${id.repeat(64)}`,resultType:'application',kind:'app',name,
 description:'Edit photos and retouch portraits',publisher:'Example',source:'userPrograms',reason:'prefix',aliases:[],purpose:'',hidden:false});
const photo=app('1','Photo Studio'), semantic=app('2','Portrait Editor');

async function setup(page, platform='Win32') {
  await page.addInitScript(({platform,photo,semantic})=>{
    Object.defineProperty(navigator,'platform',{get:()=>platform});
    window.calls=[]; window.listeners={}; window.fileMode='ready'; window.catalogEnabled=true;
    const all=Array.from({length:150},(_,i)=>({...photo,id:`app:${i.toString(16).padStart(64,'0')}`,name:`Application ${String(i).padStart(3,'0')}`}));
    const model={state:'failed',message:'No accelerator available'};
    const settings={applications:{supported:platform==='Win32',enabled:true,semanticEnabled:true,count:150,sourceErrors:{}},
      acceleration:{backend:'amd-vulkan',gpu:'',python:'',models:''},hotkey:'Ctrl+Shift+Space',shortcut:{method:'grab',command:''},
      folders:['C:/docs'],skipped:[],skipTypes:[],code:{folders:[],skipped:[],editors:[],editor:'default'},state:{model},
      indexHours:{on:false,start:60,end:420},storage:{index:'C:/test',models:'C:/models'},version:'test',updateChecks:false};
    const hit={path:'C:/docs/photos.txt',kind:'doc',segment:'chunk',segment_id:1,modified:1700000000,size:32,
      excerpt:'A photo document',keyword_rank:1,info:{},score:5};
    window.emit=(name,payload)=>{for(const cb of window.listeners[name]||[])cb({payload});};
    window.__TAURI__={core:{convertFileSrc:p=>`http://asset.localhost/${p}`,invoke:async(command,args={})=>{
      window.calls.push({command,args});
      if(command==='window_info')return {folders:['C:/docs'],hotkey:'Ctrl+Shift+Space',hasCode:true,state:{model},debugQuery:null};
      if(command==='settings_info')return settings;
      if(command==='setup_info')return {offered:[],chosen:[],skipped:[],codeOffered:[],hotkey:'Ctrl+Shift+Space',shortcut:{method:'grab',command:''},setUp:false,applicationsSupported:true,model,state:{model}};
      if(command==='app_state')return {model};
      if(command==='debug_query')return null;
      if(command==='app_icon')throw 'No icon in fixture';
      if(command==='search_apps'){
        const q=args.q.toLowerCase();
        if(args.meaning)await new Promise(r=>setTimeout(r,700));
        const matches=!q?all:q.includes('photo')?[photo,...(args.meaning?[{...semantic,reason:'semantic'}]:[])]:q==='portrait'?[semantic]:[];
        return {generation:args.generation,hits:window.catalogEnabled?matches.slice(args.offset||0,(args.offset||0)+args.limit):[],total:window.catalogEnabled?matches.length:0,
          catalog:{enabled:window.catalogEnabled,supported:true,revision:'fixture'},semantic:{state:args.meaning?'ready':'preparing',total:2,embedded:args.meaning?2:0}};
      }
      if(command==='launch_app')return {accepted:true};
      if(command==='refresh_apps')return settings.applications;
      if(command==='set_app_options'){Object.assign(settings.applications,{enabled:args.enabled,semanticEnabled:args.semanticEnabled});return settings.applications;}
      if(command==='set_app_override')return settings.applications;
      if(command==='ask'){
        if(args.request.op==='search'){
          if(window.fileMode==='blocked')return new Promise(()=>{});
          if(window.fileMode==='failed')throw 'File helper unavailable';
          await new Promise(r=>setTimeout(r,100));
          return {hits:[hit],strong:1,meaning:true};
        }
        if(args.request.op==='summaries')return {roots:[]};
        if(args.request.op==='text')return {text:'A photo document'};
        return {};
      }
      return null;
    }},path:{homeDir:async()=> 'C:/Users/Test'},event:{listen:async(name,cb)=>{
      (window.listeners[name] ||= []).push(cb);return()=>{};
    }}};
  },{platform,photo,semantic});
}

(async()=>{
  browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME||'/usr/bin/chromium',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
  const errors=[];
  const page=await browser.newPage({viewport:{width:1000,height:800}});page.on('pageerror',e=>{errors.push(e.message);console.error(e.stack);});
  await setup(page);
  await page.goto(base+'/index.html');
  await page.waitForFunction(()=>window.calls.some(c=>c.command==='app_state'));
  await page.evaluate(()=>{window.fileMode='blocked';window.calls=[];});
  await page.fill('#query','photo');
  await page.waitForSelector('.app-row');
  assert.match(await page.locator('.app-row').first().textContent(),/Photo Studio/);
  assert.equal(await page.locator('.group-title').first().textContent(),'Apps');
  await page.locator('.app-row').first().click();await page.press('#query','Enter');
  await page.waitForFunction(()=>window.calls.some(c=>c.command==='launch_app'));
  assert.deepEqual(await page.evaluate(()=>window.calls.find(c=>c.command==='launch_app').args),{appId:photo.id});
  await page.press('#query','Control+c');
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='copy_file').length),0);

  await page.evaluate(()=>{window.fileMode='ready';});
  await page.fill('#query','photo ');
  await page.waitForSelector('.row');
  await page.press('#query','ArrowDown');
  assert.match(await page.locator('.row.selected').textContent(),/photos.txt/);
  await page.waitForFunction(()=>document.querySelectorAll('.app-row').length===2);
  assert.match(await page.locator('.row.selected').textContent(),/photos.txt/);
  await page.evaluate(()=>window.calls=[]);
  await page.fill('#query','apps:');
  await page.waitForFunction(()=>document.querySelector('.app-row')?.textContent.includes('Application 000'));
  assert.equal(await page.locator('.app-row').count(),6);
  await page.waitForTimeout(200);
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='ask').length),0);
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.command==='search_apps'&&c.args.meaning).length),0);

  await page.goto(base+'/window.html');
  await page.waitForSelector('.chip');
  await page.getByRole('button',{name:/^Apps/}).click();
  await page.waitForFunction(()=>document.querySelectorAll('.app-row').length===100);
  await page.getByRole('button',{name:'Show more applications',exact:true}).click();
  await page.waitForFunction(()=>document.querySelectorAll('.app-row').length===150);
  await page.locator('.app-row').nth(120).click();await page.press('#query','Enter');
  assert.equal((await page.evaluate(()=>window.calls.filter(c=>c.command==='launch_app').at(-1).args)).appId,`app:${(120).toString(16).padStart(64,'0')}`);
  await page.fill('#query','photo');
  await page.waitForSelector('.app-row');
  assert.equal(await page.locator('.cell').count(),0);
  await page.getByRole('button',{name:'All',exact:false}).first().click();
  await page.waitForSelector('.cell');
  assert.match(await page.locator('#content').textContent(),/Photo Studio/);
  await page.locator('.cell').click();
  await page.waitForFunction(()=>document.querySelectorAll('.app-row').length===2);
  assert.equal(await page.locator('.cell.selected').count(),1);
  await page.locator('.app-row').first().click();
  assert.match(await page.locator('#side').textContent(),/Launch/);
  assert.equal(await page.locator('#side video, #side audio, #side .frame').count(),0);
  if(process.env.DIGUP_APP_SCREENSHOT)await page.screenshot({path:process.env.DIGUP_APP_SCREENSHOT});

  await page.goto(base+'/settings.html?tab=apps');
  await page.waitForFunction(()=>document.querySelectorAll('.app-editor').length===100);
  const purpose=page.locator('.app-editor textarea').nth(1);
  await purpose.fill('Retouch portraits, color correction');
  await page.evaluate(()=>window.dispatchEvent(new Event('focus')));
  await page.waitForTimeout(250);
  assert.equal(await purpose.inputValue(),'Retouch portraits, color correction');
  await page.locator('.app-editor').first().getByRole('button',{name:'Save',exact:true}).click();
  await page.waitForFunction(()=>window.calls.some(c=>c.command==='set_app_override'));
  assert.equal(await page.evaluate(()=>window.calls.find(c=>c.command==='set_app_override').args.value.purpose),'Retouch portraits, color correction');

  await page.goto(base+'/setup.html');
  await page.waitForFunction(()=>!document.querySelector('#apps-start').hidden);
  await page.getByRole('button',{name:'Open app launcher now'}).click();
  await page.waitForFunction(()=>window.calls.some(c=>c.command==='finish_setup'));

  const linux=await browser.newPage();linux.on('pageerror',e=>errors.push(e.message));await setup(linux,'Linux x86_64');
  await linux.goto(base+'/window.html');await linux.waitForSelector('.chip');
  assert.equal(await linux.getByRole('button',{name:/^Apps/}).count(),0);
  await linux.fill('#query','apps: photo');await linux.waitForTimeout(250);
  assert.equal(await linux.evaluate(()=>window.calls.filter(c=>c.command==='search_apps').length),0);
  assert.deepEqual(errors,[]);
  console.log('PASS: native-app results survive a blocked helper; routing, launch IDs, pagination, selection, app actions, settings drafts, setup and Linux behavior');
  await browser.close();
})().catch(async e=>{console.error(e);if(browser)await browser.close();process.exit(1)});
