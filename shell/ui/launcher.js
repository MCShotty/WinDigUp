"use strict";
const Launcher = {
  state:{hits:[],pinned:[],showRecent:true},generation:0,error:null,
  async refresh(){
    const generation=++this.generation;
    try{const value=await invoke("launcher_apps");if(generation!==this.generation)return;
      this.state=value||this.state;this.render();this.renderSettings();
    }catch(_){this.render();}
  },
  async pin(hit,pinned){
    await invoke("pin_launcher_app",{appId:hit.id,pinned});await this.refresh();
  },
  async launch(hit){
    try{await Apps.launch(hit);this.error=null;}
    catch(error){this.error={hit,message:error?.message||String(error)};this.render();
      document.querySelector("#launcher-shortcuts .launcher-retry")?.focus();}
  },
  render(){
    const host=document.getElementById("launcher-shortcuts");if(!host)return;
    const focused=document.activeElement?.dataset?.launcherId;
    const children=[];
    if(this.error){
      const note=element("span","launcher-error",this.error.message);note.setAttribute("role","alert");
      const retry=element("button","launcher-browse launcher-retry","Retry");retry.type="button";
      retry.setAttribute("aria-label","Retry launching "+this.error.hit.name);
      retry.onclick=async()=>{retry.disabled=true;try{await this.launch(this.error.hit);}finally{retry.disabled=false;}};
      const back=element("button","launcher-browse","Dismiss");back.type="button";
      back.onclick=()=>{const id=this.error.hit.id;this.error=null;this.render();(host.querySelector('[data-launcher-id="'+CSS.escape(id)+'"]')||document.getElementById("query"))?.focus();};
      host.replaceChildren(note,retry,back);return;
    }
    for(const hit of this.state.hits||[]){
      const button=element("button","launcher-shortcut");button.type="button";button.dataset.launcherId=hit.id;
      const label=hit.name+(hit.pinned?" · Pinned":" · Recent");
      button.setAttribute("aria-label","Launch "+label);button.title=label;button.append(Apps.icon(hit,64));
      button.onclick=async()=>{button.disabled=true;try{await this.launch(hit);}finally{button.disabled=false;}};
      children.push(button);
    }
    const browse=element("button","launcher-browse",(children.length?"All apps":"Browse apps"));
    browse.type="button";browse.setAttribute("aria-label","Browse all applications");
    browse.onclick=()=>invoke("open_window",{query:"apps:",kind:"apps",selected:null}).catch(()=>{});
    children.push(browse);
    host.replaceChildren(...children);
    if(focused)(host.querySelector('[data-launcher-id="'+CSS.escape(focused)+'"]')||document.getElementById("query"))?.focus();
  },
  renderSettings(){
    const input=document.getElementById("launcher-recents");if(!input)return;
    input.checked=this.state.showRecent!==false;
    const host=document.getElementById("launcher-pins");const focused=document.activeElement?.dataset?.pinnedId;host.replaceChildren();
    for(const id of this.state.pinned||[]){
      const hit=(this.state.hits||[]).find(h=>h.id===id);
      const row=element("div","launcher-pin");row.append(element("span","",hit?.name||"Unavailable pinned application"));
      const remove=element("button","","Unpin");remove.type="button";
      remove.dataset.pinnedId=id;remove.setAttribute("aria-label","Unpin "+(hit?.name||"unavailable application"));
      remove.onclick=()=>this.pin({id},false).catch(e=>document.getElementById("launcher-note").textContent=e?.message||String(e));row.append(remove);host.append(row);
    }
    if(focused)(host.querySelector('[data-pinned-id="'+CSS.escape(focused)+'"]')||input)?.focus();
  }
};
tauri.event.listen("launcher-changed",()=>Launcher.refresh());
tauri.event.listen("applications",()=>Launcher.refresh());
const shortcuts=document.getElementById("launcher-shortcuts");
if(shortcuts)shortcuts.addEventListener("keydown",event=>{
  const buttons=[...shortcuts.querySelectorAll("button")],at=buttons.indexOf(document.activeElement);
  if(at<0)return;
  if(["ArrowRight","ArrowLeft","Home","End"].includes(event.key)){
    event.preventDefault();const index=event.key==="Home"?0:event.key==="End"?buttons.length-1:(at+(event.key==="ArrowRight"?1:-1)+buttons.length)%buttons.length;buttons[index]?.focus();
  }else if(event.key==="ArrowUp"){event.preventDefault();document.getElementById("query")?.focus();}
});
const preferences=document.getElementById("launcher-preferences");
if(preferences)preferences.hidden=!/Win/.test(navigator.platform);
const recent=document.getElementById("launcher-recents");
if(recent){
  recent.onchange=async()=>{try{await invoke("set_launcher_recents",{enabled:recent.checked});await Launcher.refresh();}catch(e){document.getElementById("launcher-note").textContent=e?.message||String(e);await Launcher.refresh();}};
  document.getElementById("clear-launcher-recents").onclick=async()=>{try{await invoke("clear_launcher_recents");await Launcher.refresh();document.getElementById("launcher-note").textContent="Recent apps cleared.";}catch(e){document.getElementById("launcher-note").textContent=e?.message||String(e);}};
}
Launcher.refresh();

if(document.getElementById("copilot-option")&&/Win/.test(navigator.platform)){
  document.getElementById("copilot-option").hidden=false;
  document.getElementById("configure-copilot").onclick=()=>invoke("configure_copilot_key").catch(e=>document.getElementById("copilot-status").textContent=e?.message||String(e));
  invoke("copilot_status").then(status=>{
    const note=document.getElementById("copilot-status");
    if(status.supported===false){note.textContent=status.message||"Copilot-key customization is unavailable on this Windows version.";document.getElementById("configure-copilot").disabled=true;return;}
    note.textContent=status.managed?"Your organization manages the Copilot key.":status.assigned?"The Copilot key opens WinDigUp.":
      status.registered?"WinDigUp is registered. Select it in Windows' Copilot-key app picker.":"Copilot-key registration needs the signed Windows identity package. The regular shortcut remains available.";
    if(status.message)note.textContent+=" "+status.message;
  }).catch(()=>document.getElementById("copilot-status").textContent="Copilot-key registration status is unavailable.");
}
