use crate::{application_commands::Foreground,system_settings::Options,Shell};
use serde_json::{json,Value};
use std::{sync::{Arc,atomic::Ordering},time::{Duration,Instant}};
use tauri::{AppHandle,Emitter,State};

async fn synchronize(shell:&Shell)->Result<String,String> {
    let mut synced=shell.settings_sync.lock().await;
    let revision=shell.windows_settings.revision();
    if synced.as_ref().is_none_or(|(epoch,stamp)|*epoch!=shell.search.generation()||stamp!=&revision) {
        let mut request=shell.windows_settings.documents();
        let revision=request["revision"].as_str().unwrap_or_default().to_string();
        request["op"]=json!("settings_catalog");request["passive"]=json!(true);
        shell.search.ask(request).await?;
        *synced=Some((shell.search.generation(),revision.clone()));return Ok(revision)
    }
    Ok(revision)
}
#[tauri::command]
pub async fn search_windows_settings(window:tauri::WebviewWindow,shell:State<'_,Arc<Shell>>,
    q:String,meaning:bool,generation:Option<u64>,session_id:Option<u64>,
    limit:Option<usize>,offset:Option<usize>,passive:Option<bool>)->Result<Value,String> {
    if q.chars().count()>4096{return Err("Windows settings query is too long.".into())}
    let started=Instant::now();
    let generation=generation.unwrap_or(0);
    let session=format!("{}:{}:windows-settings",window.label(),session_id.unwrap_or(0));
    shell.search.advance_session(&session,generation);
    if !passive.unwrap_or(false){*shell.app_last_query.lock().unwrap()=Instant::now();}
    let mut hits=shell.windows_settings.search(q.trim());
    let mut semantic=if shell.windows_settings.semantic_enabled(){shell.settings_semantic.lock().unwrap().clone()}
        else{json!({"state":"disabled"})};
    if meaning&&!q.trim().is_empty()&&shell.windows_settings.semantic_enabled()&&shell.model_ready() {
        let _foreground=if passive.unwrap_or(false){Foreground::passive(&shell)}else{Foreground::new(&shell)};
        let result=async {
            for _ in 0..2 {
                let revision=synchronize(&shell).await?;
                let reply=shell.search.ask(json!({"op":"settings_search","q":q.trim(),"revision":revision,
                    "generation":generation,"session":session,"passive":passive.unwrap_or(false)})).await?;
                if reply["status"]=="superseded"{return Ok(reply)}
                if reply["revision"]==revision&&shell.windows_settings.revision()==revision{return Ok::<Value,String>(reply)}
                *shell.settings_sync.lock().await=None;
            }
            Err("Windows settings changed during the search.".into())
        }.await;
        match result {
            Ok(mut reply)=>{
                if reply["status"]=="superseded"{return Ok(json!({"status":"superseded","generation":generation}))}
                hits=shell.windows_settings.merge(shell.windows_settings.search(q.trim()),
                    reply["hits"].as_array().map(Vec::as_slice).unwrap_or(&[]));
                if let Some(object)=reply.as_object_mut(){object.remove("hits");}
                semantic=reply;
            },
            Err(error)=>semantic=json!({"state":"unavailable","message":error}),
        }
    }
    shell.personalization.rank(&session, generation, &q, &mut hits,
        |hit| hit.id.clone(), |hit| crate::personalization::tier(&hit.reason));
    let total=hits.len();let offset=offset.unwrap_or(0).min(total);let limit=limit.unwrap_or(50).clamp(1,100);
    let mut hits:Vec<Value>=hits.into_iter().skip(offset).take(limit).map(|hit|serde_json::to_value(hit).unwrap()).collect();
    crate::personalization::match_sources(&mut hits, &q);
    shell.personalization.decorate(&session, generation, &mut hits);
    Ok(json!({"hits":hits,"total":total,"offset":offset,"generation":generation,"requestId":generation,
        "catalog":shell.windows_settings.info(),"semantic":semantic,"ms":started.elapsed().as_secs_f64()*1000.0}))
}
#[tauri::command]
pub fn cancel_windows_settings_search(window:tauri::WebviewWindow,shell:State<'_,Arc<Shell>>,session_id:Option<u64>,generation:u64) {
    shell.search.advance_session(&format!("{}:{}:windows-settings",window.label(),session_id.unwrap_or(0)),generation);
}
#[tauri::command]
pub async fn open_windows_setting(app:AppHandle,shell:State<'_,Arc<Shell>>,setting_id:String)->Result<(),String> {
    let shell=shell.inner().clone();
    let history=shell.personalization.clone();let key=setting_id.clone();
    tauri::async_runtime::spawn_blocking(move||shell.windows_settings.launch(&setting_id)).await.map_err(|e|e.to_string())??;
    history.accepted(&key);
    crate::hide_panel(app);
    Ok(())
}
#[tauri::command]
pub fn set_windows_settings_options(app:AppHandle,shell:State<'_,Arc<Shell>>,options:Options)->Result<Value,String> {
    let mut current=shell.settings.lock().unwrap();let mut next=current.clone();next.windows_settings=options.clone();
    next.save(&shell.settings_path).map_err(|e|e.to_string())?;*current=next;drop(current);
    shell.windows_settings.configure(options);let info=shell.windows_settings.info();
    let _=app.emit("windows-settings",info.clone());Ok(info)
}
#[tauri::command]
pub fn windows_settings_status(shell:State<'_,Arc<Shell>>)->Value {
    json!({"catalog":shell.windows_settings.info(),"semantic":shell.settings_semantic.lock().unwrap().clone()})
}
#[tauri::command]
pub async fn prepare_windows_settings(shell:State<'_,Arc<Shell>>)->Result<Value,String>{
    if !shell.windows_settings.semantic_enabled(){return Err("Enable Windows settings purpose matching first.".into())}
    if !shell.model_ready(){return Err("The selected accelerator is not ready. Check General and Storage.".into())}
    let _foreground=Foreground::new(&shell);
    if shell.settings_semantic.lock().unwrap()["encoder"]=="unavailable"||shell.search.snapshot()["error"].is_string(){
        let search=shell.search.clone();
        tauri::async_runtime::spawn_blocking(move||search.stop()).await.map_err(|e|e.to_string())?;
        *shell.settings_sync.lock().await=None;*shell.app_sync.lock().await=None;
    }
    synchronize(&shell).await?;
    shell.search.ask(json!({"op":"prewarm"})).await?;
    let state=shell.search.ask(json!({"op":"settings_status"})).await?;
    *shell.settings_semantic.lock().unwrap()=state.clone();
    if state["encoder"]=="unavailable"{return Err(state["message"].as_str().unwrap_or("The selected accelerator is unavailable.").into())}
    Ok(state)
}
pub fn start(app:&AppHandle,shell:&Arc<Shell>) {
    shell.windows_settings.refresh_if_stale();
    let weak=Arc::downgrade(shell);let app=app.clone();
    std::thread::spawn(move||{
        let mut previous=Value::Null;let mut logged=Value::Null;
        loop {
            std::thread::sleep(Duration::from_millis(500));
            let Some(shell)=weak.upgrade() else{break};
            if shell.quitting.load(Ordering::SeqCst){break}
            if !shell.windows_settings.semantic_enabled()||!shell.model_ready()
                ||shell.app_foreground.load(Ordering::SeqCst)!=0
                ||shell.app_last_query.lock().unwrap().elapsed()<Duration::from_secs(1){continue}
            let state=shell.settings_semantic.lock().unwrap().clone();
            if state["revision"]==shell.windows_settings.revision()
                &&(state["encoder"]=="stopped"||state["encoder"]=="unavailable"
                    ||state["embedded"].as_u64().is_some_and(|n|state["total"].as_u64()==Some(n))){continue}
            let result=tauri::async_runtime::block_on(async {
                synchronize(&shell).await?;
                if shell.quitting.load(Ordering::SeqCst)||shell.app_foreground.load(Ordering::SeqCst)!=0 {
                    return Ok::<Value,String>(Value::Null)
                }
                shell.search.ask(json!({"op":"settings_index_step"})).await
            });
            let state=match result {Ok(s) if !s.is_null()=>s,Ok(_)=>continue,
                Err(e)=>json!({"state":"unavailable","encoder":"unavailable","revision":shell.windows_settings.revision(),"message":e})};
            *shell.settings_semantic.lock().unwrap()=state.clone();
            if state!=previous {previous=state.clone();
                let significant=json!({"state":state["state"],"encoder":state["encoder"],"message":state["message"]});
                if significant!=logged{logged=significant.clone();shell.diagnostics.record("windows-settings",significant);}
                let _=app.emit("windows-settings-progress",state);}
        }
    });
}

#[tauri::command]
pub fn refresh_windows_settings(shell:State<'_,Arc<Shell>>)->Value {shell.windows_settings.refresh();shell.windows_settings.info()}

#[tauri::command]
pub async fn windows_setting_icon(app:AppHandle,shell:State<'_,Arc<Shell>>,setting_id:String,size:Option<u32>)->Result<String,String>{
    use tauri::Manager;
    let catalog=shell.windows_settings.clone();
    let path=tauri::async_runtime::spawn_blocking(move||catalog.icon_path(&setting_id,size.unwrap_or(64))).await.map_err(|e|e.to_string())??;
    app.asset_protocol_scope().allow_file(&path).map_err(|e|e.to_string())?;
    Ok(path.to_string_lossy().into())
}
