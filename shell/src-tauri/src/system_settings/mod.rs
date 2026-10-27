//! A bounded, curated list of Windows destinations, independent of the file/model helper.
use crate::applications::{digest,rank};
use serde::{Deserialize,Serialize};
use serde_json::{json,Value};
use std::{collections::{BTreeMap,HashSet},path::PathBuf,sync::{Arc,Mutex,RwLock,atomic::{AtomicBool,Ordering}},time::{Duration,Instant}};
#[cfg(windows)]mod control_panel;

#[derive(Clone,Debug,Serialize,Deserialize)]
#[serde(default,rename_all="camelCase")]
pub struct Options {pub enabled:bool,pub semantic_enabled:bool,pub ordinary_searches:bool}
impl Default for Options {
    fn default()->Self {Self{enabled:cfg!(windows),semantic_enabled:true,ordinary_searches:true}}
}
#[derive(Clone,Debug)]
pub struct Platform {pub supported:bool,pub build:u32,pub locale:String,pub wifi:Option<bool>,pub bluetooth:Option<bool>}
impl Platform {
    pub fn current()->Self {
        #[cfg(windows)] {return native::platform();}
        #[cfg(not(windows))] {Self{supported:false,build:0,locale:"en".into(),wifi:None,bluetooth:None}}
    }
}
#[derive(Clone,Debug,Serialize,Deserialize)]
#[serde(rename_all="camelCase")]
struct Entry {
    key:String,name:String,description:String,uri:String,hardware:String,aliases:Vec<String>,
    #[serde(default)]native:Option<NativeTarget>,
    #[serde(default)]source:String,
    #[serde(default)]canonical:String,
    min_build:u32,#[serde(default)]max_build:Option<u32>,
    #[serde(default)]translations:BTreeMap<String,String>,
}
#[derive(Clone,Debug,Serialize,Deserialize)]
#[serde(tag="type",rename_all="snake_case")]
enum NativeTarget { Shell{parsing:String}, Canonical{name:String,page:String} }
#[derive(Clone,Debug,Default,Serialize,Deserialize)]
struct Source { entries:Vec<Entry>, #[serde(default)]error:Option<String> }
#[derive(Serialize,Deserialize)]
struct Cache {version:u32,build:u32,locale:String,sources:BTreeMap<String,Source>}
#[derive(Deserialize)]
struct Manifest {version:u32,entries:Vec<Entry>}
#[derive(Clone,Debug,Serialize)]
#[serde(rename_all="camelCase")]
pub struct Hit {
    pub id:String,pub result_type:String,pub kind:String,pub name:String,pub description:String,
    pub publisher:String,pub aliases:Vec<String>,pub reason:String,pub availability:String,
    pub source:String,
    #[serde(skip)]tier:u8,
}
#[derive(Clone)]
pub struct Catalog {
    platform:Platform,entries:Vec<Entry>,options:Arc<RwLock<Options>>,launching:Arc<Mutex<HashSet<String>>>,
    sources:Arc<RwLock<BTreeMap<String,Source>>>,refreshing:Arc<AtomicBool>,watch_started:Arc<AtomicBool>,
    cache:Arc<Mutex<Option<PathBuf>>>,last_refresh:Arc<Mutex<Option<Instant>>>,
    changed:Arc<dyn Fn(Value)+Send+Sync>,
}
impl Catalog {
    pub fn new(options:Options)->Self {Self::with_platform(options,Platform::current())}
    pub fn with_platform(options:Options,platform:Platform)->Self {
        let manifest:Manifest=serde_json::from_str(include_str!("catalog.json")).expect("validated built-in settings catalog");
        assert_eq!(manifest.version,1);
        Self{platform,entries:manifest.entries,options:Arc::new(RwLock::new(options)),launching:Arc::new(Mutex::new(HashSet::new())),
            sources:Arc::new(RwLock::new(BTreeMap::new())),refreshing:Arc::new(AtomicBool::new(false)),watch_started:Arc::new(AtomicBool::new(false)),
            cache:Arc::new(Mutex::new(None)),last_refresh:Arc::new(Mutex::new(None)),changed:Arc::new(|_|{})}
    }
    pub fn configure(&self,options:Options){*self.options.write().unwrap()=options;if self.options.read().unwrap().enabled{self.refresh_if_stale();}}
    pub fn attach(&mut self,path:PathBuf,changed:impl Fn(Value)+Send+Sync+'static) {
        self.changed=Arc::new(changed);
        if let Ok(bytes)=std::fs::read(&path) {
            if bytes.len()<=8_000_000 {
                if let Ok(cache)=serde_json::from_slice::<Cache>(&bytes) {
                    if cache.version==1&&cache.build==self.platform.build&&cache.locale==self.platform.locale {
                        *self.sources.write().unwrap()=cache.sources;
                    }
                }
            }
        }
        *self.cache.lock().unwrap()=Some(path);
    }
    fn all_entries(&self)->Vec<Entry>{
        let mut entries=self.entries.clone();
        let sources=self.sources.read().unwrap();
        let mut identities=HashSet::new();
        for source in sources.values(){for e in &source.entries {
            let identity=serde_json::to_string(&e.native).unwrap_or_default();
            if identities.insert(identity){entries.push(e.clone())}
        }}
        entries
    }
    fn publish(&self,source:&str,result:Result<Vec<Entry>,String>){
        let mut sources=self.sources.write().unwrap();
        match result {
            Ok(entries)=>{sources.insert(source.into(),Source{entries,error:None});},
            Err(error)=>{sources.entry(source.into()).or_default().error=Some(error);}
        }
        drop(sources);
        if let Some(path)=self.cache.lock().unwrap().clone(){
            let cache=Cache{version:1,build:self.platform.build,locale:self.platform.locale.clone(),sources:self.sources.read().unwrap().clone()};
            if let Ok(bytes)=serde_json::to_vec(&cache){
                if let Some(parent)=path.parent(){let _=std::fs::create_dir_all(parent);}
                let tmp=path.with_extension("json.new");
                if std::fs::write(&tmp,bytes).is_ok(){let _=std::fs::rename(tmp,path);}
            }
        }
        (self.changed)(self.info());
    }
    fn fallback_tasks(&self)->Vec<Entry>{
        let parents=self.sources.read().unwrap().get("control_panel").map(|s|s.entries.clone()).unwrap_or_default();
        [("Microsoft.PowerOptions","pagePlanSettings","Edit power plan"),("Microsoft.PowerOptions","pageGlobalSettings","Power button settings"),
         ("Microsoft.Mouse","1","Mouse pointers"),("Microsoft.Mouse","2","Pointer options"),("Microsoft.InternetOptions","6","Advanced Internet options")]
        .into_iter().filter(|(name,_,_)|parents.iter().any(|e|e.canonical==*name)).map(|(name,page,title)|Entry{
            key:format!("control-panel-{}",digest(&format!("{name}:{page}"))),name:title.into(),description:format!("Open {title} in Control Panel."),
            uri:String::new(),hardware:String::new(),aliases:vec![format!("control panel {title}")],min_build:19041,max_build:None,translations:Default::default(),
            source:"documented_tasks".into(),canonical:name.into(),native:Some(NativeTarget::Canonical{name:name.into(),page:page.into()})
        }).collect()
    }
    pub fn start(&self){
        #[cfg(windows)]if !self.watch_started.swap(true,Ordering::SeqCst){control_panel::watch(self.clone());}
        self.refresh_if_stale();
    }
    pub fn refresh_if_stale(&self){
        if self.last_refresh.lock().unwrap().is_none_or(|stamp|stamp.elapsed()>Duration::from_secs(300)){self.refresh();}
    }
    pub fn refresh(&self){
        if !self.platform.supported||!self.options.read().unwrap().enabled||self.refreshing.swap(true,Ordering::SeqCst){return}
        let catalog=self.clone();
        std::thread::spawn(move||{
            #[cfg(windows)]
            for source in ["control_panel","control_panel_task"]{
                if !catalog.options.read().unwrap().enabled {break}
                let result=control_panel::discover(source);
                if source=="control_panel_task"&&result.is_err(){
                    catalog.publish(source,Err(result.unwrap_err()));
                    catalog.publish("documented_tasks",Ok(catalog.fallback_tasks()));
                }else{catalog.publish(source,result);if source=="control_panel_task"{catalog.publish("documented_tasks",Ok(vec![]));}}
            }
            *catalog.last_refresh.lock().unwrap()=Some(Instant::now());
            catalog.refreshing.store(false,Ordering::SeqCst);
            (catalog.changed)(catalog.info());
        });
    }
    pub fn semantic_enabled(&self)->bool {
        let o=self.options.read().unwrap();self.platform.supported&&o.enabled&&o.semantic_enabled
    }
    fn available(&self,e:&Entry)->bool {
        self.platform.supported&&self.platform.build>=e.min_build
            &&e.max_build.is_none_or(|b|self.platform.build<=b)
            && match e.hardware.as_str() {"wifi"=>self.platform.wifi!=Some(false),"bluetooth"=>self.platform.bluetooth!=Some(false),_=>true}
    }
    fn hit(&self,e:&Entry)->Hit {
        let language=self.platform.locale.split('-').next().unwrap_or("en");
        let name=e.translations.get(language).unwrap_or(&e.name).clone();
        let mut aliases=e.aliases.clone();
        if name!=e.name {aliases.push(e.name.clone())}
        Hit{id:format!("setting:{}",e.key),result_type:"windows_setting".into(),kind:"windows_setting".into(),
            name,description:e.description.clone(),publisher:if e.native.is_some(){"Control Panel"}else{"Windows"}.into(),aliases,reason:"catalog".into(),
            source:if e.native.is_some(){"control_panel"}else{"windows_settings"}.into(),
            availability:if (!e.hardware.is_empty()) && match e.hardware.as_str(){
                "wifi"=>self.platform.wifi.is_none(),"bluetooth"=>self.platform.bluetooth.is_none(),_=>false}
                {"unknown"}else{"available"}.into(),tier:0}
    }
    pub fn search(&self,q:&str)->Vec<Hit> {
        if !self.options.read().unwrap().enabled {return vec![]}
        let q=rank::normalized(q);
        let mut hits:Vec<Hit>=self.all_entries().iter().filter(|e|self.available(e)).filter_map(|e|{
            let mut h=self.hit(e);
            let aliases=h.aliases.iter().map(|a|rank::normalized(a)).collect::<Vec<_>>();
            rank::lexical(&q,&rank::normalized(&h.name),&aliases).map(|(tier,reason)|{h.tier=tier;h.reason=reason.into();h})
        }).collect();
        hits.sort_by(|a,b|a.tier.cmp(&b.tier).then_with(||rank::normalized(&a.name).cmp(&rank::normalized(&b.name))).then_with(||a.id.cmp(&b.id)));
        hits
    }
    pub fn merge(&self,mut lexical:Vec<Hit>,semantic:&[Value])->Vec<Hit> {
        if !self.semantic_enabled(){return lexical}
        let existing:HashSet<_>=lexical.iter().map(|h|h.id.clone()).collect();
        for row in semantic {
            let Some(id)=row["id"].as_str() else{continue};
            if existing.contains(id)||lexical.iter().any(|h|h.id==id){continue}
            if let Some(e)=self.all_entries().into_iter().find(|e|format!("setting:{}",e.key)==id&&self.available(e)) {
                let mut h=self.hit(&e);h.tier=4;h.reason="semantic".into();lexical.push(h);
            }
        }
        lexical
    }
    pub fn revision(&self)->String {digest(&serde_json::to_string(&self.search("")).unwrap())}
    pub fn info(&self)->Value {
        let o=self.options.read().unwrap().clone();
        let hits=self.search("");let revision=digest(&serde_json::to_string(&hits).unwrap());
        json!({"version":1,"supported":self.platform.supported,"enabled":o.enabled,
            "semanticEnabled":o.semantic_enabled,"ordinarySearches":o.ordinary_searches,
            "count":hits.len(),"total":hits.len(),"revision":revision,
            "locale":self.platform.locale,"windowsBuild":self.platform.build,
            "refreshing":self.refreshing.load(Ordering::SeqCst),
            "controlPanel":self.sources.read().unwrap().iter().map(|(name,source)|(name.clone(),json!({"count":source.entries.len(),"error":source.error,"stale":source.error.is_some()}))).collect::<BTreeMap<_,_>>()})
    }
    pub fn documents(&self)->Value {
        let hits=self.search("");let revision=digest(&serde_json::to_string(&hits).unwrap());
        let documents:Vec<Value>=if self.semantic_enabled(){hits.into_iter().map(|h|{
            let text=format!("Windows settings: {}\nPurpose: {}\nAliases: {}",h.name,h.description,h.aliases.join(", "));
            json!({"id":h.id,"name":h.name,"hash":digest(&text),"text":text})
        }).collect()}else{vec![]};
        json!({"revision":revision,"documents":documents})
    }
    pub fn icon_path(&self,id:&str,size:u32)->Result<PathBuf,String>{
        let e=self.all_entries().into_iter().find(|e|format!("setting:{}",e.key)==id&&self.available(e)).ok_or("This item is unavailable.")?;
        let Some(NativeTarget::Shell{parsing})=e.native else{return Err("Use the generic settings icon.".into())};
        let base=self.cache.lock().unwrap().clone().ok_or("Icon cache is unavailable.")?;
        let folder=base.parent().ok_or("Icon cache is unavailable.")?.join("icons");
        std::fs::create_dir_all(&folder).map_err(|e|e.to_string())?;
        let size=size.clamp(16,128);let path=folder.join(format!("{}-{size}.png",digest(&parsing)));
        if path.is_file(){return Ok(path)}
        #[cfg(windows)]{let temporary=folder.join(format!("{}-{}-{size}.png",digest(&parsing),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos()));
            crate::applications::shell_icon(&parsing,size,&temporary)?;
            if let Err(error)=std::fs::rename(&temporary,&path){let _=std::fs::remove_file(&temporary);if !path.is_file(){return Err(error.to_string())}}
            Ok(path)}
        #[cfg(not(windows))]{Err("Native icons require Windows.".into())}
    }
    pub fn launch(&self,id:&str)->Result<(),String> {
        if !self.options.read().unwrap().enabled{return Err("Windows settings search is disabled.".into())}
        let e=self.all_entries().into_iter().find(|e|format!("setting:{}",e.key)==id&&self.available(e))
            .ok_or("This Windows settings page is unavailable.")?;
        if !self.launching.lock().unwrap().insert(id.into()){return Err("This settings page is already opening.".into())}
        #[cfg(windows)]let result=match &e.native {Some(target)=>control_panel::open(target),None=>native::open(&e.uri)};
        #[cfg(not(windows))]let result={let _=e;Err("Windows settings are available on Windows.".into())};
        self.launching.lock().unwrap().remove(id);result
    }
}
#[cfg(windows)]mod native {
    use super::Platform;
    use windows::{core::PCWSTR,Win32::{System::Com::{CoInitializeEx,CoUninitialize,COINIT_APARTMENTTHREADED},UI::{Shell::{ShellExecuteExW,SHELLEXECUTEINFOW,SEE_MASK_NOASYNC,SEE_MASK_FLAG_NO_UI},WindowsAndMessaging::SW_SHOWNORMAL}}};
    #[repr(C)]struct Version {size:u32,major:u32,minor:u32,build:u32,platform:u32,service_pack:[u16;128]}
    #[link(name="ntdll")]unsafe extern "system" {fn RtlGetVersion(v:*mut Version)->i32;}
    #[link(name="kernel32")]unsafe extern "system" {fn GetUserDefaultUILanguage()->u16;}
    pub fn platform()->Platform {
        let mut v=Version{size:std::mem::size_of::<Version>()as u32,major:0,minor:0,build:0,platform:0,service_pack:[0;128]};
        let ok=unsafe{RtlGetVersion(&mut v)}>=0;
        let language=unsafe{GetUserDefaultUILanguage()}&0x3ff;
        Platform{supported:ok&&v.major>=10,build:v.build,locale:if language==1{"ar"}else{"en"}.into(),wifi:None,bluetooth:None}
    }
    pub fn open(uri:&str)->Result<(),String> {
        // Only built-in catalog entries reach this function.
        let wide:Vec<u16>=uri.encode_utf16().chain(Some(0)).collect();
        let verb:Vec<u16>="open".encode_utf16().chain(Some(0)).collect();
        let initialized=unsafe{CoInitializeEx(None,COINIT_APARTMENTTHREADED)}.is_ok();
        let mut info=SHELLEXECUTEINFOW{cbSize:std::mem::size_of::<SHELLEXECUTEINFOW>()as u32,
            fMask:SEE_MASK_NOASYNC|SEE_MASK_FLAG_NO_UI,lpVerb:PCWSTR(verb.as_ptr()),
            lpFile:PCWSTR(wide.as_ptr()),nShow:SW_SHOWNORMAL.0,..Default::default()};
        let result=unsafe{ShellExecuteExW(&mut info)}.map_err(|e|format!("Windows could not open this settings page: {e}"));
        if initialized {unsafe{CoUninitialize()}}result
    }
}
#[cfg(test)]mod tests {
    use super::*;
    fn catalog()->Catalog {Catalog::with_platform(Options{enabled:true,..Options::default()},
        Platform{supported:true,build:22631,locale:"en".into(),wifi:Some(false),bluetooth:Some(true)})}
    #[test]fn curated_uris_ids_and_metadata_are_valid() {
        let c=catalog();let mut ids=HashSet::new();let mut uris=HashSet::new();
        for e in &c.entries {assert!(ids.insert(&e.key));assert!(uris.insert(&e.uri));
            assert!(e.uri.starts_with("ms-settings:"));assert!(!e.uri.contains([' ','\0','?','#']));
            assert!(e.key.bytes().all(|b|b.is_ascii_lowercase()||b==b'-'));
            assert!(!e.description.is_empty());assert!(e.min_build>=19041);}
    }
    #[test]fn exact_alias_unicode_and_hardware_filters() {
        let c=catalog();assert_eq!(c.search("Bluetooth")[0].reason,"exact");
        assert!(c.search("wifi").is_empty());assert_eq!(c.search("بلوتوث")[0].id,"setting:bluetooth");
        assert!(c.launch("ms-settings:display").is_err());
        assert!(c.search("unrelated financial spreadsheet").is_empty());
    }
    #[test]fn annotations_and_lexical_work_do_not_require_a_helper() {
        let c=catalog();let before=c.documents();assert!(!before["documents"].as_array().unwrap().is_empty());
        c.configure(Options{enabled:true,semantic_enabled:false,ordinary_searches:true});
        assert!(c.documents()["documents"].as_array().unwrap().is_empty());
        assert!(!c.search("display").is_empty());
        c.configure(Options{enabled:false,..Options::default()});assert!(c.search("").is_empty());
    }
}

#[cfg(test)]mod control_panel_contracts{
    use super::*;
    fn entry(parsing:&str,name:&str)->Entry{Entry{key:format!("control-panel-{}",digest(parsing)),name:name.into(),description:"Classic sound devices".into(),uri:String::new(),hardware:String::new(),
        aliases:vec![format!("classic {name}")],min_build:19041,max_build:None,translations:Default::default(),source:"control_panel".into(),canonical:String::new(),
        native:Some(NativeTarget::Shell{parsing:parsing.into()})}}
    fn catalog()->Catalog{Catalog::with_platform(Options{enabled:true,semantic_enabled:false,ordinary_searches:true},
        Platform{supported:true,build:22631,locale:"en".into(),wifi:None,bluetooth:None})}
    #[test]fn exact_modern_and_classic_names_are_distinct_and_partial_refresh_retains_entries(){
        let c=catalog();c.publish("control_panel",Ok(vec![entry("::{fixture}","Sound")]));
        let hits=c.search("Sound");assert_eq!(hits.iter().filter(|h|h.name=="Sound").count(),2);assert_ne!(hits[0].id,hits[1].id);assert!(hits.iter().any(|h|h.source=="control_panel"));
        c.publish("control_panel",Err("Temporary Shell failure".into()));assert_eq!(c.search("classic Sound").len(),1);
        assert!(c.info()["controlPanel"]["control_panel"]["stale"].as_bool().unwrap());
        c.publish("control_panel",Ok(vec![]));assert_eq!(c.search("Sound").iter().filter(|h|h.name=="Sound").count(),1);
    }
    #[test]fn duplicate_shell_identity_is_merged_without_losing_distinct_tasks(){
        let c=catalog();c.publish("control_panel",Ok(vec![entry("::{one}","Sound")]));
        c.publish("control_panel_task",Ok(vec![entry("::{one}","Sound"),entry("::{two}","Manage sound")]));
        assert_eq!(c.search("").iter().filter(|h|h.source=="control_panel").count(),2);
        assert!(c.launch("control.exe /name Microsoft.Sound").is_err());
    }
}
