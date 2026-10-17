"use strict";
const DiscoverySettings = {
  started:false, draft:null, dirty:false, generation:0, hits:[], offset:0,
  pending:new Map(), messages:new Map(), rows:new Map(), candidatePending:new Set(), providerDrafts:new Map(),
  el(id){return document.getElementById(id);},
  text(id,value){const el=this.el(id);if(el&&el.textContent!==value)el.textContent=value;},
  n(value){return Number.isFinite(value)?value.toLocaleString():"Not reported";},
  start(){
    if(this.started)return;this.started=true;
    this.driveList=new PipelineUI.DriveList(this.el("drive-progress-list"));
    for(const [event,key]of [["discovery","discovery"],["app-enrichment","enrichment"],["windows-settings","windowsSettings"],["windows-settings-progress","windowsSettingsSemantic"]]){
      tauri.event.listen(event,({payload})=>{
        this.accept(key,payload);
        if(key==="enrichment"&&payload.progress?.cleared)this.message("enrichment","Saved descriptions cleared. Your aliases and purpose notes are kept.");
        this.render();
        if(key==="discovery"&&payload.progress?.phase==="watching"&&!this.el("apps").hidden){
          clearTimeout(this.refreshTimer);this.refreshTimer=setTimeout(()=>this.candidates(),400);
        }
      });
    }
    for(const id of ["drive-enabled","drive-paused"])this.el(id).onchange=()=>this.edit();
    this.el("drive-save").onclick=()=>this.save();
    this.el("drive-revert").onclick=()=>{this.dirty=false;this.draft=null;this.render();};
    this.el("drive-refresh").onclick=()=>this.action("discovery","refresh_discovery",{full:true},"discovery","Drive refresh scheduled.");
    this.el("drive-install").onclick=()=>this.action("discovery","install_discovery_component",{},"discovery","Fast discovery installed. Drive refresh scheduled.");
    this.el("drive-filter").oninput=()=>{this.generation++;this.currentResults=false;this.renderCandidates();clearTimeout(this.timer);this.timer=setTimeout(()=>this.candidates(),120);};
    this.el("drive-visibility").onchange=()=>this.candidates();
    this.el("drive-more").onclick=()=>this.candidates(true);
    this.el("drive-retry-list").onclick=()=>this.candidates();
    for(const id of ["win-settings-enabled","win-settings-purpose","win-settings-ordinary"])this.el(id).onchange=()=>this.settingsOptions();
    this.el("win-settings-prepare").onclick=()=>this.action("windows","prepare_windows_settings",{},"windowsSettingsSemantic","Purpose preparation requested.");
    for(const id of ["descriptions-enabled","descriptions-publishers"])this.el(id).onchange=()=>this.enrichmentOptions();
    this.el("descriptions-refresh").onclick=()=>this.action("enrichment","refresh_app_descriptions",{},"enrichment","Description refresh scheduled.");
    this.el("descriptions-clear").onclick=()=>this.action("enrichment","clear_app_descriptions",{},"enrichment","Online fetching disabled. Clearing saved descriptions.");
  },
  accept(key,payload){
    if(key==="discovery"&&Number.isFinite(payload?.options?.revision)&&Number.isFinite(info.discovery?.options?.revision)&&
      payload.options.revision<info.discovery.options.revision)return false;
    info[key]=payload;return true;
  },
  message(source,value){
    this.messages.set(source,value);
    this.text("source-message",value);
    this.text("source-message-"+source,value);
  },
  render(){
    this.start();
    const d=info.discovery||{},e=info.enrichment||{},w=this.providerDrafts.get("windows")||info.windowsSettings||{};
    const s=info.windowsSettingsSemantic||{},p=d.progress||{},ep=e.progress||{};
    this.el("extra-app-sources").hidden=!d.supported;
    if(!d.supported)return;
    const driveBusy=this.pending.has("discovery"),windowsBusy=this.pending.has("windows"),descriptionsBusy=this.pending.has("enrichment");
    if(!this.dirty&&!driveBusy)this.draft=structuredClone(d.options||{enabled:false,paused:false,volumes:[],included:[],hidden:[]});
    const draft=this.draft||{};
    this.el("drive-enabled").checked=Boolean(draft.enabled);this.el("drive-paused").checked=Boolean(draft.paused);
    const volumes=d.volumes||[];
    const all=[...volumes,...(draft.volumes||[]).filter(id=>!volumes.some(v=>v.id===id)).map(id=>({id,name:"Disconnected volume",paths:[],available:false}))];
    const signature=JSON.stringify([all.map(v=>[v.id,v.paths,v.name,v.filesystem,v.available]),draft.volumes]);
    if(signature!==this.volumeSignature){
      this.volumeSignature=signature;
      const box=this.el("drive-volumes"),focused=document.activeElement?.value;
      box.replaceChildren();
      for(const volume of all){
        const label=element("label","source-volume"),check=element("input");
        check.type="checkbox";check.value=volume.id;check.checked=(draft.volumes||[]).includes(volume.id);
        check.onchange=()=>this.edit();
        label.append(check,element("span","",[(volume.paths||[]).join(", "),volume.name,volume.filesystem,volume.available===false?"Unavailable":""].filter(Boolean).join(" · ")));
        box.append(label);
      }
      if(!all.length)box.append(element("p","note","No mounted volumes were reported. Installed applications remain searchable."));
      if(focused)for(const check of box.querySelectorAll("input"))if(check.value===focused)check.focus();
    }
    for(const check of this.el("drive-volumes").querySelectorAll("input"))check.disabled=driveBusy;
    for(const id of ["drive-enabled","drive-paused","drive-install"])this.el(id).disabled=driveBusy;
    this.el("drive-save").disabled=driveBusy||!this.dirty;this.el("drive-revert").disabled=driveBusy||!this.dirty;
    this.el("drive-refresh").disabled=driveBusy||d.catalogEnabled===false||!d.options?.enabled||d.options?.paused||Boolean(d.running);
    this.text("drive-draft",this.dirty?"Unsaved drive selections. Save to apply.":"");
    const legacy=[p.phase||"Waiting",Number.isFinite(p.records)?this.n(p.records)+" records checked":"",
      Number.isFinite(p.candidates)?this.n(p.candidates)+" executable candidates":"",
      Number.isFinite(p.accepted)?this.n(p.accepted)+" accepted":"",p.message||""].filter(Boolean).join(" · ");
    this.text("drive-status",d.catalogEnabled===false?"Application search is off":d.version===2?(!d.options?.enabled?"Drive discovery off":d.options.paused?"Drive discovery paused":d.running?"Scanning selected drives":"Waiting for executable changes"):legacy);
    this.driveList.update(d);
    this.el("win-settings-enabled").checked=Boolean(w.enabled);
    this.el("win-settings-purpose").checked=Boolean(w.semanticEnabled);this.el("win-settings-ordinary").checked=Boolean(w.ordinarySearches);
    this.el("win-settings-enabled").disabled=windowsBusy;
    this.el("win-settings-purpose").disabled=windowsBusy||!w.enabled;this.el("win-settings-ordinary").disabled=windowsBusy||!w.enabled;
    this.text("win-settings-status",this.n(w.count??info.windowsSettings?.count)+" destinations available. "+
      (!w.semanticEnabled?"Purpose matching is off.":s.message||(Number.isFinite(s.total)?this.n(s.embedded)+" of "+this.n(s.total)+" prepared.":"Purpose matching starts when needed.")));
    this.el("win-settings-prepare").disabled=windowsBusy||!w.enabled||!w.semanticEnabled||info.state?.model?.state!=="ready"||
      (Number.isFinite(s.total)&&s.embedded===s.total&&s.state!=="unavailable"&&s.encoder!=="unavailable");
    const descriptions=this.providerDrafts.get("enrichment")||e.options||{};
    this.el("descriptions-enabled").checked=Boolean(descriptions.enabled);this.el("descriptions-publishers").checked=Boolean(descriptions.publisherPages);
    this.el("descriptions-enabled").disabled=descriptionsBusy;this.el("descriptions-publishers").disabled=descriptionsBusy;
    this.el("descriptions-refresh").disabled=descriptionsBusy||!e.options?.enabled||["inventory","fetching"].includes(ep.state);
    this.el("descriptions-clear").disabled=descriptionsBusy;
    this.text("descriptions-status",[
      {disabled:"Fetching is off. Saved descriptions remain available.",inventory:"Reading installed WinGet products.",
        fetching:"Fetching matching descriptions.",ready:"Description refresh complete.",unavailable:"Description fetching needs attention."}[ep.state]||"Description status has not been reported.",
      Number.isFinite(ep.enriched)?this.n(ep.enriched)+" apps enhanced.":"",
      ep.failedProducts?this.n(ep.failedProducts)+" sources failed.":"",ep.message||""].filter(Boolean).join(" "));
    const phases=JSON.stringify([p.phase,ep.state,s.state]);
    if(phases!==this.phases){this.phases=phases;this.text("sources-announcement","Drive discovery "+(p.phase||"waiting")+". Online descriptions "+(ep.state||"off")+".");}
    if(!this.loaded&&!this.el("apps").hidden){this.loaded=true;this.candidates();}
  },
  edit(){
    this.draft={...(this.draft||{}),enabled:this.el("drive-enabled").checked,paused:this.el("drive-paused").checked,
      volumes:[...this.el("drive-volumes").querySelectorAll("input:checked")].map(el=>el.value)};
    this.dirty=true;this.render();
  },
  async save(){
    if(this.pending.has("discovery")||!this.dirty)return;
    const options={...(info.discovery?.options||{}),...this.draft};
    const ok=await this.action("discovery","set_discovery_options",{options},"discovery","Drive choices saved.");
    if(ok){this.dirty=false;this.draft=null;this.render();this.candidates();}
  },
  async action(source,command,args,key,success){
    if(this.pending.has(source))return false;
    const token=Symbol(command);this.pending.set(source,token);
    this.message(source,command==="install_discovery_component"?"Windows will request administrator permission. Directory discovery remains available.":"Saving request.");
    this.render();
    let ok=false;
    try{
      const reply=await invoke(command,args);
      if(this.pending.get(source)!==token)return false;
      this.accept(key,reply);ok=true;this.message(source,success||"Options saved.");
    }catch(error){this.message(source,error?.message||String(error));}
    finally{
      if(this.pending.get(source)===token){this.pending.delete(source);this.providerDrafts.delete(source);this.render();}
    }
    return ok;
  },
  settingsOptions(){
    const options={enabled:this.el("win-settings-enabled").checked,semanticEnabled:this.el("win-settings-purpose").checked,
      ordinarySearches:this.el("win-settings-ordinary").checked};
    this.providerDrafts.set("windows",options);
    return this.action("windows","set_windows_settings_options",{options},"windowsSettings","Windows Settings choices saved.");
  },
  enrichmentOptions(){
    const options={enabled:this.el("descriptions-enabled").checked,publisherPages:this.el("descriptions-publishers").checked};
    this.providerDrafts.set("enrichment",options);
    return this.action("enrichment","set_app_enrichment_options",{options},"enrichment","Description choices saved.");
  },
  async candidates(append=false){
    const generation=++this.generation,q=this.el("drive-filter").value,classification=this.el("drive-visibility").value;
    this.currentResults=false;this.loading=true;this.renderCandidates();
    this.el("drive-retry-list").hidden=true;this.text("drive-list-state","Reading the cached executable catalog.");
    try{
      const reply=await invoke("discovery_candidates",{q,classification,offset:append?this.offset:0,limit:50,generation});
      if(generation!==this.generation||reply?.generation!==generation)return;
      this.hits=append?[...this.hits,...reply.hits]:reply.hits;this.offset=this.hits.length;
      this.total=reply.total;this.catalogTotal=reply.catalogTotal;this.currentResults=true;
      this.text("drive-count",this.n(this.offset)+" of "+this.n(reply.total)+" matching executables");
      this.el("drive-more").hidden=this.offset>=reply.total;
      this.text("drive-list-state",this.hits.length?"":this.emptyMessage(q,classification));
    }catch(error){
      if(generation===this.generation){this.text("drive-list-state","Could not read the executable catalog. "+(error?.message||String(error)));this.el("drive-retry-list").hidden=false;}
    }finally{if(generation===this.generation){this.loading=false;this.renderCandidates();}}
  },
  emptyMessage(q,classification){
    const d=info.discovery||{};
    if(d.catalogEnabled===false)return "Application search is off. Enable installed applications above to resume drive discovery.";
    if(q.trim())return "No executables match this name. Try another name or clear the search.";
    if(!d.options?.enabled)return "Drive discovery is off. Enable it and save your drive choices.";
    if(!d.options?.volumes?.length)return "No drives are selected. Choose drives and save to begin discovery.";
    if(d.running)return "Discovery is running. Candidates will appear as executable details are prepared.";
    if(d.progress?.phase==="failed")return "Discovery needs attention. Review the drive status above, then rescan.";
    if(this.catalogTotal===0)return "No executable candidates were found on the selected drives.";
    if(classification==="review")return "No executables need review. Choose All to see included and excluded entries.";
    return "No executables match this filter. Choose All to browse the cached catalog.";
  },
  renderCandidates(){
    const box=this.el("drive-candidates");
    box.setAttribute("aria-busy",String(Boolean(this.loading)));
    const present=new Set(this.hits.map(hit=>hit.id));
    for(const[id,row]of this.rows)if(!present.has(id)){row.root.remove();this.rows.delete(id);}
    const reasons={not_portable_executable:"Not a launchable Windows executable",internal_or_installation_tool:"May be an installer or internal helper",
      command_line_program:"Command line program",application_identity_uncertain:"Application identity needs review",identified_gui_application:"Identified desktop application",
      user_included:"Included by you",user_selected:"Included by you",user_hidden:"Hidden by you"};
    for(let index=0;index<this.hits.length;index++){
      const hit=this.hits[index];
      let row=this.rows.get(hit.id);
      if(!row){
        const root=element("div","source-candidate");root.dataset.candidateId=hit.id;
        const name=element("strong"),publisher=element("span","app-description"),path=element("span","source-path"),reason=element("span","note");
        const actions=element("div","apps-settings-actions");
        row={root,name,publisher,path,reason,actions,buttons:new Map()};root.append(name,publisher,path,reason,actions);
        for(const[action,label]of [["include","Include app"],["hide","Hide"],["reset","Reset review"]]){
          const button=element("button","",label);button.type="button";
          button.onclick=()=>this.review(hit.id,action);actions.append(button);row.buttons.set(action,button);
        }
        this.rows.set(hit.id,row);
      }
      for(const[key,value]of [["name",hit.name||hit.path.split(/[\\/]/).pop()],["publisher",hit.publisher||hit.product||"Publisher not provided"],
        ["path",hit.path],["reason",reasons[hit.reason]||hit.reason||hit.classification]])if(row[key].textContent!==value)row[key].textContent=value;
      const pending=this.candidatePending.has(hit.id);
      row.root.dataset.pending=String(pending);
      for(const[action,button]of row.buttons)button.disabled=pending||!this.currentResults||action==="include"&&!hit.portable;
      if(box.children[index]!==row.root)box.insertBefore(row.root,box.children[index]||null);
    }
  },
  async review(id,action){
    if(this.candidatePending.has(id)||!this.currentResults)return;
    this.candidatePending.add(id);this.renderCandidates();
    try{
      this.accept("discovery",await invoke("set_discovery_candidate",{candidateId:id,action}));
      this.message("discovery",action==="include"?"Application included.":"Review choice saved.");
      this.render();await this.candidates();
    }catch(error){this.message("discovery",error?.message||String(error));}
    finally{this.candidatePending.delete(id);this.renderCandidates();}
  },
};
