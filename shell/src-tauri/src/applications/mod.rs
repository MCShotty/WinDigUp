//! Windows supplies identities and launch targets. This service never loads a model.
mod rank;
#[cfg(windows)]
mod windows;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

pub fn digest(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Options {
    pub enabled: bool,
    pub semantic_enabled: bool,
    pub overrides: BTreeMap<String, Override>,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            enabled: cfg!(windows),
            semantic_enabled: true,
            overrides: BTreeMap::new(),
        }
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Override {
    pub aliases: Vec<String>,
    pub purpose: String,
    pub hidden: bool,
}
impl Override {
    pub fn validate(&self) -> Result<(), String> {
        if self.purpose.contains('\0') || self.aliases.iter().any(|s| s.contains('\0')) {
            return Err(
                "Remove null characters from the application description or aliases.".into(),
            );
        }
        if self.aliases.len() > 16
            || self.aliases.iter().any(|s| s.chars().count() > 80)
            || self.purpose.chars().count() > 1024
        {
            return Err(
                "Use up to 16 aliases of 80 characters and a purpose of up to 1,024 characters."
                    .into(),
            );
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Target {
    Shortcut { path: String },
    Shell { parsing_name: String },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: String,
    pub identity: String,
    pub name: String,
    pub publisher: String,
    pub description: String,
    #[serde(default)]
    pub keywords: String,
    #[serde(default)]
    pub icon_revision: String,
    pub source: String,
    pub target: Target,
    pub shortcut: Option<String>,
}
impl Record {
    pub fn new(identity: String, name: String, source: &str, target: Target) -> Self {
        let shortcut = match &target {
            Target::Shortcut { path } => Some(path.clone()),
            _ => None,
        };
        Self {
            id: format!("app:{}", digest(&identity)),
            identity,
            name,
            publisher: String::new(),
            description: String::new(),
            keywords: String::new(),
            icon_revision: String::new(),
            source: source.into(),
            target,
            shortcut,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hit {
    pub id: String,
    pub result_type: String,
    pub kind: String,
    pub name: String,
    pub publisher: String,
    pub description: String,
    pub keywords: String,
    pub icon_revision: String,
    pub source: String,
    pub shortcut: Option<String>,
    pub aliases: Vec<String>,
    pub purpose: String,
    pub hidden: bool,
    pub reason: String,
    #[serde(skip)]
    tier: u8,
    #[serde(skip)]
    normalized_name: String,
    #[serde(skip)]
    normalized_aliases: Vec<String>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Cache {
    version: u32,
    sources: BTreeMap<String, Vec<Record>>,
}
#[derive(Clone, Default)]
struct Snapshot {
    records: BTreeMap<String, Record>,
    hits: Vec<Hit>,
    revision: String,
    errors: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppError {
    pub code: String,
    pub message: String,
    pub app_id: String,
}
impl AppError {
    pub fn new(code: &str, id: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            app_id: id.into(),
        }
    }
}

pub struct Catalog {
    root: PathBuf,
    cache: Mutex<Cache>,
    snapshot: RwLock<Snapshot>,
    options: RwLock<Options>,
    refreshing: AtomicBool,
    last_refresh: Mutex<Option<Instant>>,
    launching: Mutex<HashSet<String>>,
    icons: Mutex<()>,
    notify: Arc<dyn Fn(Value) + Send + Sync>,
}
impl Catalog {
    pub fn new(
        root: PathBuf,
        options: Options,
        notify: impl Fn(Value) + Send + Sync + 'static,
    ) -> Arc<Self> {
        let cache: Cache = std::fs::read(root.join("catalog.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .filter(|c: &Cache| c.version == 1)
            .unwrap_or(Cache {
                version: 1,
                ..Cache::default()
            });
        let service = Arc::new(Self {
            root,
            cache: Mutex::new(cache),
            snapshot: RwLock::default(),
            options: RwLock::new(options),
            refreshing: AtomicBool::new(false),
            last_refresh: Mutex::new(None),
            launching: Mutex::default(),
            icons: Mutex::new(()),
            notify: Arc::new(notify),
        });
        service.rebuild();
        service
    }
    pub fn supported() -> bool {
        cfg!(windows)
    }
    pub fn revision(&self) -> String {
        self.snapshot.read().unwrap().revision.clone()
    }
    pub fn enabled(&self) -> bool {
        (Self::supported() || cfg!(test)) && self.options.read().unwrap().enabled
    }
    pub fn semantic_enabled(&self) -> bool {
        self.enabled() && self.options.read().unwrap().semantic_enabled
    }
    pub fn info(&self) -> Value {
        let s = self.snapshot.read().unwrap();
        json!({"supported":Self::supported(), "enabled":self.enabled(), "semanticEnabled":self.semantic_enabled(),
            "count":s.hits.iter().filter(|h| !h.hidden).count(), "revision":s.revision,
            "refreshing":self.refreshing.load(Ordering::Relaxed), "sourceErrors":s.errors})
    }
    pub fn configure(self: &Arc<Self>, options: Options) {
        let was_enabled = self.enabled();
        *self.options.write().unwrap() = options;
        self.rebuild();
        (self.notify)(self.info());
        if self.enabled() {
            if was_enabled {
                self.refresh_if_stale();
            } else {
                self.refresh();
            }
        }
    }
    fn rebuild(&self) {
        let cache = self.cache.lock().unwrap();
        let options = self.options.read().unwrap();
        let mut records: BTreeMap<String, Record> = BTreeMap::new();
        for record in cache.sources.values().flatten() {
            if let Some(existing) = records.get_mut(&record.id) {
                let priority = |r: &Record| match r.source.as_str() {
                    "userPrograms" => 3,
                    "commonPrograms" => 2,
                    _ => 1,
                };
                let mut merged = if priority(record) > priority(existing) {
                    record.clone()
                } else {
                    existing.clone()
                };
                let other = if priority(record) > priority(existing) {
                    &*existing
                } else {
                    record
                };
                if merged.publisher.is_empty() {
                    merged.publisher = other.publisher.clone();
                }
                if merged.description.is_empty() {
                    merged.description = other.description.clone();
                }
                if merged.keywords.is_empty() {
                    merged.keywords = other.keywords.clone();
                }
                if merged.icon_revision.is_empty() {
                    merged.icon_revision = other.icon_revision.clone();
                }
                *existing = merged;
            } else {
                records.insert(record.id.clone(), record.clone());
            }
        }
        let mut hits: Vec<Hit> = records
            .values()
            .map(|r| {
                let custom = options.overrides.get(&r.id).cloned().unwrap_or_default();
                let description = if custom.purpose.trim().is_empty() {
                    r.description.clone()
                } else {
                    custom.purpose.clone()
                };
                Hit {
                    id: r.id.clone(),
                    result_type: "application".into(),
                    kind: "app".into(),
                    name: r.name.clone(),
                    publisher: r.publisher.clone(),
                    description,
                    keywords: r.keywords.clone(),
                    icon_revision: r.icon_revision.clone(),
                    source: r.source.clone(),
                    shortcut: r.shortcut.clone(),
                    normalized_name: rank::normalized(&r.name),
                    normalized_aliases: custom
                        .aliases
                        .iter()
                        .map(|s| rank::normalized(s))
                        .collect(),
                    aliases: custom.aliases,
                    purpose: custom.purpose,
                    hidden: custom.hidden,
                    reason: "catalog".into(),
                    tier: 0,
                }
            })
            .collect();
        hits.sort_by(|a, b| {
            a.normalized_name
                .cmp(&b.normalized_name)
                .then(a.id.cmp(&b.id))
        });
        let revision = digest(&serde_json::to_string(&hits).unwrap_or_default());
        let mut s = self.snapshot.write().unwrap();
        s.records = records;
        s.hits = hits;
        s.revision = revision;
    }
    fn publish_names(&self, source: &str, result: Result<Vec<Record>, String>) {
        let result = result.map(|mut records| {
            let cache = self.cache.lock().unwrap();
            let previous: BTreeMap<_, _> = cache
                .sources
                .get(source)
                .into_iter()
                .flatten()
                .map(|r| (&r.id, r))
                .collect();
            for record in &mut records {
                if let Some(old) = previous.get(&record.id) {
                    if record.publisher.is_empty() {
                        record.publisher = old.publisher.clone();
                    }
                    if record.description.is_empty()
                        || old.description.starts_with(&record.description)
                    {
                        record.description = old.description.clone();
                    }
                    if record.keywords.is_empty() {
                        record.keywords = old.keywords.clone();
                    }
                    if record.icon_revision.is_empty()
                        || old.icon_revision.starts_with(&record.icon_revision)
                    {
                        record.icon_revision = old.icon_revision.clone();
                    }
                }
            }
            records
        });
        self.publish_source(source, result);
    }
    fn publish_source(&self, source: &str, result: Result<Vec<Record>, String>) {
        match result {
            Ok(records) => {
                self.cache
                    .lock()
                    .unwrap()
                    .sources
                    .insert(source.into(), records);
                self.snapshot.write().unwrap().errors.remove(source);
                self.rebuild();
                if let Err(error) = self.save() {
                    self.snapshot
                        .write()
                        .unwrap()
                        .errors
                        .insert("cache".into(), error.to_string());
                } else {
                    self.snapshot.write().unwrap().errors.remove("cache");
                }
            }
            Err(error) => {
                self.snapshot
                    .write()
                    .unwrap()
                    .errors
                    .insert(source.into(), error);
            }
        }
        (self.notify)(self.info());
    }
    fn save(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.root)?;
        let tmp = self.root.join("catalog.json.tmp");
        std::fs::write(&tmp, serde_json::to_vec(&*self.cache.lock().unwrap())?)?;
        std::fs::rename(tmp, self.root.join("catalog.json"))
    }
    pub fn start(self: &Arc<Self>) {
        #[cfg(all(windows, not(test)))]
        windows::watch(Arc::downgrade(self));
        self.refresh_if_stale();
    }
    pub fn refresh_if_stale(self: &Arc<Self>) {
        let stale = self
            .last_refresh
            .lock()
            .unwrap()
            .is_none_or(|t| t.elapsed() > Duration::from_secs(300));
        if stale {
            self.refresh();
        }
    }
    pub fn refresh(self: &Arc<Self>) {
        if !self.enabled() || self.refreshing.swap(true, Ordering::SeqCst) {
            return;
        }
        let service = self.clone();
        std::thread::spawn(move || {
            #[cfg(all(windows, not(test)))]
            windows::scan(
                |source, result, complete| {
                    if complete {
                        service.publish_source(source, result);
                    } else {
                        service.publish_names(source, result);
                    }
                },
                || service.enabled(),
            );
            *service.last_refresh.lock().unwrap() = Some(Instant::now());
            service.refreshing.store(false, Ordering::SeqCst);
            (service.notify)(service.info());
        });
    }
    pub fn search(&self, query: &str, include_hidden: bool) -> Vec<Hit> {
        if !self.enabled() {
            return Vec::new();
        }
        let query = rank::normalized(query);
        let s = self.snapshot.read().unwrap();
        let mut hits: Vec<Hit> = s
            .hits
            .iter()
            .filter(|h| include_hidden || !h.hidden)
            .filter_map(|hit| {
                let (tier, reason) =
                    rank::lexical(&query, &hit.normalized_name, &hit.normalized_aliases)?;
                let mut h = hit.clone();
                h.tier = tier;
                h.reason = reason.into();
                Some(h)
            })
            .collect();
        hits.sort_by(|a, b| {
            a.tier
                .cmp(&b.tier)
                .then(a.normalized_name.cmp(&b.normalized_name))
                .then(a.id.cmp(&b.id))
        });
        hits
    }
    pub fn merge_semantic(&self, mut words: Vec<Hit>, semantic: &[Value]) -> Vec<Hit> {
        if !self.enabled() {
            return Vec::new();
        }
        let s = self.snapshot.read().unwrap();
        let live: HashMap<_, _> = s.hits.iter().map(|h| (h.id.as_str(), h)).collect();
        words.retain(|word| live.get(word.id.as_str()).is_some_and(|h| !h.hidden));
        let mut seen: HashSet<String> = words.iter().map(|h| h.id.clone()).collect();
        for row in semantic {
            if let Some(id) = row["id"].as_str() {
                if seen.insert(id.into()) {
                    if let Some(hit) = live.get(id).filter(|h| !h.hidden) {
                        let mut h = (**hit).clone();
                        h.reason = "semantic".into();
                        words.push(h);
                    }
                }
            }
        }
        words
    }
    pub fn documents(&self) -> Value {
        let s = self.snapshot.read().unwrap();
        let docs: Vec<Value> = if self.semantic_enabled() {
            s.hits
                .iter()
                .filter(|h| !h.hidden)
                .map(|h| {
                    // Identity and user purpose come first, inside the existing 512-token text profile.
                    let text = format!(
                        "Application: {}\nPurpose: {}\nAliases: {}\nPublisher: {}\nKeywords: {}",
                        h.name,
                        h.description,
                        h.aliases.join(", "),
                        h.publisher,
                        h.keywords
                    );
                    json!({"id":h.id,"name":h.name,"text":text,"hash":digest(&text)})
                })
                .collect()
        } else {
            Vec::new()
        };
        json!({"revision":s.revision,"documents":docs})
    }
    pub fn icon_path(&self, id: &str, size: u32) -> Result<PathBuf, AppError> {
        let record = self.record(id)?;
        let _icon = self.icons.lock().unwrap();
        let size = if size <= 32 {
            32
        } else if size <= 64 {
            64
        } else {
            128
        };
        let path = self.root.join("icons").join(format!(
            "{}-{size}.png",
            digest(&serde_json::to_string(&record).unwrap_or_default())
        ));
        if !path.is_file() {
            std::fs::create_dir_all(path.parent().unwrap())
                .map_err(|e| AppError::new("unavailable", id, e.to_string()))?;
            #[cfg(windows)]
            {
                let temporary = path.with_extension("png.tmp");
                windows::icon(&record.target, size, &temporary)
                    .map_err(|e| AppError::new("unavailable", id, e))?;
                std::fs::rename(&temporary, &path)
                    .map_err(|e| AppError::new("unavailable", id, e.to_string()))?;
            }
            #[cfg(not(windows))]
            return Err(AppError::new(
                "unavailable",
                id,
                "Application icons are supported on Windows.",
            ));
        }
        Ok(path)
    }
    fn record(&self, id: &str) -> Result<Record, AppError> {
        if !self.enabled() {
            return Err(AppError::new(
                "unavailable",
                id,
                "Application search is disabled.",
            ));
        }
        let s = self.snapshot.read().unwrap();
        if s.hits.iter().any(|h| h.id == id && !h.hidden) {
            if let Some(r) = s.records.get(id) {
                return Ok(r.clone());
            }
        }
        Err(AppError::new(
            "not_found",
            id,
            "This application is no longer in the catalog. Refresh applications and try again.",
        ))
    }
    pub fn launch(self: &Arc<Self>, id: &str) -> Result<(), AppError> {
        let record = self.record(id).map_err(|error| {
            self.refresh();
            error
        })?;
        if let Target::Shortcut { path } = &record.target {
            if !std::path::Path::new(path).is_file() {
                self.refresh();
                return Err(AppError::new("unavailable", id, "The application's shortcut is no longer available. Refreshing installed applications."));
            }
        }
        if !self.launching.lock().unwrap().insert(id.into()) {
            return Err(AppError::new(
                "unavailable",
                id,
                "A launch request is already pending.",
            ));
        }
        #[cfg(windows)]
        let result = windows::launch(&record.target);
        #[cfg(not(windows))]
        let result: Result<(), String> = {
            let _ = record;
            Err("Application launching is supported on Windows.".into())
        };
        self.launching.lock().unwrap().remove(id);
        if result.is_err() {
            self.refresh();
        }
        result.map_err(|e| AppError::new("launch_failed", id, e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn record(name: &str, identity: &str) -> Record {
        Record::new(
            identity.into(),
            name.into(),
            "fixture",
            Target::Shortcut {
                path: format!("/{name}.lnk"),
            },
        )
    }
    #[test]
    fn equivalent_identities_merge_but_argument_variants_survive() {
        let root = std::env::temp_dir().join(format!("digup-apps-{}", std::process::id()));
        let c = Catalog::new(root.clone(), Options::default(), |_| {});
        c.publish_source(
            "user",
            Ok(vec![
                record("Browser", "browser --profile=a"),
                record("Browser work", "browser --profile=b"),
            ]),
        );
        c.publish_source(
            "common",
            Ok(vec![record("Browser duplicate", "browser --profile=a")]),
        );
        assert_eq!(c.snapshot.read().unwrap().records.len(), 2);
        c.publish_source("user", Err("temporarily unreadable".into()));
        assert_eq!(c.snapshot.read().unwrap().records.len(), 2);
        c.publish_source("user", Ok(vec![]));
        assert_eq!(c.snapshot.read().unwrap().records.len(), 1);
        let reloaded = Catalog::new(root.clone(), Options::default(), |_| {});
        assert_eq!(reloaded.snapshot.read().unwrap().records.len(), 1);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn annotation_limits() {
        assert!(Override {
            aliases: vec!["x".repeat(81)],
            ..Override::default()
        }
        .validate()
        .is_err());
        assert!(Override {
            purpose: "x".repeat(1025),
            ..Override::default()
        }
        .validate()
        .is_err());
        assert!(Override {
            aliases: vec!["name\0hidden".into()],
            ..Override::default()
        }
        .validate()
        .is_err());
    }
    #[test]
    fn name_publication_retains_metadata_until_optional_enrichment_finishes() {
        let root = std::env::temp_dir().join(format!("digup-app-metadata-{}", std::process::id()));
        let c = Catalog::new(
            root.clone(),
            Options {
                enabled: true,
                ..Options::default()
            },
            |_| {},
        );
        let mut rich = record("Photo Studio", "photo");
        rich.description = "Shortcut comment\nEdits photographs".into();
        rich.publisher = "Example Publisher".into();
        rich.icon_revision = "file-stamp:version-1".into();
        c.publish_source("userPrograms", Ok(vec![rich.clone()]));
        let before = c.documents();
        let mut names = rich.clone();
        names.publisher.clear();
        names.description = "Shortcut comment".into();
        names.icon_revision = "file-stamp:".into();
        c.publish_names("userPrograms", Ok(vec![names.clone()]));
        assert_eq!(before, c.documents());
        names.description = "Updated purpose".into();
        c.publish_source("userPrograms", Ok(vec![names]));
        assert_ne!(
            before["documents"][0]["hash"],
            c.documents()["documents"][0]["hash"]
        );
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn damaged_catalog_rebuild_preserves_annotations_and_icon_changes_preserve_documents() {
        let root = std::env::temp_dir().join(format!("digup-app-recovery-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("catalog.json"), b"damaged cache").unwrap();
        let mut app = record("Photo Studio", "packaged:Example.Photo_abc!App");
        let mut options = Options {
            enabled: true,
            ..Options::default()
        };
        options.overrides.insert(
            app.id.clone(),
            Override {
                aliases: vec!["retouch".into()],
                ..Override::default()
            },
        );
        let c = Catalog::new(root.clone(), options.clone(), |_| {});
        assert!(c.search("", false).is_empty());
        c.publish_source("appsFolder", Ok(vec![app.clone()]));
        let before = c.documents();
        app.icon_revision = "new-icon".into();
        c.publish_source("appsFolder", Ok(vec![app.clone()]));
        assert_ne!(before["revision"], c.documents()["revision"]);
        assert_eq!(before["documents"], c.documents()["documents"]);
        c.publish_source("appsFolder", Ok(vec![]));
        c.publish_source("appsFolder", Ok(vec![app]));
        assert_eq!(c.search("retouch", false)[0].reason, "exact");
        let reloaded = Catalog::new(root.clone(), options, |_| {});
        assert_eq!(reloaded.search("retouch", false).len(), 1);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn hidden_removed_and_duplicate_semantic_hits_never_reappear() {
        let root = std::env::temp_dir().join(format!("digup-app-filter-{}", std::process::id()));
        let a = record("Photo Studio", "photo");
        let b = record("Browser", "browser");
        let mut options = Options {
            enabled: true,
            ..Options::default()
        };
        options.overrides.insert(
            a.id.clone(),
            Override {
                aliases: vec!["retouch".into()],
                ..Override::default()
            },
        );
        let c = Catalog::new(root.clone(), options.clone(), |_| {});
        c.publish_source("user", Ok(vec![a.clone(), b.clone()]));
        assert_eq!(c.search("retouch", false)[0].reason, "exact");
        let words = c.search("Photo Studio", false);
        assert_eq!(
            c.merge_semantic(
                words,
                &[
                    json!({"id":a.id}),
                    json!({"id":b.id}),
                    json!({"id":"app:missing"})
                ]
            )
            .len(),
            2
        );
        options.overrides.get_mut(&a.id).unwrap().hidden = true;
        c.configure(options);
        assert!(c.search("retouch", false).is_empty());
        assert!(c
            .merge_semantic(Vec::new(), &[json!({"id":a.id})])
            .is_empty());
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn cached_name_search_budget() {
        let root = std::env::temp_dir().join(format!("digup-app-benchmark-{}", std::process::id()));
        let c = Catalog::new(
            root.clone(),
            Options {
                enabled: true,
                ..Options::default()
            },
            |_| {},
        );
        c.publish_source(
            "fixture",
            Ok((0..2000)
                .map(|i| record(&format!("Application {i:04}"), &format!("app-{i}")))
                .collect()),
        );
        let mut times = Vec::new();
        for query in [
            "application 1999",
            "app 040",
            "aplication 1234",
            "unlikely xyz",
        ] {
            for _ in 0..15 {
                let start = Instant::now();
                let _ = c.search(query, false);
                times.push(start.elapsed());
            }
        }
        times.sort();
        let p95 = times[times.len() * 95 / 100];
        println!(
            "cached native name search: 2000 records, p95={:.2} ms, {} {}",
            p95.as_secs_f64() * 1000.0,
            std::env::consts::OS,
            std::env::consts::ARCH
        );
        // The UI/IPC target is measured separately; this catches a slow algorithm or accidental I/O in the hot path.
        assert!(
            p95 < Duration::from_millis(50),
            "native name search exceeded its 50 ms budget: {p95:?}"
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
