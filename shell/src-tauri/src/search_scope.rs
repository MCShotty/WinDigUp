use serde_json::{json, Value};
use std::future::Future;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Scope {
    pub roots: Vec<String>,
    pub skipped: Vec<String>,
    pub types: Vec<String>,
}

fn empty_reply(request: &Value, changed: bool) -> Value {
    let mut reply = json!({
        "protocol_version": 2, "ok": true, "hits": [], "strong": 0, "meaning": false,
        "facets": {}, "count_scope": "ranked_candidates", "exact_filename_known": true,
        "exact_filename": false, "scope_empty": true, "ms": {},
    });
    for key in ["session", "session_id", "generation", "phase", "id"] {
        if let Some(value) = request.get(key) { reply[key] = value.clone(); }
    }
    if changed { reply["status"] = json!("superseded"); reply["scope_empty"] = json!(false); }
    reply
}

/// Shell requests always carry a selection. An omitted selection remains a developer CLI convention.
pub async fn ask<F, Fut, Current>(mut request: Value, initial: Scope, current: Current, send: F) -> Result<Value, String>
where
    F: FnOnce(Value) -> Fut,
    Fut: Future<Output = Result<Value, String>>,
    Current: FnOnce() -> Scope,
{
    if request["op"] != "search" { return send(request).await; }
    if initial.roots.is_empty() { return Ok(empty_reply(&request, false)); }
    request["file_scope"] = json!({"version": 1, "roots": &initial.roots, "skipped": &initial.skipped, "types": &initial.types});
    let descriptor = request.clone();
    let reply = send(request).await;
    let latest = current();
    if latest.roots.is_empty() { return Ok(empty_reply(&descriptor, false)); }
    if latest != initial { return Ok(empty_reply(&descriptor, true)); }
    reply
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};

    fn scope(roots: &[&str]) -> Scope {
        Scope { roots: roots.iter().map(|value| value.to_string()).collect(), skipped: vec![], types: vec![] }
    }

    #[tokio::test]
    async fn no_folders_never_calls_a_retained_index_or_encoder() {
        for query in ["", "report"] {
            let called = Arc::new(AtomicBool::new(false)); let signal = called.clone();
            let reply = ask(json!({"op":"search","q":query,"meaning":true,"generation":7}), scope(&[]), || scope(&[]),
                move |_| async move {
                    signal.store(true, Ordering::SeqCst);
                    Ok(json!({"hits":[{"path":"old-index/report.txt"}]}))
                }).await.unwrap();
            assert!(!called.load(Ordering::SeqCst));
            assert_eq!(reply["hits"], json!([]));
            assert_eq!(reply["generation"], 7);
            assert_eq!(reply["meaning"], false);
            assert_eq!(reply["scope_empty"], true);
        }
    }

    #[tokio::test]
    async fn removal_while_waiting_cannot_publish_old_hits_or_restart_errors() {
        for failed in [false, true] {
            let live = Arc::new(Mutex::new(scope(&["chosen"]))); let update = live.clone(); let read = live.clone();
            let reply = ask(json!({"op":"search","q":"report"}), scope(&["chosen"]),
                move || read.lock().unwrap().clone(), move |_| async move {
                    *update.lock().unwrap() = scope(&[]);
                    if failed { Err("helper retired".into()) } else { Ok(json!({"hits":[{"path":"chosen/report.txt"}]})) }
                }).await.unwrap();
            assert_eq!(reply["hits"], json!([]));
            assert_eq!(reply["scope_empty"], true);
        }
    }

    #[tokio::test]
    async fn changed_nonempty_selection_supersedes_and_each_request_carries_scope() {
        let reply = ask(json!({"op":"search","q":"report"}), scope(&["old"]), || scope(&["new"]), |request| async move {
            assert_eq!(request["file_scope"]["roots"], json!(["old"]));
            assert_eq!(request["file_scope"]["version"], 1);
            Ok(json!({"hits":[{"path":"old/report.txt"}]}))
        }).await.unwrap();
        assert_eq!(reply["status"], "superseded");
        assert_eq!(reply["hits"], json!([]));
    }

    #[tokio::test]
    async fn app_settings_and_code_scope_are_independent_of_file_folder_selection() {
        for operation in ["apps_search", "settings_search", "prewarm"] {
            let reply = ask(json!({"op":operation}), scope(&[]), || scope(&[]),
                |request| async move { Ok(json!({"operation":request["op"],"available":true})) }).await.unwrap();
            assert_eq!(reply["available"], true);
        }
        let reply = ask(json!({"op":"search","code":true}), scope(&["code-root"]), || scope(&["code-root"]),
            |request| async move {
                assert_eq!(request["file_scope"]["roots"], json!(["code-root"]));
                Ok(json!({"hits":[{"path":"code-root/main.swift"}]}))
            }).await.unwrap();
        assert_eq!(reply["hits"].as_array().unwrap().len(), 1);
    }
}
