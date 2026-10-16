"use strict";
// Controls keep local drafts separate from asynchronously refreshed provider status.
const DiscoverySettings = {
  started:false, draft:null, dirty:false, busy:false, generation:0, hits:[], offset:0,
  el(id){return document.getElementById(id);},
  start(){
    if(this.started)return;this.started=true;
    for(const [event,key] of [["discovery","discovery"],["app-enrichment","enrichment"],["windows-settings","windowsSettings"],["windows-settings-progress","windowsSettingsSemantic"]])
      tauri.event.listen(event,({payload})=>{info[key]=payload;this.render();});
    for(const id of ["drive-enabled","drive-paused"])this.el(id).onchange=()=>this.edit();
    this.el("drive-save").onclick=()=>this.save();
    this.el("drive-revert").onclick=()=>{this.dirty=false;this.draft=null;this.render();};
    this.el("drive-refresh").onclick=()=>this.action("refresh_discovery",{full:true},"discovery");
    this.el("drive-install").onclick=()=>this.action("install_discovery_component",{},"discovery");
    this.el("drive-filter").oninput=()=>{clearTimeout(this.timer);this.timer=setTimeout(()=>this.candidates(),120);};
    this.el("drive-visibility").onchange=()=>this.candidates();
    this.el("drive-more").onclick=()=>this.candidates(true);
    for(const id of ["win-settings-enabled","win-settings-purpose","win-settings-ordinary"])this.el(id).onchange=()=>this.settingsOptions();
    this.el("win-settings-prepare").onclick=()=>this.action("prepare_windows_settings",{},"windowsSettingsSemantic");
    for(const id of ["descriptions-enabled","descriptions-publishers"])this.el(id).onchange=()=>this.enrichmentOptions();
    this.el("descriptions-refresh").onclick=()=>this.action("refresh_app_descriptions",{},"enrichment");
    this.el("descriptions-clear").onclick=()=>this.action("clear_app_descriptions",{},"enrichment");
  },
  text(id,value){const el=this.el(id);if(el.textContent!==value)el.textContent=value;},
  n(value){return typeof value==="number"?value.toLocaleString():"Not known yet";},
  render(){
    this.start();
    const d=info.discovery||{},e=info.enrichment||{},w=info.windowsSettings||{},s=info.windowsSettingsSemantic||{},p=d.progress||{},ep=e.progress||{};
    this.el("extra-app-sources").hidden=!d.supported;
    if(!d.supported)return;
    if(!this.dirty&&!this.busy)this.draft=structuredClone(d.options||{enabled:false,paused:false,volumes:[],included:[],hidden:[]});
    const draft=this.draft||{};
    this.el("drive-enabled").checked=Boolean(draft.enabled);this.el("drive-paused").checked=Boolean(draft.paused);
    const volumes=d.volumes||[];
    const signature=JSON.stringify([volumes,draft.volumes]);
    if(signature!==this.volumeSignature){
      this.volumeSignature=signature;const box=this.el("drive-volumes");box.replaceChildren();
      const all=[...volumes,...(draft.volumes||[]).filter(id=>!volumes.some(v=>v.id===id)).map(id=>({id,name:"Disconnected volume",paths:[],available:false}))];
      for(const volume of all){
        const label=element("label","source-volume"),check=element("input");check.type="checkbox";check.value=volume.id;
        check.checked=(draft.volumes||[]).includes(volume.id);check.disabled=this.busy;
        check.onchange=()=>this.edit();
        label.append(check,element("span","",[(volume.paths||[]).join(", "),volume.name,volume.filesystem,volume.available===false?"Unavailable":""].filter(Boolean).join(" · ")));box.append(label);
      }
      if(!all.length)box.append(element("p","note","Checking available volumes. Registered applications remain searchable."));
    }
    for(const id of ["drive-enabled","drive-paused","drive-save","drive-revert","drive-install"])this.el(id).disabled=this.busy;
    this.el("drive-save").disabled=this.busy||!this.dirty;this.el("drive-revert").disabled=this.busy||!this.dirty;
    this.el("drive-refresh").disabled=this.busy||!d.options?.enabled||d.options?.paused||Boolean(d.running);
    this.text("drive-draft",this.dirty?"Unsaved drive selections. Save to apply.":"");
    this.text("drive-status",[
      {disabled:"Drive discovery off",paused:"Drive discovery paused",watching:"Watching for executable changes",enumerating:"Reading NTFS file records",metadata:"Identifying executable applications",reconciling:"Reconciling changes",waiting:"Waiting to discover applications",failed:"Drive discovery needs attention",unavailable:"Drive discovery unavailable"}[p.phase]||p.phase||"Waiting",
      typeof p.records==="number"?`${this.n(p.records)} records checked`:"",
      typeof p.candidates==="number"?`${this.n(p.candidates)} executable candidates`:"",
      typeof p.accepted==="number"?`${this.n(p.accepted)} accepted`:"",
      p.mode==="directory"?"Directory fallback":p.mode==="ntfs"?"NTFS service":"",
      p.message||""].filter(Boolean).join(" · "));
    this.el("win-settings-enabled").checked=Boolean(w.enabled);
    this.el("win-settings-purpose").checked=Boolean(w.semanticEnabled);this.el("win-settings-ordinary").checked=Boolean(w.ordinarySearches);
    this.el("win-settings-purpose").disabled=this.busy||!w.enabled;this.el("win-settings-ordinary").disabled=this.busy||!w.enabled;
    this.el("win-settings-enabled").disabled=this.busy;
    this.text("win-settings-status",`${this.n(w.count)} destinations · ${!w.semanticEnabled?"Purpose matching off":s.message||(`${this.n(s.embedded)} of ${this.n(s.total)} prepared`)}`);
    this.el("win-settings-prepare").disabled=this.busy||!w.enabled||!w.semanticEnabled||info.state?.model?.state!=="ready"||(typeof s.total==="number"&&s.embedded===s.total);
    this.el("descriptions-enabled").checked=Boolean(e.options?.enabled);this.el("descriptions-publishers").checked=e.options?.publisherPages!==false;
    this.el("descriptions-enabled").disabled=this.busy;this.el("descriptions-publishers").disabled=this.busy||!e.options?.enabled;
    this.el("descriptions-refresh").disabled=this.busy||!e.options?.enabled||["inventory","fetching"].includes(ep.state);
    this.el("descriptions-clear").disabled=this.busy;
    this.text("descriptions-status",[
      {disabled:"Online descriptions off · Saved descriptions remain available",inventory:"Reading installed WinGet products",fetching:"Fetching version-matched descriptions",ready:"Descriptions up to date",unavailable:"Description fetching needs attention"}[ep.state]||ep.state||"Not started",
      typeof ep.enriched==="number"?`${this.n(ep.enriched)} apps enhanced`:"",
      ep.failedProducts?`${this.n(ep.failedProducts)} sources failed`:"",ep.message||""].filter(Boolean).join(" · "));
    if(!this.loaded&&!this.el("apps").hidden){this.loaded=true;this.candidates();}
  },
  edit(){
    const current=this.draft||{};this.draft={...current,enabled:this.el("drive-enabled").checked,paused:this.el("drive-paused").checked,
      volumes:[...this.el("drive-volumes").querySelectorAll("input:checked")].map(el=>el.value)};
    this.dirty=true;this.render();
  },
  async save(){
    if(this.busy||!this.dirty)return;
    // Candidate review may have updated annotations since this draft was started.
    const options={...(info.discovery?.options||{}),...this.draft,
      included:info.discovery?.options?.included||[],hidden:info.discovery?.options?.hidden||[]};
    this.busy=true;this.render();
    try{info.discovery=await invoke("set_discovery_options",{options});this.dirty=false;this.draft=null;}
    catch(error){this.text("source-message",error?.message||String(error));}
    finally{this.busy=false;this.render();this.candidates();}
  },
  async action(command,args,key){
    if(this.busy)return;this.busy=true;this.render();this.text("source-message",command==="install_discovery_component"?"Windows will request administrator permission. Directory fallback is available without installation.":"Working…");
    try{info[key]=await invoke(command,args);this.text("source-message",command==="clear_app_descriptions"?"Online fetching disabled and saved descriptions cleared. Your aliases and purpose notes are kept.":"Done.");}
    catch(error){this.text("source-message",error?.message||String(error));}
    finally{this.busy=false;this.render();}
  },
  settingsOptions(){return this.action("set_windows_settings_options",{options:{enabled:this.el("win-settings-enabled").checked,
    semanticEnabled:this.el("win-settings-purpose").checked,ordinarySearches:this.el("win-settings-ordinary").checked}},"windowsSettings");},
  enrichmentOptions(){return this.action("set_app_enrichment_options",{options:{enabled:this.el("descriptions-enabled").checked,
    publisherPages:this.el("descriptions-publishers").checked}},"enrichment");},
  async candidates(append=false){
    const generation=++this.generation,q=this.el("drive-filter").value,classification=this.el("drive-visibility").value;
    try{
      const reply=await invoke("discovery_candidates",{q,classification,offset:append?this.offset:0,limit:50,generation});
      if(generation!==this.generation||reply?.generation!==generation)return;
      this.hits=append?[...this.hits,...reply.hits]:reply.hits;this.offset=this.hits.length;
      this.text("drive-count",`${this.n(this.offset)} of ${this.n(reply.total)} matching executables`);
      this.el("drive-more").hidden=this.offset>=reply.total;const box=this.el("drive-candidates");box.replaceChildren();
      const reasons={not_portable_executable:"Not a launchable Windows executable",internal_or_installation_tool:"May be an installer or internal helper",command_line_program:"Command line program",application_identity_uncertain:"Application identity needs review",identified_gui_application:"Identified desktop application",user_included:"Included by you",user_hidden:"Hidden by you"};
      for(const hit of this.hits){
        const row=element("div","source-candidate");row.dataset.candidateId=hit.id;
        row.append(element("strong","",hit.name||hit.path.split(/[\\/]/).pop()),element("span","app-description",hit.publisher||hit.product||"Publisher not provided"),
          element("span","source-path",hit.path),element("span","note",reasons[hit.reason]||hit.reason||hit.classification));
        const actions=element("div","apps-settings-actions");
        for(const [action,label] of [["include","Include app"],["hide","Hide"],["reset","Reset review"]]){
          const button=element("button","",label);button.disabled=action==="include"&&!hit.portable;
          button.onclick=async()=>{
            for(const b of actions.querySelectorAll("button"))b.disabled=true;
            try{info.discovery=await invoke("set_discovery_candidate",{candidateId:hit.id,action});this.render();await this.candidates();}
            catch(error){this.text("source-message",error?.message||String(error));for(const b of actions.querySelectorAll("button"))b.disabled=b.textContent==="Include app"&&!hit.portable;}
          };actions.append(button);
        }
        row.append(actions);box.append(row);
      }
      if(!this.hits.length)box.append(element("p","note","No executable candidates match. Select drives and save to begin discovery."));
    }catch(error){if(generation===this.generation)this.text("source-message",error?.message||String(error));}
  },
};
