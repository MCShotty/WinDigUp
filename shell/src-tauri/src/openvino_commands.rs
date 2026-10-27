use crate::{acceleration::Acceleration, Shell};
use serde_json::Value;
use std::sync::Arc;
use tauri::{AppHandle, State};
use tauri_plugin_dialog::DialogExt;

#[tauri::command]
pub async fn openvino_status(shell: State<'_,Arc<Shell>>, acceleration: Acceleration) -> Result<Value,String> {
    let setup=shell.intel_setup.clone();
    tauri::async_runtime::spawn_blocking(move ||setup.inspect(acceleration)).await.map_err(|error|error.to_string())?
}

#[tauri::command]
pub fn openvino_preparation(shell: State<'_,Arc<Shell>>) -> Value { shell.intel_setup.snapshot() }

#[tauri::command]
pub fn prepare_openvino(shell: State<'_,Arc<Shell>>, acceleration: Acceleration, source:String, revision:String) -> Result<Value,String> {
    shell.intel_setup.start(acceleration,source,revision)
}

#[tauri::command]
pub fn cancel_openvino_preparation(shell: State<'_,Arc<Shell>>) -> Value { shell.intel_setup.cancel() }

#[tauri::command]
pub async fn pick_openvino_path(app:AppHandle, kind:String) -> Result<Option<String>,String> {
    let (send,receive)=tokio::sync::oneshot::channel();
    match kind.as_str() {
        "python"=>app.dialog().file().set_title("Choose an OpenVINO Python executable").add_filter("Python executable",&["exe"])
            .pick_file(move |file|{let _=send.send(file.and_then(|file|file.into_path().ok()).map(|path|path.display().to_string()));}),
        "models"|"source"=>app.dialog().file().set_title(if kind=="source"{"Choose a complete local Transformers checkpoint"}else{"Choose an exported OpenVINO bundle"})
            .pick_folder(move |file|{let _=send.send(file.and_then(|file|file.into_path().ok()).map(|path|path.display().to_string()));}),
        _=>return Err("Unknown Intel setup picker.".into()),
    }
    receive.await.map_err(|error|error.to_string())
}
