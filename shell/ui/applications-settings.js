"use strict";
const appDrafts = new Map();
let appSettingsGeneration = 0, appSettingsOffset = 0, appSettingsTimer, appSettingsInfo = {}, appSettingsHits = [];
let appSettingsSelected = null, appSettingsSignature = "", appSettingsReady = false, appOptionsPending = false;
let appPreparationPending = false;
const appSavesPending = new Set();

function renderApplications(statusOnly = false) {
  const catalog = info.applications || {}, semantic = info.applicationSemantic || {}, model = info.state?.model || {};
  appSettingsReady = true; appSettingsInfo = catalog;
  document.getElementById("apps-tab").hidden = !catalog.supported;
  if (!appOptionsPending) {
    document.getElementById("apps-enabled").checked = Boolean(catalog.enabled);
    document.getElementById("apps-semantic").checked = Boolean(catalog.semanticEnabled);
  }
  document.getElementById("apps-enabled").disabled = appOptionsPending;
  document.getElementById("apps-semantic").disabled = appOptionsPending || !catalog.enabled;
  const issues = Object.values(catalog.sourceErrors || {});
  const complete = typeof semantic.total === "number" && semantic.embedded === semantic.total;
  const prepared = typeof semantic.total === "number" && typeof semantic.embedded === "number"
    ? `${semantic.embedded.toLocaleString()} of ${semantic.total.toLocaleString()} prepared` : "Preparation has not reported a total yet";
  const purpose = !catalog.enabled || !catalog.semanticEnabled ? "Purpose matching off."
    : model.state === "failed" || semantic.state === "unavailable" ? `Purpose matching unavailable: ${semantic.message || model.message || "check the selected accelerator"}`
    : model.state && model.state !== "ready" ? "Purpose matching is waiting for the selected accelerator."
    : complete ? `${semantic.embedded.toLocaleString()} of ${semantic.total.toLocaleString()} prepared${semantic.encoder === "ready" ? " · Ready" : " · Encoder idle; a purpose search starts it"}`
    : `${prepared}${semantic.encoder === "stopped" || !semantic.encoder ? " · Purpose matching idle" : " · Preparing"}`;
  document.getElementById("apps-catalog-status").textContent = !catalog.enabled ? "Application discovery off. Your annotations are kept."
    : `${(catalog.count || 0).toLocaleString()} apps available by name${catalog.refreshing ? " · Refreshing Windows catalog…" : " · Launch through Windows"}${issues.length ? ` · Some sources could not refresh: ${issues.join("; ")}` : ""}`;
  document.getElementById("apps-purpose-status").textContent = purpose;
  document.getElementById("apps-prepare").disabled = !catalog.enabled || !catalog.semanticEnabled || model.state !== "ready" || complete || appPreparationPending;
  document.getElementById("apps-refresh").disabled = !catalog.enabled || Boolean(catalog.refreshing);
  updateAppDraftCount();
  if (!statusOnly && catalog.supported && !document.getElementById("apps").hidden) loadApplicationSettings();
}

function updateAppDraftCount() {
  const text=appDrafts.size ? `${appDrafts.size} application${appDrafts.size === 1 ? " has" : "s have"} unsaved changes. Drafts are kept while this window is open.` : "";
  if(document.getElementById("apps-drafts").textContent!==text)document.getElementById("apps-drafts").textContent=text;
}

document.getElementById("apps-prepare").onclick = async () => {
  appPreparationPending = true; renderApplications(true);
  try { info.applicationSemantic = await invoke("prepare_apps"); }
  catch (error) { fail(error?.message || error); }
  finally { appPreparationPending = false; renderApplications(true); }
};

async function loadApplicationSettings(append = false) {
  if (!appSettingsInfo.supported) return;
  const query = document.getElementById("apps-filter").value, visibility = document.getElementById("apps-visibility").value;
  const signature = `${query}\0${visibility}`;
  const wanted = signature === appSettingsSignature ? Math.max(100, appSettingsHits.length) : 100;
  appSettingsSignature = signature;
  const generation = ++appSettingsGeneration;
  try {
    const getPage = offset => invoke("search_apps", { q: query, meaning: false, generation, limit:100, offset, includeHidden:true, visibility });
    const reply = await getPage(append ? appSettingsOffset : 0);
    if (generation !== appSettingsGeneration || reply.generation !== generation) return;
    const hits = reply.hits || [];
    while (!append && hits.length < wanted && hits.length < reply.total) {
      const next = await getPage(hits.length);
      if (generation !== appSettingsGeneration) return;
      if (next.catalog?.revision !== reply.catalog?.revision) { clearTimeout(appSettingsTimer);appSettingsTimer=setTimeout(()=>loadApplicationSettings(),150);return; }
      if (!next.hits?.length) break;
      hits.push(...next.hits);
    }
    appSettingsHits = append ? [...appSettingsHits, ...hits.filter(hit => !appSettingsHits.some(old=>old.id===hit.id))] : hits;
    appSettingsOffset = appSettingsHits.length;
    document.getElementById("apps-more").hidden = appSettingsOffset >= reply.total;
    document.getElementById("apps-list-count").textContent = `${appSettingsOffset.toLocaleString()} of ${(reply.total || 0).toLocaleString()} matching applications`;
    if (!appSettingsHits.some(hit=>hit.id===appSettingsSelected)) appSettingsSelected = appSettingsHits[0]?.id || null;
    renderApplicationList(); renderApplicationEditor();
  } catch (error) { if(generation === appSettingsGeneration) fail(error?.message || error); }
}

function renderApplicationList() {
  const list = document.getElementById("apps-list");
  const focused = list.contains(document.activeElement) ? document.activeElement.dataset.appId : null;
  list.replaceChildren();
  for (const hit of appSettingsHits) {
    const row = element("button", "app-settings-row"); row.type="button"; row.dataset.appId=hit.id;
    row.setAttribute("role","option"); row.setAttribute("aria-selected",String(hit.id===appSettingsSelected));
    row.tabIndex = hit.id === appSettingsSelected ? 0 : -1;
    row.append(element("span","app-name",hit.name));
    if(hit.publisher)row.append(element("span","app-description",hit.publisher));
    if(hit.hidden)row.append(element("span","app-visibility-note","Hidden from search"));
    if(appDrafts.has(hit.id))row.append(element("span","app-draft-mark","Unsaved"));
    row.onclick=()=>selectApplicationSettings(hit.id);
    row.onkeydown=event=>{
      if(!["ArrowDown","ArrowUp","Home","End"].includes(event.key))return;
      event.preventDefault();
      const index=appSettingsHits.findIndex(item=>item.id===hit.id);
      const next=event.key==="Home"?0:event.key==="End"?appSettingsHits.length-1:Math.max(0,Math.min(appSettingsHits.length-1,index+(event.key==="ArrowDown"?1:-1)));
      selectApplicationSettings(appSettingsHits[next].id);
      list.querySelector(`[data-app-id="${CSS.escape(appSettingsSelected)}"]`)?.focus();
    };
    list.append(row);
  }
  if(!appSettingsHits.length)list.append(element("p","app-description",appSettingsInfo.enabled ? "No applications match this filter." : "Enable application discovery to customize apps."));
  if(focused)list.querySelector(`[data-app-id="${CSS.escape(focused)}"]`)?.focus();
}

function selectApplicationSettings(id) {
  appSettingsSelected=id;
  for(const row of document.querySelectorAll(".app-settings-row")){
    row.setAttribute("aria-selected",String(row.dataset.appId===id)); row.tabIndex=row.dataset.appId===id?0:-1;
  }
  renderApplicationEditor();
}

function renderApplicationEditor(force = false) {
  const box=document.getElementById("apps-editors"), hit=appSettingsHits.find(hit=>hit.id===appSettingsSelected);
  if(!hit){box.replaceChildren(element("p","app-description","Select an application to edit its search options."));delete box.dataset.appId;return;}
  if(!force && box.dataset.appId===hit.id){box.querySelector(".app-editor-name").textContent=hit.name;return;}
  box.dataset.appId=hit.id;
  const form=element("form","app-editor");
  form.append(element("h3","app-editor-name",hit.name));
  if(hit.publisher)form.append(element("p","app-description",hit.publisher));
  if(hit.description)form.append(element("p","app-editor-purpose",hit.description));
  const initial={aliasesText:(hit.aliases||[]).join("\n"),purposeText:hit.purpose||"",hidden:Boolean(hit.hidden)};
  const value=appDrafts.get(hit.id)||initial;
  const aliases=element("textarea");aliases.value=value.aliasesText;aliases.maxLength=16*161;
  aliases.setAttribute("aria-label",`${hit.name} aliases`);aliases.rows=3;
  const purpose=element("textarea");purpose.value=value.purposeText;purpose.maxLength=2048;purpose.rows=4;
  purpose.setAttribute("aria-label",`${hit.name} purpose`);purpose.placeholder=hit.description||"Describe what you use this app for";
  const hidden=element("input");hidden.type="checkbox";hidden.checked=value.hidden;
  const aliasesLabel=element("label","","Aliases (one per line)");aliasesLabel.append(aliases);
  const purposeLabel=element("label","","What this application does");purposeLabel.append(purpose);
  const hiddenLabel=element("label","app-hidden-option","Hide from search");hiddenLabel.prepend(hidden);
  const note=element("p","app-description","Up to 16 aliases, 80 characters each. Purpose: up to 1,024 characters. Empty fields use Windows metadata.");
  const message=element("p","app-editor-message");message.setAttribute("role","status");
  const actions=element("div","apps-settings-actions");
  const save=element("button","primary","Save"),revert=element("button","","Revert"),reset=element("button","","Reset overrides");
  save.type="submit";revert.type=reset.type="button";
  function changed(){
    const draft={aliasesText:aliases.value,purposeText:purpose.value,hidden:hidden.checked};
    if(JSON.stringify(draft)===JSON.stringify(initial))appDrafts.delete(hit.id);else appDrafts.set(hit.id,draft);
    save.disabled=revert.disabled=appSavesPending.has(hit.id)||!appDrafts.has(hit.id); updateAppDraftCount();
    const row=document.querySelector(`.app-settings-row[data-app-id="${CSS.escape(hit.id)}"]`);
    row?.querySelector(".app-draft-mark")?.remove();
    if(appDrafts.has(hit.id))row?.append(element("span","app-draft-mark","Unsaved"));
  }
  aliases.oninput=purpose.oninput=hidden.onchange=changed;
  async function commit(value){
    if(appSavesPending.has(hit.id))return;
    appSavesPending.add(hit.id);aliases.disabled=purpose.disabled=hidden.disabled=true;
    save.disabled=revert.disabled=reset.disabled=true;message.textContent="Saving…";
    try{
      await invoke("set_app_override",{appId:hit.id,value});appDrafts.delete(hit.id);updateAppDraftCount();
      const current=appSettingsHits.find(item=>item.id===hit.id);if(current)Object.assign(current,value);
      if(appSettingsSelected===hit.id)renderApplicationEditor(true);
      await loadApplicationSettings();
    }catch(error){message.textContent=error?.message||String(error);}
    finally{
      appSavesPending.delete(hit.id);aliases.disabled=purpose.disabled=hidden.disabled=false;
      if(appSettingsSelected===hit.id){
        const currentForm=document.getElementById("apps-editors");
        for(const field of currentForm.querySelectorAll("textarea,input,button"))field.disabled=false;
        const buttons=currentForm.querySelectorAll("button");if(buttons.length>=2)buttons[0].disabled=buttons[1].disabled=!appDrafts.has(hit.id);
      }
    }
  }
  form.onsubmit=event=>{
    event.preventDefault();
    const values=aliases.value.split("\n").map(text=>text.trim()).filter(Boolean);
    if(values.length>16||values.some(text=>[...text].length>80)){message.textContent="Use up to 16 aliases, with at most 80 characters each.";return;}
    if([...purpose.value.trim()].length>1024){message.textContent="Use at most 1,024 characters for the purpose description.";return;}
    commit({aliases:values,purpose:purpose.value.trim(),hidden:hidden.checked});
  };
  revert.onclick=()=>{appDrafts.delete(hit.id);updateAppDraftCount();renderApplicationEditor(true);renderApplicationList();};
  reset.onclick=()=>commit({aliases:[],purpose:"",hidden:false});
  actions.append(save,revert,reset);form.append(aliasesLabel,purposeLabel,hiddenLabel,note,actions,message);
  box.replaceChildren(form);changed();
  if(appSavesPending.has(hit.id))for(const field of form.querySelectorAll("textarea,input,button"))field.disabled=true;
}

for(const id of ["apps-enabled","apps-semantic"]){
  document.getElementById(id).onchange=async()=>{
    const enabled=document.getElementById("apps-enabled").checked,semanticEnabled=document.getElementById("apps-semantic").checked;
    appOptionsPending=true;renderApplications(true);
    try{info.applications=await invoke("set_app_options",{enabled,semanticEnabled});}
    catch(error){fail(error?.message||error);}
    finally{appOptionsPending=false;renderApplications();}
  };
}
document.getElementById("apps-refresh").onclick=async()=>{
  try{info.applications=await invoke("refresh_apps");renderApplications();}
  catch(error){fail(error?.message||error);}
};
document.getElementById("apps-filter").oninput=()=>{clearTimeout(appSettingsTimer);appSettingsTimer=setTimeout(()=>loadApplicationSettings(),120);};
document.getElementById("apps-visibility").onchange=()=>loadApplicationSettings();
document.getElementById("apps-more").onclick=()=>loadApplicationSettings(true);
window.__TAURI__.event.listen("applications",({payload})=>{if(!appSettingsReady)return;info.applications=payload;renderApplications();});
window.__TAURI__.event.listen("applications-progress",({payload})=>{if(!appSettingsReady)return;info.applicationSemantic=payload;renderApplications(true);});
