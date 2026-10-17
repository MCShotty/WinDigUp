use crate::{applications::enrichment::Options,Shell};
use serde_json::Value;
use std::sync::Arc;
use tauri::{AppHandle,State};
use tauri_plugin_opener::OpenerExt;
#[tauri::command]
pub fn set_app_enrichment_options(shell:State<'_,Arc<Shell>>,options:Options)->Result<Value,String>{
    let mut current=shell.settings.lock().unwrap();let mut next=current.clone();next.enrichment=options.clone();
    next.save(&shell.settings_path).map_err(|e|e.to_string())?;*current=next;drop(current);
    shell.enrichment.configure(options);Ok(shell.enrichment.info())
}
#[tauri::command]
pub fn refresh_app_descriptions(shell:State<'_,Arc<Shell>>)->Value{
    shell.enrichment.retry();shell.enrichment.info()
}
#[tauri::command]
pub fn clear_app_descriptions(shell:State<'_,Arc<Shell>>)->Result<Value,String>{
    let options={
        let mut current=shell.settings.lock().unwrap();let mut next=current.clone();next.enrichment.enabled=false;
        next.save(&shell.settings_path).map_err(|e|e.to_string())?;*current=next;current.enrichment.clone()
    };
    shell.enrichment.configure(options);shell.enrichment.clear();Ok(shell.enrichment.info())
}
#[tauri::command]
pub fn open_app_description_source(app:AppHandle,shell:State<'_,Arc<Shell>>,app_id:String)->Result<(),String>{
    let source=shell.applications.description_source(&app_id).ok_or("This application has no fetched description source.")?;
    let source=crate::applications::enrichment::public_url(&source)?;
    app.opener().open_url(source.as_str(),None::<&str>).map_err(|e|e.to_string())
}
