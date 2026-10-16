//! Versioned, cheap UI contracts. This module performs no I/O and never asks the encoder.
use serde_json::{json, Value};

pub struct Input {
    pub state: Value,
    pub catalog: Value,
    pub semantic: Value,
    pub configured: Value,
    pub helpers: Value,
    pub runtime: Value,
    pub events: Value,
    pub has_folders: bool,
    pub blocked_by: Option<&'static str>,
}

pub fn snapshot(input: Input) -> Value {
    let Input { state, catalog, semantic, configured, helpers, runtime, events, has_folders, blocked_by } = input;
    let scan = &state["scan"];
    let active = helpers["index"]["pid"].is_number() || helpers["index"]["busy"] == true;
    let phase = if !has_folders { "not_configured" }
        else if state["paused"] == true { if active { "pausing" } else { "paused" } }
        else if state["activity"] == "failed" || (state["lastError"].is_string() && state["activity"] == "idle") { "failed" }
        else if state["heldUntil"].is_string() && !active { "scheduled" }
        else if state["measuring"] == true { "checking_accelerator" }
        else if state["model"]["state"] == "failed" { "unavailable" }
        else if state["model"]["state"] != "ready" { "preparing_model" }
        else { match state["activity"].as_str().unwrap_or("starting") {
            "scanning" => match scan["stage"].as_str() {
                Some("filtering" | "complete" | "reconciling") => "preparing_queue",
                Some("cleanup" | "checking_index") => "starting",
                _ => "discovering",
            },
            "indexing" => "indexing", "finishing" => "finishing",
            "idle" if !active && scan["event"] == "scan_progress" => "stopped",
            "idle" if state["pending"].as_u64().unwrap_or(0) > 0 => "waiting",
            "idle" => "idle", _ => "starting",
        }};
    let work = if phase == "finishing" { &state["finishing"] } else { &state["indexing"] };
    let total = work["total"].as_u64().filter(|n| *n > 0);
    let done = total.map(|n| work["done"].as_u64().unwrap_or(0).min(n));
    let semantic_verified = semantic["encoder"] == "ready" && semantic["inference_verified"] == true && semantic["execution_policy"] == "accelerator-only"
        && semantic["device"].as_str().is_some_and(|s| !s.is_empty());
    let verified = if semantic_verified { json!({"device":semantic["device"],"executionPolicy":"accelerator-only","source":"application_encoder","at":runtime["applicationUpdatedAt"] ,
        "backend":semantic["backend"],"device_id":semantic["device_id"],"driver_version":semantic["driver_version"],
        "runtime_version":semantic["runtime_version"],"precision_profile":semantic["precision_profile"],"build_identity":semantic["build_identity"]}) }
        else { runtime["verified"].clone() };
    let encoder = if helpers["search"]["running"] == false { "stopped" }
        else { runtime["encoder"]["state"].as_str().or_else(|| semantic["encoder"].as_str()).unwrap_or("unknown") };
    let mut purpose = if semantic.is_object() { semantic.clone() } else { json!({}) };
    purpose["encoder"] = json!(encoder);
    if encoder == "stopped" && purpose["state"] == "ready" { purpose["state"] = json!("preparing"); }
    if catalog["enabled"] == false || catalog["semanticEnabled"] == false { purpose["state"]=json!("disabled"); }
    else if state["model"]["state"] == "failed" { purpose["state"]=json!("unavailable");purpose["message"]=state["model"]["message"].clone(); }
    else if state["model"]["state"] != "ready" { purpose["state"]=json!("preparing"); }
    let inference_error = if state["model"]["state"] == "failed" { &state["model"]["message"] } else { &runtime["encoder"]["message"] };
    json!({
        "schemaVersion":1,"capturedAt":crate::diagnostics::now(),
        "files":{"schemaVersion":1,"phase":phase,"line":state["line"],
            "searchable":state["searchable"],"knownFiles":state["files"],"pending":state["pending"],"unfinished":state["unfinished"],
            "done":done,"total":total,"entriesChecked":scan["visited"],"candidates":scan["candidates"],
            "candidatesFinal":scan["event"] == "sync","root":scan["root"],"path":scan["path"],
            "skipped":scan["skipped"],"skippedFolders":scan["skippedFolders"],
            "missing":state["missing"],"unreadable":state["unreadable"],"error":state["lastError"],
            "lastEventAt":state["lastEventAt"],"lastProgressAt":state["lastProgressAt"],"phaseStartedAt":state["phaseStartedAt"],
            "scheduledAt":state["heldUntil"],"blockedBy":blocked_by,"paused":state["paused"],"canIndexNow":has_folders && state["busy"] == false},
        "applications":{"schemaVersion":1,"catalog":catalog,"purpose":purpose,"lastProgressAt":runtime["applicationUpdatedAt"]},
        "inference":{"schemaVersion":1,"configured":configured,"verified":verified,"encoder":encoder,
            "encoderUpdatedAt":runtime["encoder"]["updatedAt"],"error":inference_error,
            "model":state["model"],"checking":state["measuring"] == true},
        "helpers":{"schemaVersion":1,"index":helpers["index"],"search":helpers["search"]},"events":events,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(state: Value) -> Value {
        snapshot(Input { state, catalog:json!({"supported":true,"enabled":true,"count":663}),
            semantic:json!({"state":"ready","total":663,"embedded":663,"encoder":"ready","device":"AMD Radeon RX 7900 XTX","execution_policy":"accelerator-only","inference_verified":true}),
            configured:json!({"backend":"vulkan"}),helpers:json!({"index":{"pid":42},"search":{"running":false}}),
            runtime:json!({}),events:json!([]),has_folders:true,blocked_by:None })
    }
    #[test]
    fn discovery_is_not_zero_percent_and_does_not_hide_available_apps() {
        let mut status = crate::status::Status::default();
        status.apply(&json!({"event":"scan_progress","visited":443831,"candidates":107857,"stage":"discovering"}));
        let report = fixture(status.snapshot(true,&json!({"state":"ready"})));
        assert_eq!(report["files"]["phase"],"discovering");
        assert_eq!(report["files"]["entriesChecked"],443831);
        assert!(report["files"]["total"].is_null());
        assert_eq!(report["files"]["candidatesFinal"],false);
        assert_eq!(report["applications"]["purpose"]["embedded"],663);
        assert_eq!(report["inference"]["verified"]["device"],"AMD Radeon RX 7900 XTX");
    }
    #[test]
    fn phases_and_rescan_counts_are_independent_of_model_download_readiness() {
        let mut s = crate::status::Status::default();
        s.apply(&json!({"event":"counts","files":20,"searchable":17,"pending":3}));
        s.apply(&json!({"event":"scan_progress","stage":"filtering","visited":100,"candidates":40}));
        let ready=json!({"state":"ready"});
        let report=fixture(s.snapshot(true,&ready));
        assert_eq!(report["files"]["phase"],"preparing_queue");
        assert_eq!(report["files"]["searchable"],17);
        s.apply(&json!({"event":"sync","files":25,"searchable":17,"pending":8,"new":8}));
        let report=fixture(s.snapshot(true,&ready));
        assert_eq!(report["files"]["total"],8);
        s.apply(&json!({"event":"idle","files":25,"searchable":17,"pending":8}));
        assert_eq!(fixture(s.snapshot(true,&ready))["files"]["phase"],"waiting");
        s.paused=true;
        assert_eq!(fixture(s.snapshot(true,&ready))["files"]["phase"],"pausing");
    }
    #[test]
    fn downloaded_weights_do_not_prove_acceleration_and_failures_remain_independent() {
        let input=Input {state:json!({"activity":"failed","lastError":"database is locked","model":{"state":"ready"}}),
            catalog:json!({"supported":true,"enabled":true,"count":663,"sourceErrors":{"commonPrograms":"access denied"}}),
            semantic:json!({"encoder":"unavailable","state":"unavailable","message":"device missing"}),
            configured:json!({"backend":"openvino-npu"}),helpers:json!({"index":{"running":false}}),runtime:json!({}),events:json!([]),
            has_folders:true,blocked_by:None};
        let report=snapshot(input);
        assert_eq!(report["files"]["phase"],"failed");
        assert_eq!(report["files"]["error"],"database is locked");
        assert_eq!(report["applications"]["catalog"]["count"],663);
        assert!(report["inference"]["verified"].is_null());
        assert_eq!(report["inference"]["configured"]["backend"],"openvino-npu");
        let blocked=fixture(json!({"activity":"idle","model":{"state":"failed","message":"accelerator unavailable"}}));
        assert_eq!(blocked["applications"]["catalog"]["count"],663);
        assert_eq!(blocked["applications"]["purpose"]["state"],"unavailable");
        assert_eq!(blocked["applications"]["purpose"]["embedded"],663);
        assert_eq!(blocked["inference"]["error"],"accelerator unavailable");
    }
}
