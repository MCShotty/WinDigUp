//! The lexical path never contacts the helper. Only purpose matching joins its inference queue.
use crate::{
    applications::{AppError, Override},
    Shell,
};
use serde_json::{json, Value};
use std::sync::{atomic::Ordering, Arc};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, State};

pub struct Foreground<'a>(&'a Shell);
impl<'a> Foreground<'a> {
    pub fn new(shell: &'a Shell) -> Self {
        shell.app_foreground.fetch_add(1, Ordering::SeqCst);
        *shell.app_last_query.lock().unwrap() = Instant::now();
        Self(shell)
    }
    fn passive(shell: &'a Shell) -> Self {
        shell.app_foreground.fetch_add(1, Ordering::SeqCst);
        Self(shell)
    }
}
impl Drop for Foreground<'_> {
    fn drop(&mut self) {
        self.0.app_foreground.fetch_sub(1, Ordering::SeqCst);
    }
}

async fn synchronize(shell: &Shell) -> Result<String, String> {
    let mut synced = shell.app_sync.lock().await;
    let revision = shell.applications.revision();
    let generation = shell.search.generation();
    if synced
        .as_ref()
        .is_none_or(|(epoch, stamp)| *epoch != generation || stamp != &revision)
    {
        let mut documents = shell.applications.documents();
        let revision = documents["revision"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        documents["op"] = json!("apps_catalog");
        shell.search.ask(documents).await?;
        *synced = Some((shell.search.generation(), revision.clone()));
        return Ok(revision);
    }
    Ok(revision)
}

#[tauri::command]
pub async fn search_apps(
    window: tauri::WebviewWindow,
    shell: State<'_, Arc<Shell>>,
    q: String,
    meaning: bool,
    generation: Option<u64>,
    session_id: Option<u64>,
    limit: Option<usize>,
    offset: Option<usize>,
    include_hidden: Option<bool>,
    visibility: Option<String>,
    anchor_id: Option<String>,
    passive: Option<bool>,
) -> Result<Value, String> {
    if q.chars().count() > 4096 {
        return Err("Application query is too long.".into());
    }
    let started = Instant::now();
    let session = format!("{}:{}:apps",window.label(),session_id.unwrap_or(0));
    shell.search.advance_session(&session,generation.unwrap_or(0));
    let visibility = visibility.as_deref().unwrap_or(if include_hidden.unwrap_or(false) { "all" } else { "visible" });
    if !matches!(visibility, "visible" | "hidden" | "all") { return Err("Unknown application visibility filter.".into()); }
    if !passive.unwrap_or(false) {
        *shell.app_last_query.lock().unwrap() = Instant::now();
    }
    shell.applications.refresh_if_stale();
    let mut hits = shell
        .applications
        .search(q.trim(), visibility != "visible");
    let mut semantic = if shell.applications.semantic_enabled() {
        shell.app_semantic.lock().unwrap().clone()
    } else {
        json!({"state":"disabled"})
    };
    if shell.applications.semantic_enabled() && !shell.model_ready() {
        let model = shell.model_state.lock().unwrap().clone();
        semantic["state"] = json!(if model["state"] == "failed" {
            "unavailable"
        } else {
            "preparing"
        });
        if model["state"] == "failed" {
            semantic["message"] = model["message"].clone();
        }
    }
    if meaning
        && !q.trim().is_empty()
        && shell.applications.semantic_enabled()
        && shell.model_ready()
    {
        let _foreground = if passive.unwrap_or(false) {
            Foreground::passive(&shell)
        } else {
            Foreground::new(&shell)
        };
        let result = async {
            // A restarted helper can have lost its in-memory protocol state. One resync retry is bounded and read-only.
            for _ in 0..2 {
                let revision = synchronize(&shell).await?;
                let reply = shell
                    .search
                    .ask(json!({"op":"apps_search","q":q.trim(),"revision":revision,
                        "session":session,"generation":generation.unwrap_or(0),"passive":passive.unwrap_or(false)}))
                    .await?;
                if reply["status"] == "superseded" { return Ok(reply); }
                if reply["revision"] == revision && shell.applications.revision() == revision {
                    return Ok::<Value, String>(reply);
                }
                *shell.app_sync.lock().await = None;
            }
            Err("Applications changed during the search; try again.".into())
        }
        .await;
        match result {
            Ok(mut reply) => {
                if reply["status"] == "superseded" { return Ok(json!({"status":"superseded","generation":generation.unwrap_or(0)})); }
                hits = shell
                    .applications
                    .search(q.trim(), include_hidden.unwrap_or(false));
                hits = shell.applications.merge_semantic(
                    hits,
                    reply["hits"].as_array().map(Vec::as_slice).unwrap_or(&[]),
                );
                // Internal candidate IDs are unpaginated. Cache/report only bounded native hits plus preparation state.
                if let Some(state) = reply.as_object_mut() {
                    state.remove("hits");
                }
                semantic = reply;
                if !shell.applications.semantic_enabled() {
                    hits = shell
                        .applications
                        .search(q.trim(), include_hidden.unwrap_or(false));
                    semantic = json!({"state":"disabled"});
                }
            }
            Err(error) => {
                semantic = json!({"state":"unavailable","message":error});
            }
        }
        *shell.app_semantic.lock().unwrap() = semantic.clone();
    }
    let anchor_offset = crate::applications::anchor_offset(&hits, visibility, anchor_id.as_deref());
    let (hits, total, offset) = crate::applications::page_hits(hits, visibility, offset.unwrap_or(0), limit.unwrap_or(6));
    Ok(
        json!({"hits":hits,"total":total,"offset":offset,"anchorOffset":anchor_offset,"generation":generation.unwrap_or(0),
        "catalog":shell.applications.info(),"semantic":semantic,"ms":started.elapsed().as_secs_f64()*1000.0}),
    )
}

#[tauri::command]
pub async fn cancel_app_search(window: tauri::WebviewWindow, shell: State<'_, Arc<Shell>>, generation:u64, session_id:Option<u64>) -> Result<Value,String> {
    shell.search.ask(json!({"op":"cancel","session":format!("{}:{}:apps",window.label(),session_id.unwrap_or(0)),"generation":generation})).await
}

#[tauri::command]
pub async fn launch_app(
    app: AppHandle,
    shell: State<'_, Arc<Shell>>,
    app_id: String,
) -> Result<Value, AppError> {
    let catalog = shell.applications.clone();
    let id = app_id.clone();
    tauri::async_runtime::spawn_blocking(move || catalog.launch(&id))
        .await
        .map_err(|e| AppError::new("launch_failed", &app_id, e.to_string()))??;
    crate::hide_panel(app);
    Ok(json!({"accepted":true,"appId":app_id}))
}
#[tauri::command]
pub async fn app_icon(
    app: AppHandle,
    shell: State<'_, Arc<Shell>>,
    app_id: String,
    size: Option<u32>,
) -> Result<String, AppError> {
    let catalog = shell.applications.clone();
    let id = app_id.clone();
    let path =
        tauri::async_runtime::spawn_blocking(move || catalog.icon_path(&id, size.unwrap_or(64)))
            .await
            .map_err(|e| AppError::new("unavailable", &app_id, e.to_string()))??;
    app.asset_protocol_scope()
        .allow_file(&path)
        .map_err(|e| AppError::new("unavailable", &app_id, e.to_string()))?;
    Ok(path.to_string_lossy().into())
}
#[tauri::command]
pub fn refresh_apps(shell: State<'_, Arc<Shell>>) -> Value {
    shell.applications.refresh();
    shell.applications.info()
}

/// An explicit preparation request may wake the encoder; passive background steps still never do.
#[tauri::command]
pub async fn prepare_apps(shell: State<'_, Arc<Shell>>) -> Result<Value, String> {
    if !shell.applications.semantic_enabled() { return Err("Enable application purpose matching first.".into()); }
    if !shell.model_ready() { return Err("The selected accelerator is not ready. Check General and Storage.".into()); }
    let _foreground = Foreground::new(&shell);
    let retry = shell.app_semantic.lock().unwrap()["encoder"] == "unavailable" || shell.search.snapshot()["error"].is_string();
    if retry {
        let search = shell.search.clone();
        tauri::async_runtime::spawn_blocking(move || search.stop()).await.map_err(|error|error.to_string())?;
        *shell.app_sync.lock().await = None;
    }
    synchronize(&shell).await?;
    let reply = shell.search.ask(json!({"op":"prewarm"})).await?;
    let state = shell.search.ask(json!({"op":"apps_status"})).await?;
    *shell.app_semantic.lock().unwrap() = state.clone();
    shell.diagnostics.record("applications", state.clone());
    if reply["encoder"] == "unavailable" { return Err(state["message"].as_str().unwrap_or("The selected accelerator is unavailable.").into()); }
    Ok(state)
}

#[tauri::command]
pub fn set_app_options(
    shell: State<'_, Arc<Shell>>,
    enabled: bool,
    semantic_enabled: bool,
    mixed_search: Option<crate::applications::MixedSearch>,
) -> Result<Value, String> {
    let options = {
        let mut settings = shell.settings.lock().unwrap();
        let mut next = settings.clone();
        next.applications.enabled = enabled;
        next.applications.semantic_enabled = semantic_enabled;
        if let Some(value) = mixed_search { next.applications.mixed_search = value; }
        next.save(&shell.settings_path).map_err(|e| e.to_string())?;
        *settings = next;
        settings.applications.clone()
    };
    shell.applications.configure(options);
    Ok(shell.applications.info())
}
#[tauri::command]
pub fn set_app_override(
    shell: State<'_, Arc<Shell>>,
    app_id: String,
    value: Override,
) -> Result<Value, String> {
    value.validate()?;
    if !app_id.starts_with("app:")
        || app_id.len() != 68
        || !app_id[4..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err("Invalid application identity.".into());
    }
    let options = {
        let mut settings = shell.settings.lock().unwrap();
        let mut next = settings.clone();
        if value.aliases.is_empty() && value.purpose.trim().is_empty() && !value.hidden {
            next.applications.overrides.remove(&app_id);
        } else {
            next.applications.overrides.insert(app_id, value);
        }
        next.save(&shell.settings_path).map_err(|e| e.to_string())?;
        *settings = next;
        settings.applications.clone()
    };
    shell.applications.configure(options);
    Ok(shell.applications.info())
}

pub fn start(app: &AppHandle, shell: &Arc<Shell>) {
    shell.applications.start();
    let weak = Arc::downgrade(shell);
    let app = app.clone();
    std::thread::spawn(move || {
        let mut previous = Value::Null;
        let mut renewed = Instant::now() - Duration::from_secs(3);
        loop {
            std::thread::sleep(Duration::from_millis(150));
            let Some(shell) = weak.upgrade() else { break };
            if shell.quitting.load(Ordering::SeqCst) {
                break;
            }
            if renewed.elapsed() >= Duration::from_millis(500)
                && (shell.app_foreground.load(Ordering::SeqCst) != 0 || shell.app_last_query.lock().unwrap().elapsed() < Duration::from_secs(1)) {
                shell.index.foreground(); renewed = Instant::now();
            }
            if !crate::applications::Catalog::supported() { continue; }
            if !shell.applications.semantic_enabled()
                || !shell.model_ready()
                || shell.app_foreground.load(Ordering::SeqCst) != 0
                || shell.app_last_query.lock().unwrap().elapsed() < Duration::from_secs(1)
            {
                continue;
            }
            let state = shell.app_semantic.lock().unwrap().clone();
            if state["revision"] == shell.applications.revision()
                && (state["encoder"] == "stopped"
                    || state["encoder"] == "unavailable"
                    || state["total"]
                        .as_u64()
                        .is_some_and(|n| state["embedded"].as_u64() == Some(n)))
            {
                continue;
            }
            let result = tauri::async_runtime::block_on(async {
                if shell.quitting.load(Ordering::SeqCst) {
                    return Ok::<Value, String>(Value::Null);
                }
                synchronize(&shell).await?;
                if shell.quitting.load(Ordering::SeqCst)
                    || shell.app_foreground.load(Ordering::SeqCst) != 0
                {
                    return Ok::<Value, String>(Value::Null);
                }
                // Exactly one document per request; the helper refuses to wake a stopped encoder here.
                shell.search.ask(json!({"op":"apps_index_step"})).await
            });
            let state = match result {
                Ok(state) if !state.is_null() => state,
                Ok(_) => continue,
                Err(error) => json!({"state":"unavailable","encoder":"unavailable","message":error,
                    "revision":shell.applications.revision()}),
            };
            *shell.app_semantic.lock().unwrap() = state.clone();
            if state != previous {
                previous = state.clone();
                shell.diagnostics.record("applications", state.clone());
                let _ = app.emit("applications-progress", state);
            }
        }
    });
}
