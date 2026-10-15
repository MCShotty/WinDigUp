//! Bounded, local indexing evidence. Reports never ask the inference helper or walk the selected folders.
use serde_json::{json, Value};
use std::{collections::VecDeque, fs::{File, OpenOptions}, io::{Read, Seek, SeekFrom, Write}, path::{Path, PathBuf}, sync::Mutex, time::{SystemTime, UNIX_EPOCH}};

pub struct Diagnostics {
    path: PathBuf,
    recent: Mutex<VecDeque<Value>>,
}

impl Diagnostics {
    pub fn new(directory: &Path) -> Self {
        Self { path: directory.join("indexing.jsonl"), recent: Mutex::default() }
    }

    pub fn record(&self, source: &str, event: Value) {
        let entry = json!({"time": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64(), "source": source, "event": event});
        // Serialize rotation and append with the ring so concurrent helpers cannot interleave JSON lines.
        let mut recent = self.recent.lock().unwrap();
        if recent.len() == 100 { recent.pop_front(); }
        recent.push_back(entry.clone());
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
}
