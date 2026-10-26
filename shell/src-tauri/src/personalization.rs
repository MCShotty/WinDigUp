use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{Read, Write},
    path::PathBuf,
    sync::{mpsc, Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const VERSION: u32 = 1;
const MAX_ENTRIES: usize = 5_000;
const MAX_SESSIONS: usize = 32;
const MAX_RECEIPTS: usize = 512;
const RETENTION: u64 = 90 * 24 * 60 * 60;
const RECEIPT_LIFETIME: Duration = Duration::from_secs(10 * 60);

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Options { pub enabled: bool }
impl Default for Options { fn default() -> Self { Self { enabled: true } } }

#[derive(Clone, Default, Serialize, Deserialize)]
struct Entry { uses: u32, useful: u32, updated: u64 }
impl Entry {
    fn signal(&self) -> u32 { self.uses.saturating_add(self.useful.saturating_mul(3)).min(100) }
}
#[derive(Default, Serialize, Deserialize)]
struct History { version: u32, entries: BTreeMap<String, Entry> }
struct Frozen { generation: u64, touched: Instant, signals: Arc<BTreeMap<String, u32>> }
struct Receipt { key: String, touched: Instant, used: bool }
struct State {
    enabled: bool,
    entries: BTreeMap<String, Entry>,
    sessions: HashMap<String, Frozen>,
    receipts: HashMap<String, Receipt>,
    last_open: HashMap<String, Instant>,
    error: Option<String>,
}
pub struct Personalization {
    state: Arc<Mutex<State>>,
    persist: mpsc::SyncSender<Option<mpsc::Sender<Result<(), String>>>>,
}
fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() }
fn digest(key: &str) -> String {
    format!("{:x}", Sha256::digest(key.as_bytes()))
}
fn valid_digest(key: &str) -> bool { key.len() == 64 && key.bytes().all(|c| c.is_ascii_hexdigit()) }
fn prune(entries: &mut BTreeMap<String, Entry>, clock: u64) {
    entries.retain(|key, entry| valid_digest(key) && entry.updated <= clock.saturating_add(86_400)
        && clock.saturating_sub(entry.updated) <= RETENTION);
    while entries.len() > MAX_ENTRIES {
        let oldest = entries.iter().min_by_key(|(key, entry)| (entry.updated, *key)).map(|(key, _)| key.clone());
        if let Some(key) = oldest { entries.remove(&key); } else { break; }
    }
}
impl Personalization {
    pub fn new(path: PathBuf, options: Options) -> Self {
        let mut entries = fs::File::open(&path).ok().and_then(|file| {
            let mut bytes = Vec::new();
            file.take(2_000_001).read_to_end(&mut bytes).ok()?;
            if bytes.len() > 2_000_000 { return None; }
            let history: History = serde_json::from_slice(&bytes).ok()?;
            (history.version == VERSION).then_some(history.entries)
        }).unwrap_or_default();
        prune(&mut entries, now());
        let state = Arc::new(Mutex::new(State {
            enabled: options.enabled, entries, sessions: HashMap::new(), receipts: HashMap::new(),
            last_open: HashMap::new(), error: None,
        }));
        let (persist, receiver) = mpsc::sync_channel::<Option<mpsc::Sender<Result<(), String>>>>(1);
        let weak = Arc::downgrade(&state);
        std::thread::spawn(move || {
            while let Ok(first) = receiver.recv() {
                let mut replies = first.into_iter().collect::<Vec<_>>();
                // Coalesce interaction bursts without delaying search or native activation.
                std::thread::sleep(Duration::from_millis(150));
                while let Ok(message) = receiver.try_recv() { replies.extend(message); }
                let Some(state) = weak.upgrade() else { break };
                let history = {
                    let mut guard = state.lock().unwrap();
                    prune(&mut guard.entries, now());
                    History { version: VERSION, entries: guard.entries.clone() }
                };
                let result = (|| -> Result<(), String> {
                    if let Some(parent) = path.parent() { fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
                    let temporary = path.with_extension("json.new");
                    let mut file = fs::File::create(&temporary).map_err(|e| e.to_string())?;
                    let bytes = serde_json::to_vec(&history).map_err(|e| e.to_string())?;
                    file.write_all(&bytes).and_then(|_| file.sync_all()).map_err(|e| e.to_string())?;
                    fs::rename(&temporary, &path).map_err(|e| e.to_string())
                })();
                state.lock().unwrap().error = result.as_ref().err().map(|_| "Local relevance history could not be saved.".into());
                for reply in replies { let _ = reply.send(result.clone()); }
            }
        });
        Self { state, persist }
    }
    pub fn info(&self) -> Value {
        let state = self.state.lock().unwrap();
        json!({"version":VERSION,"enabled":state.enabled,"entries":state.entries.len(),"message":state.error})
    }
    pub fn configure(&self, options: Options) {
        let mut state = self.state.lock().unwrap();
        state.enabled = options.enabled;
        state.sessions.clear();
        state.receipts.clear();
    }
    pub fn clear(&self) -> Result<Value, String> {
        {
            let mut state = self.state.lock().unwrap();
            state.entries.clear(); state.sessions.clear(); state.receipts.clear(); state.last_open.clear();
        }
        let (reply, receiver) = mpsc::channel();
        self.persist.send(Some(reply)).map_err(|_| "Local relevance history could not be cleared.".to_string())?;
        receiver.recv().map_err(|_| "Local relevance history could not be cleared.".to_string())??;
        Ok(self.info())
    }
    fn signals(&self, session: &str, generation: u64) -> Arc<BTreeMap<String, u32>> {
        let mut state = self.state.lock().unwrap();
        if !state.enabled { return Arc::new(BTreeMap::new()); }
        if let Some(frozen) = state.sessions.get_mut(session) {
            if frozen.generation == generation { frozen.touched = Instant::now(); return frozen.signals.clone(); }
            if frozen.generation > generation { return Arc::new(BTreeMap::new()); }
        }
        state.sessions.retain(|_, value| value.touched.elapsed() < RECEIPT_LIFETIME);
        if !state.sessions.contains_key(session) && state.sessions.len() >= MAX_SESSIONS {
            if let Some(oldest) = state.sessions.iter().max_by_key(|(_, value)| value.touched.elapsed()).map(|(key, _)| key.clone()) {
                state.sessions.remove(&oldest);
            }
        }
        prune(&mut state.entries, now());
        let signals: Arc<BTreeMap<String, u32>> = Arc::new(state.entries.iter().map(|(key, entry)| (key.clone(), entry.signal())).collect());
        state.sessions.insert(session.into(), Frozen { generation, touched: Instant::now(), signals: signals.clone() });
        signals
    }
    pub fn rank<T: Clone>(&self, session: &str, generation: u64, query: &str, hits: &mut [T],
        key: impl Fn(&T) -> String, tier: impl Fn(&T) -> u8) {
        if query.trim().is_empty() { return; }
        let signals = self.signals(session, generation);
        if signals.is_empty() { return; }
        for class in 0..=4 {
            let indices: Vec<_> = hits.iter().enumerate().filter_map(|(i, hit)| (tier(hit) == class).then_some(i)).collect();
            let mut bucket: Vec<_> = indices.iter().enumerate().map(|(rank, &i)| {
                let signal = signals.get(&digest(&key(&hits[i]))).copied().unwrap_or(0);
                (rank, signal, hits[i].clone())
            }).collect();
            for at in 0..bucket.len() {
                let end = (at + 3).min(bucket.len());
                let best = (at..end).filter(|&i| bucket[i].0 <= at + 2)
                    .max_by_key(|&i| (bucket[i].1, std::cmp::Reverse(bucket[i].0))).unwrap_or(at);
                let chosen = bucket.remove(best); bucket.insert(at, chosen);
            }
            for (&i, (_, _, hit)) in indices.iter().zip(bucket) { hits[i] = hit; }
        }
    }
    pub fn decorate(&self, session: &str, generation: u64, hits: &mut [Value]) {
        let signals = self.signals(session, generation);
        let mut state = self.state.lock().unwrap();
        if !state.enabled { return; }
        state.receipts.retain(|_, receipt| receipt.touched.elapsed() < RECEIPT_LIFETIME);
        for hit in hits {
            let Some(key) = result_key(hit) else { continue };
            let key = digest(&key);
            hit["personalizationSignal"] = json!(signals.get(&key).copied().unwrap_or(0));
            let token = digest(&format!("{session}:{generation}:{key}"));
            while state.receipts.len() >= MAX_RECEIPTS {
                if let Some(oldest) = state.receipts.iter().max_by_key(|(_, value)| value.touched.elapsed()).map(|(key, _)| key.clone()) {
                    state.receipts.remove(&oldest);
                } else { break; }
            }
            let receipt = state.receipts.entry(token.clone()).or_insert(Receipt { key, touched: Instant::now(), used: false });
            receipt.touched = Instant::now();
            hit["feedbackToken"] = json!(token);
            hit["usefulSaved"] = json!(receipt.used);
        }
    }
    pub fn accepted(&self, key: &str) {
        let key = digest(key);
        let mut state = self.state.lock().unwrap();
        if !state.enabled || !state.receipts.values().any(|r| r.key == key && r.touched.elapsed() < RECEIPT_LIFETIME) { return; }
        if state.last_open.get(&key).is_some_and(|last| last.elapsed() < Duration::from_secs(2)) { return; }
        if state.last_open.len() >= MAX_RECEIPTS { state.last_open.retain(|_, last| last.elapsed() < Duration::from_secs(2)); }
        state.last_open.insert(key.clone(), Instant::now());
        let entry = state.entries.entry(key).or_default();
        entry.uses = entry.uses.saturating_add(1); entry.updated = now();
        prune(&mut state.entries, now());
        drop(state);
        let _ = self.persist.try_send(None);
    }
    pub fn useful(&self, token: &str) -> Result<Value, String> {
        let mut state = self.state.lock().unwrap();
        if !state.enabled { return Err("Enable result personalization before saving feedback.".into()); }
        let receipt = state.receipts.get_mut(token).filter(|r| r.touched.elapsed() < RECEIPT_LIFETIME)
            .ok_or("This result is no longer current. Search again before saving feedback.")?;
        if receipt.used { return Ok(json!({"saved":true})); }
        receipt.used = true;
        let key = receipt.key.clone();
        let entry = state.entries.entry(key).or_default();
        entry.useful = entry.useful.saturating_add(1); entry.updated = now();
        prune(&mut state.entries, now());
        drop(state);
        let _ = self.persist.try_send(None);
        Ok(json!({"saved":true}))
    }
}
pub fn result_key(hit: &Value) -> Option<String> {
    if matches!(hit["resultType"].as_str(), Some("application" | "windows_setting")) {
        hit["id"].as_str().map(str::to_string)
    } else { hit["path"].as_str().map(|path| format!("file:{path}")) }
}
pub fn tier(reason: &str) -> u8 {
    match reason { "exact" => 0, "prefix" => 1, "substring" => 2, "fuzzy" => 3, _ => 4 }
}
pub fn file_tier(hit: &Value, query: &str) -> u8 {
    let query = crate::applications::rank::normalized(query);
    let name = hit["path"].as_str().unwrap_or_default().rsplit(['/', '\\']).next().unwrap_or_default();
    let name = crate::applications::rank::normalized(name);
    let stem = name.rsplit_once('.').map(|(stem, _)| stem).unwrap_or(&name).to_string();
    crate::applications::rank::lexical(&query, &name, &[stem]).map(|(tier, _)| if tier <= 2 { tier } else { 4 }).unwrap_or(4)
}

pub fn match_sources(hits: &mut [Value], query: &str) {
    let query = crate::applications::rank::normalized(query);
    for hit in hits {
        let source = match hit["resultType"].as_str() {
            Some("application" | "windows_setting") => {
                if query.is_empty() { continue; }
                if hit["reason"] == "semantic" { "purpose" } else {
                    let name = crate::applications::rank::normalized(hit["name"].as_str().unwrap_or_default());
                    let name_tier = crate::applications::rank::lexical(&query, &name, &[]).map(|(tier, _)| tier);
                    if name_tier == Some(tier(hit["reason"].as_str().unwrap_or_default())) { "name" } else { "alias" }
                }
            }
            _ => if file_tier(hit, &query) < 4 { "name" } else { "content" },
        };
        hit["matchSource"] = json!(source);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn history() -> (Personalization, PathBuf) {
        let root = std::env::temp_dir().join(format!("digup-history-{}-{}", std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        let path = root.join("history.json");
        (Personalization::new(path.clone(), Options::default()), path)
    }
    fn seed(history: &Personalization, key: &str, uses: u32) {
        history.state.lock().unwrap().entries.insert(digest(key), Entry { uses, useful: 0, updated: now() });
    }
    fn order(history: &Personalization, session: &str, generation: u64, hits: &[(String, u8)]) -> Vec<(String, u8)> {
        let mut hits = hits.to_vec();
        history.rank(session, generation, "query", &mut hits, |hit| hit.0.clone(), |hit| hit.1);
        hits
    }
    fn flush(history: &Personalization) {
        let (tx, rx) = mpsc::channel();
        history.persist.send(Some(tx)).unwrap();
        rx.recv_timeout(Duration::from_secs(3)).unwrap().unwrap();
    }
    #[test]
    fn promotion_is_bounded_and_never_changes_match_class() {
        let (history, _) = history();
        let hits: Vec<_> = (0..12).map(|i| (format!("file:{i}"), if i < 3 { 0 } else { 4 })).collect();
        seed(&history, "file:10", 100);
        seed(&history, "file:5", 99);
        let ranked = order(&history, "window", 1, &hits);
        assert_eq!(ranked[..3], hits[..3]);
        for (position, hit) in ranked.iter().enumerate() {
            let original = hits.iter().position(|item| item == hit).unwrap();
            assert!(original <= position + 2, "A result moved more than two places");
        }
        assert!(ranked.iter().position(|hit| hit.0 == "file:5").unwrap() < 5);
        assert!(ranked.iter().position(|hit| hit.0 == "file:10").unwrap() >= 8);
    }
    #[test]
    fn generation_and_pagination_share_a_frozen_signal() {
        let (history, _) = history();
        let hits: Vec<_> = ["a", "b", "c", "d"].into_iter().map(|key| (key.to_string(), 1)).collect();
        assert_eq!(order(&history, "panel", 1, &hits), hits);
        seed(&history, "c", 50);
        assert_eq!(order(&history, "panel", 1, &hits), hits);
        assert_eq!(order(&history, "panel", 2, &hits)[0].0, "c");
        assert_eq!(order(&history, "panel", 1, &hits), hits, "Older generation must not replace the snapshot");
        let mut browse = hits.clone();
        history.rank("browse", 1, "", &mut browse, |hit| hit.0.clone(), |hit| hit.1);
        assert_eq!(browse, hits, "Empty catalog browsing must stay alphabetical");
    }
    #[test]
    fn accepted_and_explicit_feedback_require_receipts_and_deduplicate() {
        let (history, path) = history();
        history.accepted("file:C:/private/report.txt");
        assert_eq!(history.info()["entries"], 0);
        let mut hits = vec![json!({"path":"C:/private/report.txt"})];
        history.decorate("window", 1, &mut hits);
        let token = hits[0]["feedbackToken"].as_str().unwrap().to_string();
        history.accepted("file:C:/private/report.txt");
        history.accepted("file:C:/private/report.txt");
        history.useful(&token).unwrap(); history.useful(&token).unwrap();
        history.decorate("window", 1, &mut hits);
        assert_eq!(hits[0]["feedbackToken"], token);
        assert_eq!(hits[0]["usefulSaved"], true);
        let entries = history.state.lock().unwrap().entries.clone();
        let entry = entries.values().next().unwrap();
        assert_eq!((entry.uses, entry.useful), (1, 1));
        assert!(history.useful(&"f".repeat(64)).is_err());
        flush(&history);
        let saved = fs::read_to_string(&path).unwrap();
        assert!(!saved.contains("private") && !saved.contains("report.txt") && !saved.contains("query"));
        let reloaded = Personalization::new(path.clone(), Options::default());
        assert_eq!(reloaded.info()["entries"], 1);
        history.configure(Options { enabled: false });
        let before = history.state.lock().unwrap().entries.clone();
        history.accepted("file:C:/private/report.txt");
        assert_eq!(history.state.lock().unwrap().entries.len(), before.len());
        assert!(history.useful(&token).is_err());
        assert!(history.clear().unwrap()["entries"] == 0);
        assert!(serde_json::from_str::<History>(&fs::read_to_string(&path).unwrap()).unwrap().entries.is_empty());
    }
    #[test]
    fn history_bounds_expiry_corruption_and_isolation() {
        let (history, path) = history();
        let mut entries = BTreeMap::new();
        for i in 0..(MAX_ENTRIES + 30) {
            entries.insert(digest(&i.to_string()), Entry { uses: 1, useful: 0, updated: now() });
        }
        entries.insert(digest("expired"), Entry { updated: now() - RETENTION - 1, ..Entry::default() });
        entries.insert("raw path".into(), Entry { updated: now(), ..Entry::default() });
        prune(&mut entries, now());
        assert_eq!(entries.len(), MAX_ENTRIES);
        assert!(!entries.contains_key(&digest("expired")) && !entries.contains_key("raw path"));
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"{damaged").unwrap();
        let recovered = Personalization::new(path, Options::default());
        assert_eq!(recovered.info()["entries"], 0);
        seed(&history, "only this index", 10);
        assert_eq!(recovered.info()["entries"], 0);
    }
    #[test]
    fn disabled_ranking_is_identical_and_reasons_preserve_evidence() {
        let (history, _) = history();
        let hits: Vec<_> = ["a", "b", "c"].into_iter().map(|key| (key.to_string(), 4)).collect();
        seed(&history, "c", 100); history.configure(Options { enabled: false });
        assert_eq!(order(&history, "window", 1, &hits), hits);
        let mut values = vec![
            json!({"resultType":"application","id":"app:1","name":"Visual Studio Code","reason":"exact","aliases":["vscode"]}),
            json!({"resultType":"windows_setting","id":"setting:display","name":"Display","reason":"semantic"}),
            json!({"path":"C:/docs/vscode.txt","keyword_rank":1,"availability":"unknown"}),
        ];
        match_sources(&mut values, "vscode");
        assert_eq!(values[0]["matchSource"], "alias");
        assert_eq!(values[1]["matchSource"], "purpose");
        assert_eq!(values[2]["matchSource"], "name");
        assert_eq!(values[2]["availability"], "unknown");
    }
}
