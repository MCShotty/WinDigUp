use crate::{Shell,launcher};
use std::{sync::Arc,collections::HashMap};
use tauri::{AppHandle,State,Emitter};
use serde_json::{json,Value};
#[tauri::command]
pub fn launcher_apps(shell:State<'_,Arc<Shell>>)->Value{
    let options=shell.settings.lock().unwrap().launcher.clone();
    let visible=shell.applications.search("",false).into_iter().map(|h|(h.id.clone(),h)).collect::<HashMap<_,_>>();
    let mut ids=options.pinned.clone();if options.show_recent{ids.extend(shell.launcher_history.ids());}
    let mut used=std::collections::HashSet::new();
    let hits=ids.into_iter().filter(|id|used.insert(id.clone())).filter_map(|id|visible.get(&id)).take(6)
        .map(|h|{let mut v=serde_json::to_value(h).unwrap();v["pinned"]=json!(options.pinned.contains(&h.id));v}).collect::<Vec<_>>();
    json!({"hits":hits,"pinned":options.pinned,"showRecent":options.show_recent})
}
#[tauri::command]
pub fn pin_launcher_app(app:AppHandle,shell:State<'_,Arc<Shell>>,app_id:String,pinned:bool)->Result<Value,String>{
    if !launcher::valid_id(&app_id){return Err("Invalid application identity.".into())}
    let mut settings=shell.settings.lock().unwrap();let mut next=settings.clone();
    next.launcher.pinned.retain(|id|id!=&app_id);
    if pinned{
        if next.launcher.pinned.len()>=6{return Err("Unpin an app before adding another. The launcher holds six pins.".into())}
        if !shell.applications.search("",false).iter().any(|h|h.id==app_id){return Err("This application is unavailable.".into())}
        next.launcher.pinned.push(app_id);
    }
    next.save(&shell.settings_path).map_err(|e|e.to_string())?;*settings=next;drop(settings);
    let _=app.emit("launcher-changed",());Ok(json!({"saved":true}))
}
#[tauri::command]
pub fn set_launcher_recents(app:AppHandle,shell:State<'_,Arc<Shell>>,enabled:bool)->Result<(),String>{
    let mut settings=shell.settings.lock().unwrap();let mut next=settings.clone();next.launcher.show_recent=enabled;
    next.save(&shell.settings_path).map_err(|e|e.to_string())?;*settings=next;drop(settings);
    let _=app.emit("launcher-changed",());Ok(())
}
#[tauri::command]
pub async fn clear_launcher_recents(app:AppHandle,shell:State<'_,Arc<Shell>>)->Result<(),String>{
    let history=shell.launcher_history.clone();tauri::async_runtime::spawn_blocking(move||history.clear()).await.map_err(|e|e.to_string())??;
    let _=app.emit("launcher-changed",());Ok(())
}
