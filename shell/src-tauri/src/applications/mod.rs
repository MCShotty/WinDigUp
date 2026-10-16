//! Windows supplies identities and launch targets. This service never loads a model.
pub(crate) mod rank;
pub mod enrichment;
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

/// Filter before counting and pagination; a hidden match beyond page one must remain discoverable in Settings.
pub fn page_hits(mut hits: Vec<Hit>, visibility: &str, offset: usize, limit: usize) -> (Vec<Hit>, usize, usize) {
    hits.retain(|hit| visibility == "all" || hit.hidden == (visibility == "hidden"));
    let total=hits.len();
    let offset=offset.min(1_000_000);
    (hits.into_iter().skip(offset).take(limit.clamp(1,100)).collect(),total,offset)
}

pub fn anchor_offset(hits: &[Hit], visibility: &str, id: Option<&str>) -> Option<usize> {
    let id=id?;
    hits.iter().filter(|hit| visibility == "all" || hit.hidden == (visibility == "hidden"))
        .position(|hit| hit.id == id)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Options {
    pub enabled: bool,
    pub semantic_enabled: bool,
    pub mixed_search: MixedSearch,
    pub overrides: BTreeMap<String, Override>,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            enabled: cfg!(windows),
            semantic_enabled: true,
            mixed_search: MixedSearch::Smart,
            overrides: BTreeMap::new(),
        }
    }
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum MixedSearch {
    #[default]
    Smart,
    FilesFirst,
    AppsOnly,
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
    Executable { path: String, working_directory: String },
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
    #[serde(default)] pub launch_key: String,
    #[serde(default)] pub executable: String,
    #[serde(default)] pub working_directory: String,
    #[serde(default)] pub arguments: String,
    #[serde(default)] pub product: String,
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
            launch_key: String::new(), executable: String::new(), working_directory: String::new(),
            arguments: String::new(), product: String::new(),
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
    #[serde(skip_serializing_if="Option::is_none")] pub description_source: Option<Value>,
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
    #[serde(default)] launch_identities: BTreeMap<String,String>,
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
    save_lock: Mutex<()>,
    discovery_sources: RwLock<HashSet<String>>,
    discovery_refreshing: AtomicBool,
    discovery_hidden: RwLock<HashSet<String>>,
    enrichment: RwLock<BTreeMap<String,enrichment::Description>>,
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
            save_lock: Mutex::new(()),
            discovery_sources: RwLock::new(HashSet::new()),
            discovery_refreshing: AtomicBool::new(false),
            discovery_hidden: RwLock::new(HashSet::new()),
            enrichment: RwLock::new(BTreeMap::new()),
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
        // Every reader takes options before the snapshot, as rebuild does. Reversing this order
        // can deadlock with a queued settings writer on writer-preferring platforms.
        let options = self.options.read().unwrap();
        let enabled = (Self::supported() || cfg!(test)) && options.enabled;
        let s = self.snapshot.read().unwrap();
        json!({"supported":Self::supported(), "enabled":enabled, "semanticEnabled":enabled && options.semantic_enabled,
            "mixedSearch":options.mixed_search,
            "count":s.hits.iter().filter(|h| !h.hidden).count(), "totalCount":s.hits.len(),
            "hiddenCount":s.hits.iter().filter(|h| h.hidden).count(), "revision":s.revision,
            "semanticLimit":20000,"semanticOverflow":s.hits.iter().filter(|h|!h.hidden).count().saturating_sub(20000),
            "refreshing":self.refreshing.load(Ordering::Relaxed)||self.discovery_refreshing.load(Ordering::Relaxed), "sourceErrors":s.errors})
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
        let mut cache = self.cache.lock().unwrap();
        let options = self.options.read().unwrap();
        let discovery=self.discovery_sources.read().unwrap();
        let hidden_discoveries=self.discovery_hidden.read().unwrap();
        let priority=|r:&Record|match r.source.as_str(){"userPrograms"=>3,"commonPrograms"=>2,_=>1};
        let mut input:Vec<Record>=cache.sources.iter().filter(|(source,_)|!source.starts_with("drive:")||discovery.contains(*source))
            .flat_map(|(_,records)|records.iter().cloned())
            .filter(|r|!r.identity.strip_prefix("discovered:").is_some_and(|id|hidden_discoveries.contains(id))).collect();
        input.sort_by(|a,b|priority(b).cmp(&priority(a)).then_with(||a.id.cmp(&b.id)));
        let mut records: BTreeMap<String, Record> = BTreeMap::new();
        for original in &input {
            let mut record=original.clone();
            if !record.launch_key.is_empty() {
                let canonical=cache.launch_identities.entry(record.launch_key.clone()).or_insert_with(||record.identity.clone()).clone();
                record.identity=canonical;record.id=format!("app:{}",digest(&record.identity));
            }
            let record=&record;
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
        let enrichment=self.enrichment.read().unwrap();
        let mut hits: Vec<Hit> = records
            .values()
            .map(|r| {
                let custom = options.overrides.get(&r.id).cloned().unwrap_or_default();
                let fetched=enrichment.get(&r.id).filter(|_|custom.purpose.trim().is_empty());
                let description = if custom.purpose.trim().is_empty() {
                    fetched.map(|d|d.description.clone()).unwrap_or_else(||r.description.clone())
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
                    description_source:fetched.map(|d|json!({"provider":d.source,"url":d.url,"packageId":d.package_id,"version":d.package_version,"extractorVersion":d.extractor_version})),
                    keywords:if let Some(d)=fetched{format!("{} {}",r.keywords,d.tags.join(" ")).trim().to_string()}else{r.keywords.clone()},
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
        let _writer=self.save_lock.lock().unwrap();
        std::fs::create_dir_all(&self.root)?;
        let tmp = self.root.join("catalog.json.tmp");
        std::fs::write(&tmp, serde_json::to_vec(&*self.cache.lock().unwrap())?)?;
        std::fs::rename(tmp, self.root.join("catalog.json"))
    }
    pub fn configure_discovery(&self,sources:HashSet<String>,hidden:HashSet<String>){
        *self.discovery_sources.write().unwrap()=sources;
        *self.discovery_hidden.write().unwrap()=hidden;self.rebuild();(self.notify)(self.info());
    }
    pub fn publish_discovery(&self,source:&str,records:Vec<Record>,complete:bool){
        if !source.starts_with("drive:"){return}
        let records=if complete{records}else{
            let mut merged:BTreeMap<String,Record>=self.cache.lock().unwrap().sources.get(source).into_iter()
                .flatten().cloned().map(|r|(r.id.clone(),r)).collect();
            for record in records{merged.insert(record.id.clone(),record);}
            merged.into_values().collect()
        };
        self.publish_source(source,Ok(records));
    }
    pub fn discovery_running(&self,running:bool){self.discovery_refreshing.store(running,Ordering::SeqCst);(self.notify)(self.info());}
    pub fn records(&self)->Vec<Record>{self.snapshot.read().unwrap().records.values().cloned().collect()}
    pub fn enrich(&self,descriptions:BTreeMap<String,enrichment::Description>){
        *self.enrichment.write().unwrap()=descriptions;self.rebuild();(self.notify)(self.info());
    }
    pub fn enriched_count(&self)->usize{let descriptions=self.enrichment.read().unwrap();self.snapshot.read().unwrap().hits.iter().filter(|h|!h.hidden&&descriptions.contains_key(&h.id)).count()}
    pub fn description_source(&self,id:&str)->Option<String>{self.enrichment.read().unwrap().get(id).map(|d|d.url.clone())}
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
        let semantic_enabled = self.semantic_enabled();
        let s = self.snapshot.read().unwrap();
        let docs: Vec<Value> = if semantic_enabled {
            let mut candidates=s.hits.iter().filter(|h|!h.hidden).collect::<Vec<_>>();
            let priority=|h:&Hit|if !h.purpose.is_empty()||!h.aliases.is_empty(){0}else if !h.source.starts_with("drive:"){1}else{2};
            candidates.sort_by(|a,b|priority(a).cmp(&priority(b)).then_with(||a.name.cmp(&b.name)).then_with(||a.id.cmp(&b.id)));
            candidates.into_iter()
                .take(20_000)
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
    #[test]
    fn description_changes_are_scoped_and_user_purpose_wins(){
        let root=std::env::temp_dir().join(format!("digup-enriched-catalog-{}",std::process::id()));
        let _=std::fs::remove_dir_all(&root);
        let c=Catalog::new(root.clone(),Options{enabled:true,..Options::default()},|_|{});
        let mut r=record("Editor","editor");let id=r.id.clone();r.publisher="Example".into();
        c.publish_source("userPrograms",Ok(vec![r.clone()]));
        let original=c.documents()["documents"][0]["hash"].clone();
        let d=enrichment::Description{description:"Retouch photographs and correct portrait colors".into(),tags:vec!["portrait".into()],
            package_id:"Example.Editor".into(),package_version:"1.2.3".into(),name:"Editor".into(),publisher:"Example".into(),
            source:"WinGet".into(),url:"https://example.com/product".into(),extractor_version:1,..Default::default()};
        c.enrich([(id.clone(),d.clone())].into_iter().collect());
        let enriched=c.documents()["documents"][0]["hash"].clone();assert_ne!(original,enriched);
        r.icon_revision="new-icon".into();c.publish_source("userPrograms",Ok(vec![r]));
        assert_eq!(c.documents()["documents"][0]["hash"],enriched);
        let mut next=d;next.fetched=12345;c.enrich([(id.clone(),next)].into_iter().collect());
        assert_eq!(c.documents()["documents"][0]["hash"],enriched);
        let mut options=Options{enabled:true,..Options::default()};
        options.overrides.insert(id.clone(),Override{purpose:"My custom purpose".into(),..Default::default()});
        c.configure(options);
        let hit=c.search("Editor",false).remove(0);assert_eq!(hit.description,"My custom purpose");
        assert!(hit.description_source.is_none());assert!(!hit.keywords.contains("portrait"));
        let _=std::fs::remove_dir_all(root);
    }
    #[test]
    fn discovered_equivalent_launches_keep_identity_and_prefer_original_shortcut(){
        let root=std::env::temp_dir().join(format!("digup-discovery-catalog-{}",std::process::id()));
        let _=std::fs::remove_dir_all(&root);
        let c=Catalog::new(root.clone(),Options{enabled:true,..Options::default()},|_|{});
        c.configure_discovery(["drive:test".to_string()].into_iter().collect(),HashSet::new());
        let mut discovered=Record::new("discovered:exe:one".into(),"Editor".into(),"drive:test",
            Target::Executable{path:"C:/Editor/Editor.exe".into(),working_directory:"C:/Editor".into()});
        discovered.launch_key="same-file-arguments-and-directory".into();
        let original_id=discovered.id.clone();
        c.publish_discovery("drive:test",vec![discovered],true);
        let mut shortcut=Record::new("shortcut:original".into(),"Editor".into(),"userPrograms",Target::Shortcut{path:"C:/Start/Editor.lnk".into()});
        shortcut.launch_key="same-file-arguments-and-directory".into();
        c.publish_source("userPrograms",Ok(vec![shortcut]));
        let hits=c.search("Editor",false);assert_eq!(hits.len(),1);assert_eq!(hits[0].id,original_id);
        assert!(matches!(c.record(&original_id).unwrap().target,Target::Shortcut{..}));
        c.configure_discovery(HashSet::new(),HashSet::new());
        assert_eq!(c.search("Editor",false).len(),1,"Disabling discovery retains the registered shortcut.");
        let _=std::fs::remove_dir_all(root);
    }
    #[test]
    fn hidden_discoveries_are_removed_before_old_semantic_results_can_return(){
        let root=std::env::temp_dir().join(format!("digup-hidden-discovery-{}",std::process::id()));
        let _=std::fs::remove_dir_all(&root);
        let c=Catalog::new(root.clone(),Options{enabled:true,..Options::default()},|_|{});
        c.configure_discovery(["drive:test".to_string()].into_iter().collect(),HashSet::new());
        let r=Record::new("discovered:exe:one".into(),"Editor".into(),"drive:test",
            Target::Executable{path:"C:/Editor.exe".into(),working_directory:"C:/".into()});
        let id=r.id.clone();c.publish_discovery("drive:test",vec![r],true);
        c.configure_discovery(["drive:test".to_string()].into_iter().collect(),["exe:one".to_string()].into_iter().collect());
        assert!(c.search("",false).is_empty());
        assert!(c.merge_semantic(vec![],&[json!({"id":id,"cosine":0.99})]).is_empty());
        let _=std::fs::remove_dir_all(root);
    }
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
    fn waiting_for_options_never_locks_the_catalog_snapshot() {
        // rebuild acquires options before the snapshot. Taking those locks in the reverse order
        // deadlocks when a settings writer queues between two readers on a writer-preferring RwLock.
        let catalog = Catalog::new(std::env::temp_dir().join(format!("digup-locks-{}", std::process::id())), Options::default(), |_| {});
        for documents in [false, true] {
            let options = catalog.options.write().unwrap();
            let copy = catalog.clone();
            let (started, ready) = std::sync::mpsc::channel();
            let reader = std::thread::spawn(move || {
                started.send(()).unwrap();
                if documents { copy.documents() } else { copy.info() }
            });
            ready.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
            let mut blocked = false;
            for _ in 0..100 {
                blocked |= catalog.snapshot.try_write().is_err();
                if blocked { break; }
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            drop(options);
            reader.join().unwrap();
            assert!(!blocked, "a settings-blocked reader held the catalog snapshot (documents={documents})");
        }
    }

    #[test]
    fn visibility_counts_and_pages_are_filtered_before_the_limit() {
        let root=std::env::temp_dir().join(format!("digup-visibility-{}",std::process::id()));
        let records=(0..205).map(|n|record(&format!("App {n:03}"),&format!("id-{n}"))).collect::<Vec<_>>();
        let mut options=Options {enabled:true,..Options::default()};
        options.overrides.insert(records[204].id.clone(),Override {hidden:true,..Override::default()});
        let catalog=Catalog::new(root.clone(),options,|_|{});catalog.publish_source("fixture",Ok(records));
        let (hidden,total,_)=page_hits(catalog.search("",true),"hidden",0,100);
        assert_eq!(total,1);assert_eq!(hidden[0].name,"App 204");
        assert_eq!(anchor_offset(&catalog.search("",true),"all",Some(&hidden[0].id)),Some(204));
        assert_eq!(anchor_offset(&catalog.search("",true),"visible",Some(&hidden[0].id)),None);
        let (visible,total,offset)=page_hits(catalog.search("",true),"visible",200,100);
        assert_eq!(total,204);assert_eq!(visible.len(),4);assert_eq!(offset,200);
        assert!(visible.iter().all(|hit|!hit.hidden));
        let (all,total,_)=page_hits(catalog.search("",true),"all",0,999);
        assert_eq!(all.len(),100);assert_eq!(total,205);
        std::fs::remove_dir_all(root).unwrap();
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
