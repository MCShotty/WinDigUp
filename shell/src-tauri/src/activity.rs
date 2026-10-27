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
    let measured_held = state["heldPending"].as_u64().is_some_and(|value| value > 0)
        || state["heldUnfinished"].as_u64().is_some_and(|value| value > 0);
    let known_counts_complete = state["knownCountsComplete"].as_bool().unwrap_or(true);
    let all_held = known_counts_complete && measured_held && state["runnablePending"].as_u64() == Some(0)
        && state["runnableUnfinished"].as_u64() == Some(0);
    let inventory_count = |key: &str| if !known_counts_complete && state[key].as_u64() == Some(0) {
        Value::Null
    } else { state[key].clone() };
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
            "indexing" => "indexing", "finishing" => "finishing", "waiting" => "waiting",
            "idle" if all_held => "waiting",
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
        "runtime_version":semantic["runtime_version"],"precision_profile":semantic["precision_profile"],"build_identity":semantic["build_identity"],
        "model":semantic["model"],"revision":semantic["revision"],"runtime":semantic["runtime"],"dtype":semantic["dtype"],"dim":semantic["dim"]}) }
        else { runtime["verified"].clone() };
    let encoder = if helpers["search"]["running"] == false { "stopped" }
        else { runtime["encoder"]["state"].as_str().or_else(|| semantic["encoder"].as_str()).unwrap_or("unknown") };
    let mut purpose = if semantic.is_object() { semantic.clone() } else { json!({}) };
    purpose["encoder"] = json!(encoder);
    if encoder == "stopped" && purpose["state"] == "ready" { purpose["state"] = json!("preparing"); }
    if catalog["enabled"] == false || catalog["semanticEnabled"] == false { purpose["state"]=json!("disabled"); }
    else if state["model"]["state"] == "failed" { purpose["state"]=json!("unavailable");purpose["message"]=state["model"]["message"].clone(); }
    else if state["model"]["state"] != "ready" { purpose["state"]=json!("preparing"); }
    if helpers["search"]["error"].is_string() && catalog["enabled"] != false && catalog["semanticEnabled"] != false {
        purpose["state"]=json!("unavailable"); purpose["message"]=helpers["search"]["error"].clone();
    }
    let inference_error = if state["model"]["state"] == "failed" { &state["model"]["message"] }
        else if helpers["search"]["error"].is_string() { &helpers["search"]["error"] }
        else { &runtime["encoder"]["message"] };
    json!({
        "schemaVersion":1,"capturedAt":crate::diagnostics::now(),
        "search":{"schemaVersion":1,"last":runtime["lastSearch"],"index":runtime["searchIndex"]},
        "files":{"schemaVersion":2,"phase":phase,
            "discoveryActive":state["discoveryActive"].as_bool().unwrap_or(scan["discoveryActive"] == true),"line":state["line"],"pipeline":runtime["indexPipeline"],"pipelineHistory":runtime["indexPipelineHistory"],
            "knownCountsComplete":known_counts_complete,
            "searchable":inventory_count("searchable"),"knownFiles":inventory_count("files"),"pending":inventory_count("pending"),"unfinished":inventory_count("unfinished"),
            "heldPending":state["heldPending"],"heldUnfinished":state["heldUnfinished"],
            "runnablePending":state["runnablePending"],"runnableUnfinished":state["runnableUnfinished"],
            "done":done,"total":total,"entriesChecked":scan["visited"],"candidates":scan["candidates"],
            "candidatesFinal":scan["event"] == "sync","root":scan["root"],"path":scan["path"],
            "skipped":scan["skipped"],"skippedFolders":scan["skippedFolders"],
            "missing":state["missing"],"unreadable":state["unreadable"],"error":state["lastError"],
            "lastEventAt":state["lastEventAt"],"lastProgressAt":state["lastProgressAt"],"phaseStartedAt":state["phaseStartedAt"],
            "scheduledAt":state["heldUntil"],"blockedBy":blocked_by,"paused":state["paused"],"canIndexNow":has_folders && state["busy"] == false},
        "applications":{"schemaVersion":1,"catalog":catalog,"purpose":purpose,"lastProgressAt":runtime["applicationUpdatedAt"]},
        "inference":{"schemaVersion":2,"configured":configured,"verified":verified,"encoder":encoder,"jobs":runtime["inferenceJobs"],"capacity":runtime["inferenceCapacity"],
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
    fn streaming_discovery_retains_independent_content_counts() {
        let report = fixture(json!({"activity":"indexing","model":{"state":"ready"},"files":83,"searchable":17,
            "pending":66,"discoveryActive":true,"scan":{"discoveryActive":true,"visited":500,"candidates":83}}));
        assert_eq!(report["files"]["schemaVersion"], 2);
        assert_eq!(report["files"]["discoveryActive"], true);
        assert_eq!(report["files"]["knownFiles"], 83);
        assert_eq!(report["files"]["searchable"], 17);
        assert!(report["files"]["total"].is_null());
    }
    #[test]
    fn unavailable_inference_does_not_erase_name_discovery_state() {
        let report = fixture(json!({"activity":"scanning","model":{"state":"failed","message":"Unavailable"},
            "discoveryActive":true,"files":83,"searchable":17,"scan":{"visited":500,"discoveryActive":true}}));
        assert_eq!(report["files"]["phase"], "unavailable");
        assert_eq!(report["files"]["discoveryActive"], true);
        assert_eq!(report["files"]["knownFiles"], 83);
        assert!(report["files"]["total"].is_null());
    }
    #[test]
    fn explicit_stopped_discovery_overrides_the_last_scan_receipt() {
        let report = fixture(json!({"activity":"idle","model":{"state":"ready"},
            "discoveryActive":false,"files":83,"searchable":17,"scan":{"visited":500,"discoveryActive":true}}));
        assert_eq!(report["files"]["discoveryActive"], false);
    }
    #[test]
    fn held_work_counts_are_explicit_and_legacy_unknowns_stay_unknown() {
        let report = fixture(json!({"activity":"idle","model":{"state":"ready"},"files":83,"searchable":17,"pending":66,"unfinished":3,
            "heldPending":66,"heldUnfinished":3,"runnablePending":0,"runnableUnfinished":0}));
        assert_eq!(report["files"]["heldPending"], 66);
        assert_eq!(report["files"]["heldUnfinished"], 3);
        assert_eq!(report["files"]["runnablePending"], 0);
        assert_eq!(report["files"]["runnableUnfinished"], 0);
        let legacy = fixture(json!({"activity":"idle","model":{"state":"ready"}}));
        assert!(legacy["files"]["heldPending"].is_null());
        assert!(legacy["files"]["runnablePending"].is_null());
    }
    #[test]
    fn held_long_files_wait_even_without_pending_first_pass_files() {
        let report = fixture(json!({"activity":"idle","model":{"state":"ready"},"pending":0,"unfinished":3,
            "heldPending":0,"heldUnfinished":3,"runnablePending":0,"runnableUnfinished":0}));
        assert_eq!(report["files"]["phase"], "waiting");
        assert_eq!(report["files"]["pending"], 0);
        assert_eq!(report["files"]["heldUnfinished"], 3);
        let unknown = fixture(json!({"activity":"idle","model":{"state":"ready"},"pending":0,"unfinished":3,
            "heldPending":null,"heldUnfinished":null,"runnablePending":null,"runnableUnfinished":null}));
        assert_eq!(unknown["files"]["phase"], "idle");
        assert!(unknown["files"]["heldUnfinished"].is_null());
        let waiting = fixture(json!({"activity":"waiting","model":{"state":"ready"}}));
        assert_eq!(waiting["files"]["phase"], "waiting");
    }
    #[test]
    fn incomplete_inventory_zero_is_unknown_and_legacy_zero_remains_observed() {
        let report = fixture(json!({"activity":"idle","model":{"state":"ready"},"knownCountsComplete":false,
            "files":0,"searchable":0,"pending":0,"unfinished":0}));
        for key in ["knownFiles","searchable","pending","unfinished"] { assert!(report["files"][key].is_null()); }
        assert_eq!(report["files"]["knownCountsComplete"], false);
        let legacy = fixture(json!({"activity":"idle","model":{"state":"ready"},"files":0,"searchable":0}));
        assert_eq!(legacy["files"]["knownFiles"], 0);
        assert_eq!(legacy["files"]["knownCountsComplete"], true);
        let incomplete = fixture(json!({"activity":"idle","model":{"state":"ready"},"knownCountsComplete":false,
            "pending":0,"unfinished":3,"heldPending":0,"heldUnfinished":3,"runnablePending":0,"runnableUnfinished":0}));
        assert_eq!(incomplete["files"]["phase"], "idle");
        assert_eq!(incomplete["files"]["heldUnfinished"], 3);
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
