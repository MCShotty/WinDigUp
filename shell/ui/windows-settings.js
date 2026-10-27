"use strict";
const WindowsSettings = {
  supported:isWindows,enabled:isWindows,ordinarySearches:true,
  configure(info){if(!info)return;if(typeof info.enabled==="boolean")this.enabled=info.enabled;
    if(typeof info.supported==="boolean")this.supported=info.supported;
    if(typeof info.ordinarySearches==="boolean")this.ordinarySearches=info.ordinarySearches;},
  icon(hit){const holder=element("span","app-icon");holder.setAttribute("aria-hidden","true");
    const image=element("img");image.src="settings-generic.svg";image.alt="";holder.append(image);
    if(hit?.source==="control_panel")invoke("windows_setting_icon",{settingId:hit.id,size:64}).then(fileURL).then(src=>{if(holder.isConnected)image.src=src;}).catch(()=>{});
    return holder;},
  async open(hit){if(Apps.launching.has(hit.id))return;Apps.launching.add(hit.id);
    try{return await invoke("open_windows_setting",{settingId:hit.id});}
    finally{Apps.launching.delete(hit.id);}},
  details(hit,fail){const box=element("div","app-details");
    box.append(this.icon(hit),element("div","app-name",hit.name),element("p","app-description",hit.source==="control_panel"?"Control Panel":"Windows Settings"),
      element("p","",hit.description||"Open this Windows settings page."));
    if(hit.availability==="unknown")box.append(element("p","note","Availability depends on this PC's hardware and Windows configuration."));
    const button=element("button","primary","Open settings");button.onclick=async()=>{button.disabled=true;
      try{await this.open(hit);}catch(error){fail(error);}finally{button.disabled=false;}};
    box.append(element("p","app-description",matchLabel(hit)),button);
    appendUsefulResult(box,hit,fail);return box;},
};
class WindowsSettingsSearch {
  constructor(changed){
    this.changed=changed;this.hits=[];this.total=0;this.epoch=0;this.semantic={state:"preparing"};this.catalog={};
    for(const name of ["windows-settings","windows-settings-progress"])tauri.event.listen(name,({payload})=>{
      if(name==="windows-settings"){WindowsSettings.configure(payload);this.catalog=payload;
        if(this.requestedActive){this.begin(this.text,true,this.mode);this.changed();}else this.changed(true);return;}
      const changed=this.semantic.embedded!==payload.embedded||this.semantic.revision!==payload.revision;
      this.semantic=payload;this.changed(true);
      if(changed&&this.active&&this.text&&!this.refreshTimer&&!document.hidden)
        this.refreshTimer=setTimeout(()=>{this.refreshTimer=null;this.request(true,true);},1000);
    });
    tauri.event.listen("model",({payload})=>{if(payload.state==="ready"&&this.active&&this.text)this.request(true,true);});
  }
  begin(text,active,mode="all"){
    this.epoch++;this.requestedActive=active;this.text=text;this.mode=mode;this.hits=[];this.total=0;this.error=null;this.finalEpoch=-1;this.settledEpoch=-1;
    clearTimeout(this.timer);clearTimeout(this.refreshTimer);cancelAnimationFrame(this.frame);
    this.active=active&&WindowsSettings.supported&&WindowsSettings.enabled&&(mode==="settings"||WindowsSettings.ordinarySearches);
    if(!this.active)return;
    this.frame=requestAnimationFrame(()=>this.request(false));
    if(text)this.timer=setTimeout(()=>this.request(true),120);
  }
  visible(){return this.active?(this.mode==="settings"?this.hits:this.hits.slice(0,2)):[];}
  async request(meaning,passive=false,append=false){
    if(!this.active||(meaning&&!this.text))return;
    if(meaning&&this.semanticBusy){this.pending={epoch:this.epoch,passive,append};return;}
    if(meaning)this.semanticBusy=true;
    const epoch=this.epoch,text=this.text;
    try{
      const reply=await SearchTiming.measure(meaning?"settings_purpose":"settings_names",async()=>invoke("search_windows_settings",{
        q:text,meaning,generation:epoch,sessionId:await SearchTiming.session,limit:this.mode==="settings"?100:2,
        offset:append?this.hits.length:0,passive}),passive);
      if(epoch!==this.epoch||reply?.generation!==epoch||reply.status==="superseded")return;
      this.settledEpoch=epoch;
      WindowsSettings.configure(reply.catalog);this.catalog=reply.catalog||{};
      if(!WindowsSettings.enabled||(this.mode==="all"&&!WindowsSettings.ordinarySearches)){this.hits=[];this.total=0;this.active=false;this.changed();return;}
      if(!meaning&&this.finalEpoch===epoch)return;
      if(meaning)this.finalEpoch=epoch;
      this.hits=append?[...this.hits,...(reply.hits||[]).filter(h=>!this.hits.some(old=>old.id===h.id))]:reply.hits||[];
      this.total=reply.total||0;this.semantic=reply.semantic||{};this.error=null;this.changed();
    }catch(error){if(epoch===this.epoch){this.settledEpoch=epoch;this.error=error?.message||String(error);this.changed();}}
    finally{if(meaning){this.semanticBusy=false;const pending=this.pending;this.pending=null;
      if(pending?.epoch===this.epoch)this.request(true,pending.passive,pending.append);}}
  }
  more(){return this.request(Boolean(this.text),true,true);}
  suspend(){const generation=++this.epoch;this.active=false;clearTimeout(this.timer);clearTimeout(this.refreshTimer);cancelAnimationFrame(this.frame);
    SearchTiming.session.then(sessionId=>invoke("cancel_windows_settings_search",{sessionId,generation})).catch(()=>{});}
  status(){if(!WindowsSettings.enabled)return "Windows settings search is off.";
    if(this.error)return "Windows settings: "+this.error;
    if(this.semantic.state==="unavailable")return "Names available · Purpose matching unavailable";
    if(this.semantic.state==="preparing"&&this.text)return "Names available · Purpose matching preparing";
    return this.total+" Windows settings "+(this.text?"matches":"pages");}
}
