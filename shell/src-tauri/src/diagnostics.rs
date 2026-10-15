//! Bounded, local indexing evidence. Reports never ask the inference helper or walk the selected folders.
use serde_json::{json, Value};
use std::{collections::VecDeque, fs::{File, OpenOptions}, io::{Read, Seek, SeekFrom, Write}, path::{Path, PathBuf}, sync::Mutex, time::{SystemTime, UNIX_EPOCH}};

pub struct Diagnostics {
    path: PathBuf,
    recent: Mutex<VecDeque<Value>>,
    runtime: Mutex<Value>,
    writer: Mutex<()>,
    significant: Mutex<VecDeque<Value>>,
}

pub fn now() -> f64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64() }

impl Diagnostics {
    pub fn new(directory: &Path) -> Self {
        Self { path: directory.join("indexing.jsonl"), recent: Mutex::default(), runtime: Mutex::new(json!({})), writer: Mutex::new(()), significant: Mutex::default() }
    }

    pub fn record(&self, source: &str, event: Value) {
        let time = now();
        let mut important = !matches!(event["event"].as_str(), Some("scan_progress" | "file" | "rest" | "counts" | "progress"));
        if event["event"] == "file" && event["state"] == "error" { important = true; }
        {
            let mut runtime = self.runtime.lock().unwrap();
            if source == "applications" {
                runtime["applicationUpdatedAt"] = json!(time);
                let state=json!({"state":event["state"],"encoder":event["encoder"],"message":event["message"]});
                important = runtime["applicationState"] != state;
                runtime["applicationState"] = state;
            }
            if source == "search" && event["event"] == "encoder" {
                runtime["encoder"] = json!({"state":event["state"],"updatedAt":time,"message":event["error"]});
            }
            let verified = event["execution_policy"] == "accelerator-only"
                && event["device"].as_str().is_some_and(|device| !device.is_empty())
                && event.get("error").is_none()
                && ((source == "speed" && event["measured"] == true)
                    || (source == "search" && event["event"] == "encoder" && event["state"] == "ready"));
            if verified {
                runtime["verified"] = json!({"device":event["device"],"executionPolicy":"accelerator-only","at":time,"source":source});
            }
        }
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
}
