//! Bounded, local indexing evidence. Reports never ask the inference helper or walk the selected folders.
use serde_json::{json, Value};
use std::{collections::VecDeque, fs::{File, OpenOptions}, io::{Read, Seek, SeekFrom, Write}, path::{Path, PathBuf}, sync::Mutex, time::{SystemTime, UNIX_EPOCH}};

pub struct Diagnostics {
    path: PathBuf,
    recent: Mutex<VecDeque<Value>>,
    runtime: Mutex<Value>,
    writer: Mutex<()>,
    significant: Mutex<VecDeque<Value>>,
    searches: Mutex<VecDeque<Value>>,
}

pub fn now() -> f64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64() }

impl Diagnostics {
    pub fn new(directory: &Path) -> Self {
        Self { path: directory.join("indexing.jsonl"), recent: Mutex::default(), runtime: Mutex::new(json!({})), writer: Mutex::new(()), significant: Mutex::default(), searches: Mutex::default() }
    }

    pub fn record(&self, source: &str, event: Value) {
        let time = now();
        let mut important = !matches!(event["event"].as_str(), Some("scan_progress" | "file" | "rest" | "counts" | "progress" | "inference_activity" | "panel_timing" | "index_pipeline"));
        if event["event"] == "file" && matches!(event["state"].as_str(), Some("failed" | "error")) { important = true; }
        {
            let mut runtime = self.runtime.lock().unwrap();
            if source == "index" && event["event"] == "index_pipeline" && event["pipeline"]["schemaVersion"] == 1 {
                if !runtime["indexPipeline"].is_object() { runtime["indexPipeline"] = json!({}); }
                let key = if event["code"] == true { "code" } else { "files" };
                runtime["indexPipeline"][key] = event["pipeline"].clone();
                runtime["indexPipeline"][key]["capturedAt"] = json!(time);
            }
            if event["event"]=="inference_activity" && event["activity"]["schemaVersion"]==1 {
                let value=&event["activity"];
                if let Some(worker)=value["workerID"].as_i64() {
                    let key=format!("{worker}");
                    if !runtime["inferenceJobs"].is_object(){runtime["inferenceJobs"]=json!({});}
                    let mut row=value.clone();row["source"]=json!(source);row["updatedAt"]=json!(time);
                    if runtime["inferenceJobs"].as_object().unwrap().len()>=12 && runtime["inferenceJobs"].get(&key).is_none(){
                        let oldest=runtime["inferenceJobs"].as_object().unwrap().iter()
                            .min_by(|a,b|a.1["updatedAt"].as_f64().unwrap_or(0.0).total_cmp(&b.1["updatedAt"].as_f64().unwrap_or(0.0))).map(|(id,_)|id.clone());
                        if let Some(oldest)=oldest{runtime["inferenceJobs"].as_object_mut().unwrap().remove(&oldest);}
                    }
                    runtime["inferenceJobs"][&key]=row;
                    if value["phase"]=="limited"{runtime["inferenceCapacity"]=value.clone();runtime["inferenceCapacity"]["source"]=json!(source);}
                }
            }
            if event["fatal"]==true || matches!(event["event"].as_str(),Some("exit"|"stopped"|"ended")) ||
                event["event"]=="encoder" && matches!(event["state"].as_str(),Some("stopped"|"unavailable")){
                if runtime["inferenceCapacity"]["source"]==source{runtime["inferenceCapacity"]=Value::Null;}
                if let Some(jobs)=runtime["inferenceJobs"].as_object_mut(){
                    for value in jobs.values_mut().filter(|v|v["source"]==source){value["phase"]=json!("stopped");value["activeJobs"]=Value::Null;}
                }
            }
            if source == "applications" {
                runtime["applicationUpdatedAt"] = json!(time);
                let state=json!({"state":event["state"],"encoder":event["encoder"],"message":event["message"]});
                important = runtime["applicationState"] != state;
                runtime["applicationState"] = state;
            }
            if source == "search" && event["event"] == "encoder" {
                let message = if matches!(event["state"].as_str(),Some("ready" | "starting")) && event["inference_verified"] != true {
                    runtime["encoder"]["message"].clone()
                } else { event["error"].clone() };
                runtime["encoder"] = json!({"state":event["state"],"updatedAt":time,"message":message});
            }
            if source == "search" && event["event"] == "search_index" {
                important=event["state"]=="unavailable";
                runtime["searchIndex"]=event.clone();
            }
            let verified = event["execution_policy"] == "accelerator-only"
                && event["device"].as_str().is_some_and(|device| !device.is_empty())
                && event.get("error").is_none()
                && ((source == "speed" && event["measured"] == true)
                    || (source == "search" && event["event"] == "encoder" && event["state"] == "ready" && event["inference_verified"] == true));
            if verified {
                runtime["verified"] = json!({"device":event["device"],"executionPolicy":"accelerator-only","at":time,"source":source});
                for key in ["backend", "device_id", "driver_version", "runtime_version", "precision_profile", "build_identity", "model", "revision", "runtime", "dtype", "dim"] {
                    if let Some(value) = event.get(key) { runtime["verified"][key] = value.clone(); }
                }
            }
        }
        if event["event"]=="inference_activity" && event["activity"]["phase"]!="limited"{return}
        let entry = json!({"time": time, "source": source, "event": event});
        if important {
            let mut significant=self.significant.lock().unwrap();
            if significant.len()==30 { significant.pop_front(); }
            significant.push_back(entry.clone());
        }
        // Disk serialization is independent of snapshot reads: no UI snapshot waits on log I/O.
        let _writer = self.writer.lock().unwrap();
        let mut recent = self.recent.lock().unwrap();
        if recent.len() == 100 { recent.pop_front(); }
        recent.push_back(entry.clone());
        drop(recent);
        if std::fs::metadata(&self.path).is_ok_and(|file| file.len() > 1_048_576) {
            let previous = self.path.with_extension("previous.jsonl");
            let _ = std::fs::remove_file(&previous);
            // If a reader prevents rotation on Windows, keep the bounded in-memory report and retry next time.
            if std::fs::rename(&self.path, previous).is_err() { return }
        }
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&self.path) {
            let _ = writeln!(file, "{entry}");
        }
    }

    pub fn recent(&self) -> Value { json!(self.recent.lock().unwrap().clone()) }

    /// In-memory evidence survives ring-buffer eviction; no logs or helper requests.
    pub fn runtime(&self) -> Value { self.runtime.lock().unwrap().clone() }

    /// Strictly bounded numeric evidence. Never retain a query, path, hit, or frontend-provided metadata.
    pub fn record_search(&self, view: &str, sample: &Value) -> Result<(), String> {
        let phase = sample["phase"].as_str().unwrap_or_default();
        if !["app_names","app_purpose","settings_names","settings_purpose","file_words","file_meaning"].contains(&phase) {
            return Err("Unknown search timing phase".into());
        }
        if sample["total"].as_f64().is_none_or(|value| !value.is_finite() || value < 0.0 || value > 86_400_000.0) {
            return Err("Missing or invalid total search duration".into());
        }
        let mut clean = json!({"schemaVersion":1,"capturedAt":now(),"view":view,"phase":phase,
            "timingOrigin":"ui_input",
            "generation":sample["generation"].as_u64().unwrap_or(0),"requestId":sample["requestId"].as_u64().unwrap_or(0)});
        if let Some(id)=sample["nativeRequestId"].as_u64() { clean["nativeRequestId"]=json!(id); }
        for key in ["total", "roundtrip", "debounce", "render", "native", "queue", "helper_total", "helper_startup", "model_load", "encode", "search", "scoring", "keywords", "metadata", "vector_load", "retrieval_queue", "transport"] {
            if let Some(value) = sample[key].as_f64().filter(|v| v.is_finite() && *v >= 0.0 && *v <= 86_400_000.0) { clean[key] = json!(value); }
        }
        clean["cacheHit"] = json!(sample["cacheHit"] == true);
        clean["semantic"] = json!(sample["semantic"] == true);
        let mut history = self.searches.lock().unwrap();
        if history.len() == 200 { history.pop_front(); }
        history.push_back(clean.clone());
        self.runtime.lock().unwrap()["lastSearch"] = clean;
        Ok(())
    }
    pub fn search_timings(&self) -> Value { json!(self.searches.lock().unwrap().iter().cloned().collect::<Vec<_>>()) }

    pub fn significant(&self) -> Value {
        json!(self.significant.lock().unwrap().iter().rev().cloned().collect::<Vec<_>>())
    }
}

pub fn tail(path: &Path, maximum: usize) -> String {
    let Ok(mut file) = File::open(path) else { return "(log absent)".into() };
    let Ok(size) = file.metadata().map(|m| m.len()) else { return "(cannot read log)".into() };
    let offset = size.saturating_sub(maximum as u64);
    if file.seek(SeekFrom::Start(offset)).is_err() { return "(cannot read log)".into() }
    let mut bytes = Vec::new();
    let _ = file.take(maximum as u64).read_to_end(&mut bytes);
    let text = String::from_utf8_lossy(&bytes);
    // A tail can start in a UTF-8 character or in the middle of a JSON event.
    if offset > 0 { text.split_once('\n').map(|(_, rest)| rest).unwrap_or(&text).to_string() }
    else { text.into_owned() }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn search_timing_history_is_bounded_numeric_and_in_memory() {
        let dir=std::env::temp_dir().join("digup-search-timings-absent");
        let d=Diagnostics::new(&dir);
        for n in 0..250 {
            d.record_search("window",&json!({"phase":"file_words","generation":n,"total":12.5,
                "encode":-1,"metadata":3,"native":2,"nativeRequestId":n+1,"q":"private query","path":"C:/private.txt"})).unwrap();
        }
        let samples=d.search_timings();assert_eq!(samples.as_array().unwrap().len(),200);
        assert!(samples[0].get("q").is_none());assert!(samples[0].get("path").is_none());assert!(samples[0].get("encode").is_none());
        assert_eq!(d.runtime()["lastSearch"]["total"],12.5);
        assert_eq!(d.runtime()["lastSearch"]["nativeRequestId"],250);
        assert_eq!(d.runtime()["lastSearch"]["native"],2.0);
        assert!(d.record_search("window",&json!({"phase":"unknown"})).is_err());
        assert!(!dir.join("indexing.jsonl").exists());
    }
    #[test]
    fn bounds_reports_and_keeps_worker_errors() {
        let dir = std::env::temp_dir().join(format!("digup-diagnostics-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let diagnostics = Diagnostics::new(&dir);
        for n in 0..150 { diagnostics.record("index", json!({"event":"scan_progress", "visited":n})); }
        diagnostics.record("index", json!({"event":"error","message":"database is locked"}));
        let recent = diagnostics.recent();
        assert_eq!(recent.as_array().unwrap().len(), 100);
        assert_eq!(recent[99]["event"]["message"], "database is locked");
        let report = tail(&dir.join("indexing.jsonl"), 400);
        assert!(report.len() <= 400);
        assert!(report.contains("database is locked"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn verified_device_requires_an_accelerator_receipt_and_survives_progress_eviction() {
        let dir=std::env::temp_dir().join(format!("digup-evidence-{}",std::process::id()));
        let diagnostics=Diagnostics::new(&dir);
        diagnostics.record("speed",json!({"device":"CPU","measured":true}));
        assert!(diagnostics.runtime()["verified"].is_null());
        diagnostics.record("search",json!({"event":"encoder","state":"ready","device":"RTX 2060","execution_policy":"accelerator-only","inference_verified":false}));
        assert!(diagnostics.runtime()["verified"].is_null(), "loading an encoder is not inference");
        diagnostics.record("search",json!({"event":"encoder","state":"ready","device":"RTX 2060","execution_policy":"accelerator-only","inference_verified":true}));
        assert_eq!(diagnostics.runtime()["verified"]["device"], "RTX 2060");
        diagnostics.record("speed",json!({"device":"RX 7900 XTX","measured":true,"execution_policy":"accelerator-only"}));
        for n in 0..110 { diagnostics.record("index",json!({"event":"scan_progress","visited":n})); }
        assert_eq!(diagnostics.runtime()["verified"]["device"],"RX 7900 XTX");
        assert!(diagnostics.significant().as_array().unwrap().iter().any(|entry|entry["source"]=="speed"));
        diagnostics.record("search",json!({"event":"encoder","state":"stopped"}));
        assert_eq!(diagnostics.runtime()["encoder"]["state"],"stopped");
        assert_eq!(diagnostics.runtime()["verified"]["device"],"RX 7900 XTX");
    }

    #[test]
    fn significant_timeline_keeps_errors_through_scan_and_embedding_progress() {
        let d=Diagnostics::new(&std::env::temp_dir().join("digup-timeline-absent"));
        d.record("index",json!({"event":"error","message":"disk full"}));
        for n in 0..200 {
            d.record("index",json!({"event":"scan_progress","visited":n}));
            d.record("applications",json!({"state":"preparing","encoder":"ready","embedded":n}));
        }
        assert!(d.significant().as_array().unwrap().iter().any(|entry|entry["event"]["message"]=="disk full"));
        assert_eq!(d.significant().as_array().unwrap().len(),2);
        for n in 0..40 {d.record("index",json!({"event":"error","message":format!("error {n}")}));}
        assert_eq!(d.significant().as_array().unwrap().len(),30);
    }

    #[test]
    fn retry_does_not_hide_a_cuda_failure_before_successful_inference() {
        let d=Diagnostics::new(&std::env::temp_dir().join("digup-retry-failure-absent"));
        d.record("search",json!({"event":"encoder","state":"unavailable","error":"insufficient_vram"}));
        d.record("search",json!({"event":"encoder","state":"ready","inference_verified":false}));
        assert_eq!(d.runtime()["encoder"]["message"],"insufficient_vram");
        d.record("search",json!({"event":"encoder","state":"ready","inference_verified":true}));
        assert!(d.runtime()["encoder"]["message"].is_null());
    }

    #[test]
    fn failed_files_are_retained_in_the_significant_timeline() {
        let d=Diagnostics::new(&std::env::temp_dir().join("digup-file-failure-absent"));
        d.record("index",json!({"event":"file","state":"failed","path":"broken.pdf","note":"cannot decode PDF"}));
        for n in 0..120 {d.record("index",json!({"event":"file","state":"done","path":format!("ok-{n}.txt")}));}
        assert_eq!(d.significant()[0]["event"]["note"],"cannot decode PDF");
    }
}

#[cfg(test)]
mod panel_timing_tests {
    use super::*;
    #[test]
    fn opening_metrics_do_not_displace_errors_from_activity() {
        let root = std::env::temp_dir().join(format!("digup-panel-metrics-{}-{}",
            std::process::id(), now().to_bits()));
        std::fs::create_dir_all(&root).unwrap();
        let diagnostics = Diagnostics::new(&root);
        diagnostics.record("index", json!({"event":"error","message":"Fixture indexing failure"}));
        for request in 0..200 {
            diagnostics.record("panel", json!({"event":"panel_timing","requestId":request,"showToFocusMs":12.5}));
        }
        let significant = diagnostics.significant();
        assert_eq!(significant.as_array().unwrap().len(), 1);
        assert_eq!(significant[0]["event"]["message"], "Fixture indexing failure");
        assert_eq!(diagnostics.recent().as_array().unwrap().len(), 100);
        assert_eq!(diagnostics.recent()[99]["event"]["showToFocusMs"], 12.5);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod index_pipeline_tests {
    use super::*;

    #[test]
    fn pipeline_timings_are_separate_for_file_and_code_work_and_do_not_evict_errors() {
        let d = Diagnostics::new(&std::env::temp_dir().join("digup-pipeline-diagnostics-absent"));
        d.record("index", json!({"event":"error","message":"Fixture model failure"}));
        for n in 0..150 {
            d.record("index", json!({"event":"index_pipeline","pipeline":{
                "schemaVersion":1,"preparedJobs":n,"preparationMs":23.5,"inferenceMs":200,"commitMs":12
            }}));
        }
        d.record("index", json!({"event":"index_pipeline","code":true,
            "pipeline":{"schemaVersion":1,"preparedJobs":4,"inferenceMs":8}}));
        d.record("index", json!({"event":"index_pipeline","pipeline":{"schemaVersion":99,"preparedJobs":999}}));
        assert_eq!(d.runtime()["indexPipeline"]["files"]["preparedJobs"], 149);
        assert_eq!(d.runtime()["indexPipeline"]["files"]["preparationMs"], 23.5);
        assert_eq!(d.runtime()["indexPipeline"]["code"]["preparedJobs"], 4);
        assert!(d.runtime()["indexPipeline"]["files"]["capturedAt"].is_number());
        assert!(d.runtime()["verified"].is_null());
        assert_eq!(d.significant().as_array().unwrap().len(), 1);
        assert_eq!(d.significant()[0]["event"]["message"], "Fixture model failure");
    }
}
