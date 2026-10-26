//! What DigUp is doing, in the words the tray, the window and the panel use: the index helper's events and the model's
//! download turned into one line, a progress and a caveat for results (the Mac app's AppModel and EngineStatus).

use serde_json::{json, Value};

#[derive(Clone, Debug, Default, PartialEq)]
pub enum Activity {
    /// The index helper hasn't reported yet.
    #[default]
    Starting,
    Scanning,
    Idle,
    /// A pass over new or changed files: `done` of `total`.
    Indexing { done: u64, total: u64 },
    /// The rest of long PDFs and documents: `done` of the `total` pages and chunks this pass reads, `files` unfinished.
    Finishing { done: u64, total: u64, files: u64 },
    Failed(String),
}

#[derive(Clone, Debug, Default)]
pub struct Status {
    pub activity: Activity,
    pub discovery_active: bool,
    /// Files in the index, in any state.
    pub files: u64,
    /// Done or partly read: what search finds by what's in it.
    pub searchable: u64,
    /// Waiting to be read.
    pub pending: u64,
    /// Long files with pages or chunks still to read.
    pub unfinished: u64,
    /// Chosen folders that aren't there now (an unplugged drive), and ones DigUp can't read: skipped, files kept.
    pub missing: Vec<String>,
    pub unreadable: Vec<String>,
    /// Failed subtrees from the last completed crawl, kept while another crawl is in progress.
    pub scan_unreadable: Vec<String>,
    /// The speed check before the first index is running.
    pub measuring: bool,
    /// Indexing is paused (Pause Indexing): nothing is read until it's resumed; search goes on.
    pub paused: bool,
    /// Outside the set hours (Settings → Folders): when they begin ("01:00").
    pub held_until: Option<String>,
    /// Last reported stage/counts and errors survive an idle/exit event, rather than looking like an empty index.
    pub scan: Value,
    pub last_error: Option<String>,
    pub last_event_at: Option<f64>,
    pub last_progress_at: Option<f64>,
    pub phase_started_at: Option<f64>,
}

impl Status {
    /// A newly selected backend owns a different store. Scheduling choices survive, counts do not.
    pub fn reset_for_index(&mut self) {
        *self = Self { paused: self.paused, held_until: self.held_until.clone(), ..Self::default() };
    }

    /// A helper started before device discovery may reply after the effective store has changed.
    pub fn cached_counts(&mut self, reply: &Value, expected_file: &std::path::Path) -> bool {
        // The helper standardizes --index to an absolute path. Match that lexical form without touching the disk.
        let normalize = |path: &std::path::Path| -> Option<std::path::PathBuf> {
            let mut result = std::path::PathBuf::new();
            for component in std::path::absolute(path).ok()?.components() {
                match component {
                    std::path::Component::ParentDir => { result.pop(); }
                    std::path::Component::CurDir => {}
                    _ => result.push(component),
                }
            }
            Some(result)
        };
        let expected = normalize(expected_file);
        let actual = reply["index"].as_str().and_then(|file| normalize(std::path::Path::new(file)));
        if expected.is_none() || actual != expected
            || self.files != 0 || !reply["files"].is_u64() { return false; }
        self.apply(&json!({"event":"counts", "files":reply["files"], "searchable":reply["searchable"],
            "pending":reply["pending"], "unfinished":reply["unfinished"]}));
        if self.activity == Activity::Starting && (self.paused || self.held_until.is_some()) {
            self.activity = Activity::Idle;
        }
        true
    }

    /// An index-service event (`Sources/digup/IndexService.swift`); events about the code index don't count here.
    pub fn apply(&mut self, event: &Value) {
        self.apply_at(event, crate::diagnostics::now());
    }

    fn apply_at(&mut self, event: &Value, time: f64) {
        if event["code"] == true {
            return;
        }
        let previous = (self.activity.clone(), self.searchable, self.pending, self.scan.clone());
        self.last_event_at = Some(time);
        let count = |key: &str| event[key].as_u64().unwrap_or(0);
        // Only complete count snapshots describe the index. Rest/rescan/pruned events count a subset.
        if event["files"].is_u64() && matches!(event["event"].as_str(), Some("counts" | "sync" | "scan_batch" | "idle" | "waiting")) {
            self.files = count("files");
            self.searchable = count("searchable");
            self.pending = count("pending");
            self.unfinished = count("unfinished");
        }
        if let active = event["discoveryActive"].as_bool() { self.discovery_active=active; }
        match event["event"].as_str().unwrap_or_default() {
            "started" => { self.discovery_active=false; self.scan = Value::Null; self.activity = Activity::Starting; }
            "phase" | "scanning" | "scan_progress" => {
                self.activity = Activity::Scanning;
                self.scan = event.clone();
            }
            "scan_batch" => { self.activity=Activity::Scanning; }
            "scan_cancelled" => { self.discovery_active=false; self.activity=Activity::Idle; }
            "sync" => {
                self.scan_unreadable = event["unreadable"].as_array().into_iter().flatten()
                    .filter_map(Value::as_str).map(String::from).collect();
                self.last_error = None; self.scan = event.clone(); self.activity = if count("new") > 0 || self.pending > 0 {
                Activity::Indexing { done: 0, total: count("new").max(self.pending) }
            } else { Activity::Idle }; },
            "file" => {
                self.activity = Activity::Indexing { done: count("done"), total: count("total") };
                // The counts come with a sync; each file read since leaves "waiting".
                self.pending = self.pending.saturating_sub(1);
                if matches!(event["state"].as_str(), Some("done" | "partial")) {
                    self.searchable += 1;
                }
            }
            "rest" => {
                self.activity = Activity::Finishing { done: count("done"), total: count("total"), files: count("files") }
            }
            "idle" | "waiting" => self.activity = Activity::Idle,
            "missing" => {
                let paths = |key: &str| -> Vec<String> {
                    event[key].as_array().into_iter().flatten().filter_map(Value::as_str).map(String::from).collect()
                };
                self.missing = paths("folders");
                self.unreadable = paths("unreadable");
            }
            "error" => {
                let message = event["message"].as_str().unwrap_or("Indexing stopped").chars().take(1500).collect::<String>();
                self.last_error = Some(message.clone());
                self.activity = Activity::Failed(message);
            }
            // The helper is gone: whatever it was doing is over.
            "exit" | "ended" => {
                self.discovery_active=false;
                if event["event"] == "ended" && event["status"].as_i64() != Some(0) {
                    let message = self.last_error.clone().unwrap_or_else(|| format!("Indexing helper exited (status {}). Open indexing diagnostics for details.", event["status"]));
                    self.last_error = Some(message.clone());
                    self.activity = Activity::Failed(message);
                }
                if matches!(self.activity, Activity::Starting | Activity::Scanning | Activity::Indexing { .. } | Activity::Finishing { .. }) {
                    self.activity = Activity::Idle;
                }
            }
            _ => {}
        }
        // Identical heartbeats are contact, not progress. A new path/stage or a changed
        // counter is evidence of work; no wall-clock stall diagnosis is inferred here.
        if !matches!(event["event"].as_str(), Some("error" | "ended" | "exit" | "started"))
            && previous != (self.activity.clone(), self.searchable, self.pending, self.scan.clone()) {
            self.last_progress_at = Some(time);
        }
        if event["event"] == "started" || std::mem::discriminant(&previous.0) != std::mem::discriminant(&self.activity)
            || previous.3["stage"] != self.scan["stage"] {
            self.phase_started_at = Some(time);
        }
    }

    /// One line for the tray and the window: "Indexing 42% · 120 of 306", "306 files indexed".
    pub fn line(&self, has_folders: bool, model: &Value) -> String {
        if !has_folders {
            return "No folders chosen yet".into();
        }
        if let Activity::Failed(problem) = &self.activity {
            return format!("⚠︎ {problem}");
        }
        if let Some(problem) = &self.last_error { return format!("⚠︎ {problem}"); }
        // Nothing is read before the model is in (file names are searchable once indexing starts).
        if let Some(line) = download_line(model) {
            return line;
        }
        if self.measuring {
            return "Checking this computer's speed…".into();
        }
        if self.discovery_active {
            return match self.scan["visited"].as_u64() {
                Some(visited) => format!("Discovering files · {} entries checked · {} content ready",number(visited),number(self.searchable)),
                None => format!("Discovering files · {} content ready",number(self.searchable)),
            };
        }
        match self.activity {
            // Held or paused, no index helper runs to say it has started: what's indexed stands.
            Activity::Starting if !self.paused && self.held_until.is_none() => "Starting…".into(),
            Activity::Scanning => {
                match self.scan["visited"].as_u64() {
                    Some(visited) => format!("Scanning folders · {} entries checked · {} candidates", number(visited), number(self.scan["candidates"].as_u64().unwrap_or(0))),
                    None => self.scan["message"].as_str().unwrap_or("Scanning folders…").to_string(),
                }
            },
            Activity::Indexing { total: 0, .. } => format!("Indexing files · {} content ready",number(self.searchable)),
            Activity::Indexing { done, total } => format!("Indexing {}% · {} of {}", percent(done, total), number(done), number(total)),
            Activity::Finishing { done, total, files } => {
                let which = if files > 0 { format!("{} long {}", number(files), plural(files, "file", "files")) } else { "long files".into() };
                format!("Reading the rest of {which} · {}%", percent(done, total))
            }
            _ if self.pending > 0 => {
                let waiting = format!("{} {} waiting", number(self.pending), plural(self.pending, "file", "files"));
                match &self.held_until {
                    _ if self.paused => format!("Paused · {waiting}"),
                    Some(start) => format!("{waiting} · indexing from {start}"),
                    None => format!("{waiting} to be indexed"),
                }
            }
            _ => {
                if self.files == 0 && self.scan["event"] == "sync" && !self.paused {
                    return if !self.missing.is_empty() || !self.unreadable.is_empty() || !self.scan_unreadable.is_empty() {
                        "No files found · some selected folders are unavailable".into()
                    } else { "No supported local files found in the selected folders".into() };
                }
                let indexed = format!("{} {} indexed", number(self.searchable), plural(self.searchable, "file", "files"));
                match &self.held_until {
                    _ if self.paused => format!("{indexed} · paused"),
                    Some(start) => format!("{indexed} · indexing from {start}"),
                    None => indexed,
                }
            }
        }
    }

    /// A few words beside the panel's field while results may be incomplete: "Indexing 42%", "Downloading model · 42%".
    pub fn badge(&self, model: &Value) -> Option<String> {
        if model["state"] == "downloading" {
            return Some(format!("Downloading model · {}%", (fraction(model) * 100.0) as u64));
        }
        if self.paused && self.pending > 0 {
            return Some("Indexing paused".into());
        }
        match self.activity {
            Activity::Indexing { done, total } if total > 0 => Some(format!("Indexing {}%", percent(done, total))),
            _ => None,
        }
    }

    /// Something is under way or can't start: Index Now has nothing to add.
    pub fn busy(&self, model: &Value) -> bool {
        model["state"] != "ready" || self.measuring || self.paused || self.held_until.is_some()
            || matches!(self.activity, Activity::Scanning | Activity::Indexing { .. } | Activity::Finishing { .. })
    }

    /// 0…1 while something is under way (the download, then an indexing pass or the rest of long files).
    pub fn progress(&self, model: &Value) -> Option<f64> {
        if model["state"] == "downloading" {
            return Some(fraction(model));
        }
        if self.discovery_active { return None; }
        match self.activity {
            Activity::Indexing { done, total } | Activity::Finishing { done, total, .. } if total > 0 => {
                Some(done as f64 / total as f64)
            }
            _ => None,
        }
    }

    /// Why results may be incomplete right now: the model isn't in yet, or files aren't read yet.
    pub fn caveat(&self, model: &Value) -> Option<String> {
        match model["state"].as_str() {
            Some("downloading") => {
                return Some(format!("Matching words only until the model has downloaded ({}%)", (fraction(model) * 100.0) as u64))
            }
            Some("waiting") => return Some("Matching words only: the model isn't downloaded".into()),
            Some("failed") => return Some("Matching words only: model inference is unavailable".into()),
            _ => {}
        }
        if let Activity::Indexing { done, total } = self.activity {
            if total > 0 {
                return Some(format!("Still indexing ({}%): some files aren't in yet", percent(done, total)));
            }
        }
        (self.pending > 0).then(|| {
            format!("{} {} indexed yet", number(self.pending), plural(self.pending, "file isn't", "files aren't"))
        })
    }

    /// What the pages show: the line, the progress, the caveat, and the counts.
    pub fn snapshot(&self, has_folders: bool, model: &Value) -> Value {
        let unreadable: std::collections::BTreeSet<_> = self.unreadable.iter().chain(&self.scan_unreadable).collect();
        let indexing = match self.activity {
            Activity::Indexing { done, total } => json!({"done": done, "total": if total>0 {Some(total)} else {None}}),
            _ => Value::Null,
        };
        json!({
            "line": self.line(has_folders, model),
            "progress": self.progress(model),
            "caveat": self.caveat(model),
            "indexing": indexing,
            "files": self.files,
            "discoveryActive": self.discovery_active,
            "searchable": self.searchable,
            "pending": self.pending,
            "unfinished": self.unfinished,
            "measuring": self.measuring,
            "paused": self.paused,
            "heldUntil": self.held_until,
            "badge": self.badge(model),
            "busy": self.busy(model),
            "activity": match self.activity {
                Activity::Starting => "starting",
                Activity::Scanning => "scanning",
                Activity::Idle => "idle",
                Activity::Indexing { .. } => "indexing",
                Activity::Finishing { .. } => "finishing",
                Activity::Failed(_) => "failed",
            },
            "model": model,
            "scan": self.scan,
            "lastError": self.last_error,
            "lastEventAt": self.last_event_at,
            "lastProgressAt": self.last_progress_at,
            "phaseStartedAt": self.phase_started_at,
            "missing": self.missing,
            "unreadable": unreadable,
            "finishing": match self.activity { Activity::Finishing { done, total, files } => json!({"done":done,"total":total,"files":files}), _ => Value::Null },
        })
    }
}

/// While the model isn't there, how its download goes.
fn download_line(model: &Value) -> Option<String> {
    match model["state"].as_str()? {
        "downloading" => Some(format!("Downloading the model · {}%", (fraction(model) * 100.0) as u64)),
        "checking" => Some("Checking the model download…".into()),
        "waiting" => Some("Model download: waiting for the network".into()),
        "failed" => Some(format!("⚠︎ {}", model["message"].as_str().filter(|s| !s.is_empty())
            .unwrap_or("Model inference is unavailable"))),
        _ => None,
    }
}

fn fraction(model: &Value) -> f64 {
    let (bytes, total) = (model["bytes"].as_f64().unwrap_or(0.0), model["total"].as_f64().unwrap_or(0.0));
    if total > 0.0 { (bytes / total).clamp(0.0, 1.0) } else { 0.0 }
}

/// Rounded down, so 100% means done.
fn percent(done: u64, total: u64) -> u64 {
    if total == 0 { 0 } else { done * 100 / total }
}

fn plural(count: u64, one: &'static str, many: &'static str) -> &'static str {
    if count == 1 { one } else { many }
}

/// "1,204"
pub fn number(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines() {
        let ready = json!({"state": "ready"});
        let mut status = Status::default();
        assert_eq!(status.line(false, &ready), "No folders chosen yet");
        assert_eq!(status.line(true, &ready), "Starting…");
        status.apply(&json!({"event":"scanning"}));
        assert_eq!(status.line(true, &ready), "Scanning folders…");
        assert_eq!(status.snapshot(true, &ready)["activity"], "scanning");
        assert!(status.busy(&ready));
        assert_eq!(status.line(true, &json!({"state": "downloading", "bytes": 432.0, "total": 865.0})),
                   "Downloading the model · 49%");
        status.apply(&json!({"event": "sync", "new": 306, "files": 306, "searchable": 0, "pending": 306}));
        assert_eq!(status.line(true, &ready), "Indexing 0% · 0 of 306");
        status.apply(&json!({"event": "file", "done": 129, "total": 306}));
        assert_eq!(status.line(true, &ready), "Indexing 42% · 129 of 306");
        assert_eq!(status.progress(&ready), Some(129.0 / 306.0));
        assert_eq!(status.caveat(&ready).as_deref(), Some("Still indexing (42%): some files aren't in yet"));
        status.apply(&json!({"event": "file", "done": 1, "total": 1, "code": true}));
        assert_eq!(status.line(true, &ready), "Indexing 42% · 129 of 306");
        status.apply(&json!({"event": "rest", "done": 40, "total": 100, "files": 3}));
        assert_eq!(status.line(true, &ready), "Reading the rest of 3 long files · 40%");
        status.apply(&json!({"event": "idle", "files": 1306, "searchable": 1306, "pending": 0, "unfinished": 0}));
        assert_eq!(status.line(true, &ready), "1,306 files indexed");
        assert_eq!(status.progress(&ready), None);
        assert_eq!(status.caveat(&ready), None);
        status.apply(&json!({"event": "error", "message": "worker died", "fatal": true}));
        assert_eq!(status.line(true, &ready), "⚠︎ worker died");

        let mut held = Status { held_until: Some("01:00".into()), ..Status::default() };
        held.apply(&json!({"event": "counts", "files": 70, "searchable": 66, "pending": 4, "unfinished": 0}));
        assert_eq!(held.line(true, &ready), "4 files waiting · indexing from 01:00");
        assert!(held.busy(&ready));
        held.held_until = None;
        held.paused = true;
        assert_eq!(held.line(true, &ready), "Paused · 4 files waiting");
    }

    #[test]
    fn streaming_discovery_has_no_fake_completion_percentage() {
        let ready=json!({"state":"ready"});
        let mut status=Status::default();
        status.apply(&json!({"event":"scan_progress","discoveryActive":true,"visited":500,"candidates":80}));
        status.apply(&json!({"event":"scan_batch","discoveryActive":true,"files":80,"searchable":5,"pending":75}));
        assert_eq!(status.snapshot(true,&ready)["discoveryActive"],true);
        assert_eq!(status.files,80);
        assert!(status.progress(&ready).is_none());
        assert!(status.line(true,&ready).contains("5 content ready"));
        status.apply(&json!({"event":"scan_cancelled","discoveryActive":false}));
        assert!(!status.discovery_active);
        assert_eq!(status.files,80);
    }

    #[test]
    fn numbers() {
        assert_eq!(number(0), "0");
        assert_eq!(number(999), "999");
        assert_eq!(number(1000), "1,000");
        assert_eq!(number(1234567), "1,234,567");
    }

    #[test]
    fn errors_are_not_disguised_as_an_empty_index() {
        let ready = json!({"state":"ready"});
        let mut status = Status::default();
        status.apply(&json!({"event":"error","message":"sync failed: database is locked"}));
        status.apply(&json!({"event":"idle","files":0,"searchable":0}));
        status.apply(&json!({"event":"ended","status":0}));
        assert!(status.line(true, &ready).contains("database is locked"));
        status.apply(&json!({"event":"started","pid":123}));
        assert!(status.last_error.is_some(), "a restart is not proof the failed operation recovered");
        status.apply(&json!({"event":"scan_progress","visited":2020,"candidates":17,"path":"C:/Documents"}));
        assert_eq!(status.snapshot(true, &ready)["scan"]["visited"], 2020);
        status.apply(&json!({"event":"sync","files":17,"new":17}));
        assert!(status.last_error.is_none());
        status.apply(&json!({"event":"ended","status":-1073741819_i64}));
        assert!(status.line(true, &ready).contains("-1073741819"));
        status.apply(&json!({"event":"started"}));
        status.apply(&json!({"event":"sync","files":0,"candidates":0,"visited":500,"skipped":{"other type":500}}));
        assert_eq!(status.line(true, &ready), "No supported local files found in the selected folders");
        assert_eq!(status.snapshot(true, &ready)["scan"]["skipped"]["other type"], 500);
    }

    #[test]
    fn timestamps_separate_contact_from_progress_and_ignore_code_events() {
        let mut status=Status::default();
        let event=json!({"event":"scan_progress","visited":8,"candidates":3,"stage":"discovering"});
        status.apply_at(&event,10.0);
        status.apply_at(&event,20.0);
        assert_eq!(status.last_event_at,Some(20.0));
        assert_eq!(status.last_progress_at,Some(10.0));
        status.apply_at(&json!({"event":"scan_progress","visited":9,"candidates":3,"stage":"discovering"}),30.0);
        assert_eq!(status.last_progress_at,Some(30.0));
        status.apply_at(&json!({"event":"file","code":true}),40.0);
        assert_eq!(status.last_event_at,Some(30.0));
        status.apply_at(&json!({"event":"error","message":"worker failed"}),50.0);
        assert_eq!(status.last_progress_at,Some(30.0));
    }

    #[test]
    fn finishing_long_files_does_not_erase_catalog_counts() {
        let mut status=Status::default();
        status.apply(&json!({"event":"counts","files":120,"searchable":100,"pending":20,"unfinished":3}));
        status.apply(&json!({"event":"rest","done":4,"total":20,"files":3}));
        let snapshot=status.snapshot(true,&json!({"state":"ready"}));
        assert_eq!(snapshot["files"],120);assert_eq!(snapshot["searchable"],100);assert_eq!(snapshot["pending"],20);
        assert_eq!(snapshot["finishing"]["files"],3);
    }

    #[test]
    fn maintenance_counts_are_not_index_totals() {
        let mut status = Status::default();
        status.apply(&json!({"event":"counts","files":120,"searchable":100,"pending":20,"unfinished":3}));
        for event in ["rescan", "pruned"] {
            status.apply(&json!({"event":event,"files":4}));
            assert_eq!(status.files, 120);
            assert_eq!(status.searchable, 100);
            assert_eq!(status.pending, 20);
        }
    }

    #[test]
    fn accelerator_failure_is_not_reported_as_a_missing_download() {
        let status = Status::default();
        let model = json!({"state":"failed","message":"No compatible Vulkan device"});
        assert!(status.line(true, &model).contains("No compatible Vulkan device"));
        assert!(!status.caveat(&model).unwrap().contains("downloaded"));
    }

    #[test]
    fn cached_counts_cannot_cross_accelerator_stores() {
        let mut status = Status { files: 10, searchable: 8, paused: true, held_until: Some("01:00".into()), ..Status::default() };
        status.reset_for_index();
        assert_eq!(status.files, 0); assert!(status.paused); assert_eq!(status.held_until.as_deref(), Some("01:00"));
        let expected = std::path::Path::new("base/nvidia-cuda/index.sqlite");
        assert!(!status.cached_counts(&json!({"index":"base/index.sqlite","files":10,"searchable":8}), expected));
        assert_eq!(status.searchable, 0);
        assert!(status.cached_counts(&json!({"index":"base/nvidia-cuda/index.sqlite","files":2,"searchable":1}), expected));
        assert_eq!(status.searchable, 1);
        assert!(!status.cached_counts(&json!({"index":"base/nvidia-cuda/index.sqlite","files":3}), expected));
        let mut relative = Status::default();
        let absolute = std::env::current_dir().unwrap().join("base/nvidia-cuda/index.sqlite");
        assert!(relative.cached_counts(&json!({"index":absolute,"files":2,"searchable":1}), std::path::Path::new("base/./old/../nvidia-cuda/index.sqlite")));
        assert_eq!(relative.searchable,1);
    }

    #[test]
    fn partial_scan_paths_stay_visible_until_a_successful_rescan() {
        let mut status = Status::default();
        let ready = json!({"state":"ready"});
        status.apply(&json!({"event":"missing","unreadable":["C:/offline"]}));
        status.apply(&json!({"event":"sync","files":3,"searchable":3,"unreadable":["C:/docs/locked"]}));
        status.apply(&json!({"event":"scan_progress","visited":1}));
        assert_eq!(status.snapshot(true, &ready)["unreadable"], json!(["C:/docs/locked","C:/offline"]));
        status.apply(&json!({"event":"sync","files":3,"searchable":3,"unreadable":[]}));
        assert_eq!(status.snapshot(true, &ready)["unreadable"], json!(["C:/offline"]));
    }
}
