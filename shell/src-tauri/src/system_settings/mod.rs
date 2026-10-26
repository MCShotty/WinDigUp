//! A bounded, curated list of Windows destinations, independent of the file/model helper.
use crate::applications::{digest,rank};
use serde::{Deserialize,Serialize};
use serde_json::{json,Value};
use std::{collections::{BTreeMap,HashSet},sync::{Mutex,RwLock}};

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
#[derive(Clone,Debug,Deserialize)]
#[serde(rename_all="camelCase")]
struct Entry {
    key:String,name:String,description:String,uri:String,hardware:String,aliases:Vec<String>,
    min_build:u32,#[serde(default)]max_build:Option<u32>,
    #[serde(default)]translations:BTreeMap<String,String>,
}
#[derive(Deserialize)]
struct Manifest {version:u32,entries:Vec<Entry>}
#[derive(Clone,Debug,Serialize)]
#[serde(rename_all="camelCase")]
pub struct Hit {
    pub id:String,pub result_type:String,pub kind:String,pub name:String,pub description:String,
    pub publisher:String,pub aliases:Vec<String>,pub reason:String,pub availability:String,
    #[serde(skip)]tier:u8,
}
pub struct Catalog {
    platform:Platform,entries:Vec<Entry>,options:RwLock<Options>,launching:Mutex<HashSet<String>>,
}
impl Catalog {
    pub fn new(options:Options)->Self {Self::with_platform(options,Platform::current())}
    pub fn with_platform(options:Options,platform:Platform)->Self {
        let manifest:Manifest=serde_json::from_str(include_str!("catalog.json")).expect("validated built-in settings catalog");
        assert_eq!(manifest.version,1);
        Self{platform,entries:manifest.entries,options:RwLock::new(options),launching:Mutex::new(HashSet::new())}
    }
    pub fn configure(&self,options:Options){*self.options.write().unwrap()=options}
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
            name,description:e.description.clone(),publisher:"Windows".into(),aliases,reason:"catalog".into(),
            availability:if (!e.hardware.is_empty()) && match e.hardware.as_str(){
                "wifi"=>self.platform.wifi.is_none(),"bluetooth"=>self.platform.bluetooth.is_none(),_=>false}
                {"unknown"}else{"available"}.into(),tier:0}
    }
    pub fn search(&self,q:&str)->Vec<Hit> {
        if !self.options.read().unwrap().enabled {return vec![]}
        let q=rank::normalized(q);
        let mut hits:Vec<Hit>=self.entries.iter().filter(|e|self.available(e)).filter_map(|e|{
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
            if let Some(e)=self.entries.iter().find(|e|format!("setting:{}",e.key)==id&&self.available(e)) {
                let mut h=self.hit(e);h.tier=4;h.reason="semantic".into();lexical.push(h);
            }
        }
        lexical
    }
    pub fn revision(&self)->String {digest(&serde_json::to_string(&self.search("")).unwrap())}
    pub fn info(&self)->Value {
        let o=self.options.read().unwrap().clone();
        json!({"version":1,"supported":self.platform.supported,"enabled":o.enabled,
            "semanticEnabled":o.semantic_enabled,"ordinarySearches":o.ordinary_searches,
            "count":self.search("").len(),"total":self.search("").len(),"revision":self.revision(),"refreshing":false,
            "locale":self.platform.locale,"windowsBuild":self.platform.build})
    }
    pub fn documents(&self)->Value {
        let documents:Vec<Value>=if self.semantic_enabled(){self.search("").into_iter().map(|h|{
            let text=format!("Windows settings: {}\nPurpose: {}\nAliases: {}",h.name,h.description,h.aliases.join(", "));
            json!({"id":h.id,"name":h.name,"hash":digest(&text),"text":text})
        }).collect()}else{vec![]};
        json!({"revision":self.revision(),"documents":documents})
    }
    pub fn launch(&self,id:&str)->Result<(),String> {
        if !self.options.read().unwrap().enabled{return Err("Windows settings search is disabled.".into())}
        let e=self.entries.iter().find(|e|format!("setting:{}",e.key)==id&&self.available(e))
            .ok_or("This Windows settings page is unavailable.")?;
        if !self.launching.lock().unwrap().insert(id.into()){return Err("This settings page is already opening.".into())}
        #[cfg(windows)]let result=native::open(&e.uri);
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
