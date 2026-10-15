// Shared native-boundary fixtures; actual app HTML/CSS/JS renders in Chromium.
const app = (id,name) => ({id:`app:${id.repeat(64)}`,resultType:'application',kind:'app',name,
 description:'Edit photos and retouch portraits',publisher:'Example',source:'userPrograms',reason:'prefix',aliases:[],purpose:'',hidden:false});
const photo=app('1','Photo Studio'), semantic=app('2','Portrait Editor');

async function setup(page, platform='Win32') {
  await page.addInitScript(({platform,photo,semantic})=>{
    Object.defineProperty(navigator,'platform',{get:()=>platform});
    window.calls=[]; window.listeners={}; window.fileMode='ready'; window.catalogEnabled=true;
    const all=Array.from({length:150},(_,i)=>({...photo,id:`app:${i.toString(16).padStart(64,'0')}`,name:`Application ${String(i).padStart(3,'0')}`}));
    const hiddenApp={...photo,id:`app:${'f'.repeat(64)}`,name:'Hidden application',hidden:true};
    const overrides={};
    const model={state:'failed',message:'No accelerator available'};
    window.setupInfo={offered:[],chosen:[],skipped:[],codeOffered:[],hotkey:'Ctrl+Shift+Space',shortcut:{method:'grab',command:''},setUp:false,applicationsSupported:true,model,state:{model}};
    const settings={applications:{supported:platform==='Win32',enabled:true,semanticEnabled:true,count:150,hiddenCount:1,totalCount:151,sourceErrors:{}},
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
      if(command==='activity_snapshot')return {schemaVersion:1,capturedAt:Date.now()/1000,
        files:{phase:'unavailable',searchable:0,pending:0,unfinished:0,knownFiles:0,total:null,done:null,missing:[],unreadable:[]},
        applications:{catalog:settings.applications,purpose:{state:'unavailable',message:'No accelerator available',encoder:'unavailable'}},
        inference:{configured:settings.acceleration,verified:null,encoder:'unavailable',model},helpers:{index:{running:false},search:{running:false}},events:[]};
      if(command==='export_diagnostics')return {saved:true};
      if(command==='indexing_diagnostics')return 'Build fixture\nIndex helper exited: database is locked\nC:/Documents العربية';
      if(command==='prepare_apps')return {state:'preparing',encoder:'ready',total:150,embedded:0};
      if(command==='setup_info')return window.setupInfo;
      if(command==='estimate')return args.folders.map(folder=>({folder,files:{doc:1},seconds:0,calibrated:false,subfolders:[]}));
      if(command==='apply_setup_folders' && window.setupSaveError)throw window.setupSaveError;
      if(command==='app_state')return {model};
      if(command==='debug_query')return null;
      if(command==='app_icon')throw 'No icon in fixture';
      if(command==='search_apps'){
        const q=args.q.toLowerCase();
        if(args.meaning)await new Promise(r=>setTimeout(r,700));
        const meaning=args.meaning&&!window.holdPurpose;
        const baseMatches=!q?[...all,hiddenApp]:q.includes('photo')?[photo,...(meaning?[{...semantic,reason:'semantic'}]:[])]:q==='portrait'?[semantic]:q==='retouch'&&meaning?[{...semantic,reason:'semantic'}]:[...all,hiddenApp].filter(h=>h.name.toLowerCase().includes(q)||overrides[h.id]?.aliases?.some(a=>a.toLowerCase().includes(q)));
        const visibility=args.visibility||(args.includeHidden?'all':'visible');
        const matches=baseMatches.map(h=>({...h,...overrides[h.id]})).filter(h=>visibility==='hidden'?h.hidden:visibility==='visible'?!h.hidden:true);
        return {generation:args.generation,hits:window.catalogEnabled?matches.slice(args.offset||0,(args.offset||0)+args.limit):[],total:window.catalogEnabled?matches.length:0,
          catalog:{enabled:window.catalogEnabled,supported:true,semanticEnabled:settings.applications.semanticEnabled,revision:'fixture',count:150},semantic:{state:meaning?'ready':'preparing',total:2,embedded:meaning?2:0}};
      }
      if(command==='launch_app'){if(window.launchFailure)throw {code:'launch_failed',message:'Application launch was refused'};return {accepted:true};}
      if(command==='refresh_apps')return settings.applications;
      if(command==='set_app_options'){window.catalogEnabled=args.enabled;Object.assign(settings.applications,{enabled:args.enabled,semanticEnabled:args.semanticEnabled});return settings.applications;}
      if(command==='set_app_override'){overrides[args.appId]=args.value;return settings.applications;}
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


module.exports = {setup, app, photo, semantic};
