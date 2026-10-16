//! User-process metadata preparation. Two bounded HTTP jobs; searching never waits on this actor.
use crate::{applications::{Catalog,digest,enrichment::{self,Description,Options,Package}},discovery::db::{Database,Value as Sql}};
use serde_json::{json,Value};
use std::{collections::{BTreeMap,HashMap,HashSet},path::PathBuf,sync::{Arc,Mutex,RwLock,atomic::{AtomicBool,Ordering}},time::{Duration,Instant}};

struct Cache {db:Database}
impl Cache {
    fn open(file:&std::path::Path)->Result<Self,String>{
        let db=Database::open(file,false)?;
        let version=db.rows("PRAGMA user_version",&[])?.first().and_then(|r|r[0].parse::<u32>().ok()).unwrap_or(0);
        if version>1{return Err("Description cache was created by a newer DigUp version.".into())}
        db.run("PRAGMA journal_mode=WAL",&[])?;
        db.run("CREATE TABLE IF NOT EXISTS products(key TEXT PRIMARY KEY,record TEXT NOT NULL,retry INTEGER NOT NULL,error TEXT NOT NULL)",&[])?;
        db.run("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",&[])?;
        db.run("PRAGMA user_version=1",&[])?;
        Ok(Self{db})
    }
    fn recovering(file:&std::path::Path)->Result<Self,String>{
        match Self::open(file){
            Ok(db)=>Ok(db),
            Err(error)if error.contains("not a database")||error.contains("malformed")=>{
                for suffix in ["","-wal","-shm"]{let path=PathBuf::from(format!("{}{suffix}",file.display()));
                    if path.is_file(){std::fs::remove_file(path).map_err(|e|e.to_string())?;}}
                Self::open(file)
            },
            Err(error)=>Err(error),
        }
    }
    fn errors(&self)->Result<BTreeMap<String,String>,String>{Ok(self.db.rows("SELECT key,error FROM products WHERE error!=''",&[])?.into_iter().map(|r|(r[0].clone(),r[1].clone())).collect())}
    fn retry_all(&self)->Result<(),String>{self.db.run("UPDATE products SET retry=0",&[])}
    fn descriptions(&self)->Result<Vec<Description>,String>{
        self.db.rows("SELECT record FROM products WHERE record!='' AND length(record)<=65536 LIMIT 5000",&[])?.into_iter()
            .map(|r|serde_json::from_str(&r[0]).map_err(|e|e.to_string())).collect()
    }
    fn inventory(&self)->Result<Vec<Package>,String>{
        self.db.rows("SELECT value FROM metadata WHERE key='inventory'",&[])?.first()
            .map(|r|serde_json::from_str(&r[0]).map_err(|e|e.to_string())).transpose().map(|v|v.unwrap_or_default())
    }
    fn save_inventory(&self,inventory:&[Package])->Result<(),String>{
        let text=serde_json::to_string(inventory).map_err(|e|e.to_string())?;
        self.db.run("INSERT INTO metadata VALUES('inventory',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",&[Sql::Text(&text)])
    }
    fn key(p:&Package)->String{digest(&format!("{}|{}|{}",p.id,p.version,enrichment::EXTRACTOR_VERSION))}
    fn due(&self,p:&Package)->Result<bool,String>{
        Ok(self.db.rows("SELECT retry FROM products WHERE key=?",&[Sql::Text(&Self::key(p))])?.first()
            .is_none_or(|r|r[0].parse::<u64>().unwrap_or(0)<=enrichment::now()))
    }
    fn save(&self,p:&Package,result:&Result<Description,String>)->Result<(),String>{
        match result{
            Ok(record)=>{
                let text=serde_json::to_string(record).map_err(|e|e.to_string())?;
                self.db.run("INSERT INTO products VALUES(?,?,?,'') ON CONFLICT(key) DO UPDATE SET record=excluded.record,retry=excluded.retry,error=''",
                    &[Sql::Text(&Self::key(p)),Sql::Text(&text),Sql::Integer((enrichment::now()+7*86400)as i64)])
            },
            Err(error)=>self.db.run("INSERT INTO products VALUES(?,'',?,?) ON CONFLICT(key) DO UPDATE SET retry=excluded.retry,error=excluded.error",
                &[Sql::Text(&Self::key(p)),Sql::Integer((enrichment::now()+3600)as i64),Sql::Text(error)]),
        }
    }
    fn clear(&self)->Result<(),String>{
        self.db.run("DELETE FROM products",&[])?;self.db.run("DELETE FROM metadata",&[])
    }
}
pub struct Manager {
    root:PathBuf,apps:Arc<Catalog>,options:RwLock<Options>,state:RwLock<Value>,last_foreground:Mutex<Instant>,
    cancel:AtomicBool,wake:AtomicBool,clear:AtomicBool,refresh:AtomicBool,notify:Arc<dyn Fn(Value)+Send+Sync>,
}
impl Manager {
    pub fn new(root:PathBuf,apps:Arc<Catalog>,options:Options,notify:impl Fn(Value)+Send+Sync+'static)->Arc<Self>{
        Arc::new(Self{root,apps,options:RwLock::new(options),state:RwLock::new(json!({"version":1,"state":"disabled","productsTotal":null,"enriched":0})),
            last_foreground:Mutex::new(Instant::now().checked_sub(Duration::from_secs(5)).unwrap_or_else(Instant::now)),cancel:AtomicBool::new(false),
            wake:AtomicBool::new(true),clear:AtomicBool::new(false),refresh:AtomicBool::new(false),notify:Arc::new(notify)})
    }
    pub fn info(&self)->Value{json!({"version":1,"options":self.options.read().unwrap().clone(),"progress":self.state.read().unwrap().clone()})}
    fn update(&self,mut state:Value){
        let mut current=self.state.write().unwrap();
        let mut previous=current.clone();if let Some(object)=previous.as_object_mut(){object.remove("lastProgressAt");}
        if previous==state{return}
        state["lastProgressAt"]=json!(enrichment::now());*current=state;drop(current);(self.notify)(self.info());
    }
    pub fn configure(&self,options:Options){*self.options.write().unwrap()=options;self.wake.store(true,Ordering::SeqCst);}
    pub fn retry(&self){self.refresh.store(true,Ordering::SeqCst);self.wake.store(true,Ordering::SeqCst);}
    pub fn clear(&self){self.apps.enrich(BTreeMap::new());self.clear.store(true,Ordering::SeqCst);self.wake.store(true,Ordering::SeqCst);}
    pub fn stop(&self){self.cancel.store(true,Ordering::SeqCst);}
    pub fn foreground(&self){*self.last_foreground.lock().unwrap()=Instant::now();}
    fn quiet(&self)->bool{self.last_foreground.lock().unwrap().elapsed()>=Duration::from_secs(1)}
    pub fn start(self:&Arc<Self>){
        let weak=Arc::downgrade(self);
        std::thread::spawn(move||{
            let mut cache:Option<Cache>=None;let mut inventory:Vec<Package>=vec![];
            let mut last_inventory=Instant::now();
            let mut applied=String::new();let mut checked=0u64;let mut errors=BTreeMap::<String,String>::new();
            let mut inventory_error:Option<String>=None;let mut clear_failed=false;let mut cleared=false;
            let mut work=HashSet::new();let mut disabled_epoch=0u64;
            let(tx,rx)=std::sync::mpsc::sync_channel::<(Package,bool,u64)>(4);
            let jobs=Arc::new(Mutex::new(rx));
            let(done_tx,done_rx)=std::sync::mpsc::sync_channel::<(Package,Result<Description,String>,u64)>(4);
            for _ in 0..2{
                let jobs=jobs.clone();let done=done_tx.clone();let manager=weak.clone();
                std::thread::spawn(move||loop{
                    let job=match jobs.lock().unwrap().recv(){Ok(job)=>job,Err(_)=>break};
                    let Some(manager)=manager.upgrade()else{break};
                    if manager.cancel.load(Ordering::SeqCst){break}
                    let result=if manager.options.read().unwrap().enabled&&manager.apps.enabled(){enrichment::fetch_package_with_policy(&job.0,job.1,&||manager.options.read().unwrap().enabled&&manager.apps.enabled()&&!manager.cancel.load(Ordering::SeqCst))}
                        else{Err("Online descriptions are disabled.".into())};
                    let _=done.send((job.0,result,job.2));
                });
            }
            drop(done_tx);
            loop{
                std::thread::sleep(Duration::from_millis(250));
                let Some(manager)=weak.upgrade()else{break};
                if manager.cancel.load(Ordering::SeqCst){break}
                let options=manager.options.read().unwrap().clone();
                let file=manager.root.join("enrichment.sqlite");
                if cache.is_none()&&(options.enabled||file.is_file()){
                    if let Err(error)=std::fs::create_dir_all(&manager.root).map_err(|e|e.to_string()){
                        manager.update(json!({"version":1,"state":"unavailable","message":error,"productsTotal":null}));continue;
                    }
                    match Cache::recovering(&file){
                        Ok(db)=>{inventory=db.inventory().unwrap_or_default();errors=db.errors().unwrap_or_default();cache=Some(db);},
                        Err(error)=>{manager.update(json!({"version":1,"state":"unavailable","message":error,"productsTotal":null}));continue},
                    }
                }
                let clear=manager.clear.swap(false,Ordering::SeqCst);
                if clear{
                    clear_failed=false;cleared=false;disabled_epoch+=1;work.clear();inventory.clear();checked=0;errors.clear();inventory_error=None;
                    if let Some(db)=&cache{if let Err(error)=db.clear(){
                        clear_failed=true;manager.update(json!({"version":1,"state":"unavailable","message":format!("Saved descriptions could not be cleared: {error}. Close other readers and try Turn off and clear again."),"enriched":0}));continue;
                    }}
                    cleared=true;manager.apps.enrich(BTreeMap::new());applied.clear();
                }
                if clear_failed{continue}
                while let Ok((package,result,epoch))=done_rx.try_recv(){
                    work.remove(&Cache::key(&package));
                    if epoch!=disabled_epoch{continue}
                    if let Some(db)=&cache{if let Err(error)=db.save(&package,&result){errors.insert("cache".into(),error);}}
                    checked+=1;match result{Ok(_)=>{errors.remove(&Cache::key(&package));},Err(error)=>{errors.insert(Cache::key(&package),error);}}
                }
                if !manager.quiet()&&!clear{continue}
                if manager.refresh.swap(false,Ordering::SeqCst){if let Some(db)=&cache{let _=db.retry_all();}}
                if let Some(db)=&cache{
                    let records=manager.apps.records();
                    let native=records.iter().map(|r|format!("{}|{}|{}|{}",r.id,r.name,r.product,r.publisher)).collect::<Vec<_>>().join("\n");
                    let descriptions=match db.descriptions(){
                        Ok(descriptions)=>{errors.remove("cache-records");descriptions},
                        Err(error)=>{
                            errors.insert("cache-records".into(),error.clone());
                            manager.update(json!({"version":1,"state":"unavailable","message":format!("Saved description data could not be read: {error}. Use Turn off and clear to rebuild this cache."),
                                "enriched":manager.apps.enriched_count(),"productsTotal":inventory.len()}));continue
                        }
                    };
                    let inventory_keys=inventory.iter().map(Cache::key).collect::<HashSet<_>>();
                    let mut by_name:HashMap<String,Vec<&crate::applications::Record>>=HashMap::new();
                    for record in &records{
                        for name in [&record.name,&record.product]{
                            if !name.is_empty(){by_name.entry(enrichment::key(name,&record.publisher)).or_default().push(record);}
                        }
                    }
                    let mut proposed=BTreeMap::new();
                    let mut ambiguous=HashSet::new();
                    for description in descriptions.iter().filter(|d|d.extractor_version==enrichment::EXTRACTOR_VERSION
                        &&inventory_keys.contains(&Cache::key(&Package{id:d.package_id.clone(),version:d.package_version.clone()}))){
                        if let Some(records)=by_name.get(&enrichment::key(&description.name,&description.publisher)){
                            for record in records.iter().filter(|r|enrichment::matches(r,description)){
                                if let Some(existing)=proposed.get(&record.id){
                                    let existing:&Description=existing;
                                    if existing.package_id!=description.package_id||existing.package_version!=description.package_version{
                                        ambiguous.insert(record.id.clone());
                                    }
                                }else{proposed.insert(record.id.clone(),description.clone());}
                            }
                        }
                    }
                    for id in ambiguous{proposed.remove(&id);}
                    let effective=proposed.iter().map(|(id,d)|format!("{id}|{}|{}|{}|{}|{}",d.description,d.tags.join("|"),d.source,d.url,d.package_version)).collect::<Vec<_>>().join("\n");
                    let signature=digest(&format!("{native}\n{effective}"));
                    if signature!=applied{manager.apps.enrich(proposed);applied=signature;}
                }
                let requested=manager.wake.swap(false,Ordering::SeqCst);
                if !options.enabled{
                    manager.update(json!({"version":1,"state":"disabled","cachedDescriptionsAvailable":true,"cleared":cleared,"enriched":manager.apps.enriched_count(),
                        "productsTotal":inventory.len(),"productsChecked":checked,"failedProducts":errors.len(),"message":inventory_error.clone().or_else(||errors.values().next().cloned())}));
                    continue;
                }
                cleared=false;
                if !manager.quiet()||!manager.apps.enabled(){continue}
                if last_inventory.elapsed()>Duration::from_secs(86400)||requested{
                    manager.update(json!({"version":1,"state":"inventory","enriched":manager.apps.enriched_count(),"productsTotal":null}));
                    last_inventory=Instant::now();
                    match export_inventory(&manager.root,&manager.cancel){
                        Ok(products)=>{
                            inventory=products;inventory_error=None;if let Some(db)=&cache{let _=db.save_inventory(&inventory);}
                        },
                        Err(error)=>{
                            manager.update(json!({"version":1,"state":"unavailable","message":error,"enriched":manager.apps.enriched_count(),"productsTotal":null}));
                            inventory_error=Some(error);
                            continue;
                        }
                    }
                }
                if let Some(db)=&cache{
                    for package in &inventory{
                        if work.len()>=2{break}
                        let key=Cache::key(package);
                        if !work.contains(&key)&&db.due(package).unwrap_or(false){
                            if tx.try_send((package.clone(),options.publisher_pages,disabled_epoch)).is_ok(){work.insert(key);}
                        }
                    }
                }
                manager.update(json!({"version":1,"state":if inventory_error.is_some(){"unavailable"}else if work.is_empty(){"ready"}else{"fetching"},
                    "enriched":manager.apps.enriched_count(),"productsTotal":inventory.len(),"productsChecked":checked,
                    "failedProducts":errors.len(),"activeRequests":work.len(),"message":inventory_error.clone().or_else(||errors.values().next().cloned())}));
            }
        });
    }
}
#[cfg(windows)]
fn export_inventory(root:&std::path::Path,cancel:&AtomicBool)->Result<Vec<Package>,String>{
    use std::{process::{Command,Stdio},os::windows::process::CommandExt};
    let winget=std::env::var_os("LOCALAPPDATA").map(PathBuf::from).ok_or("Windows local application data is unavailable.")?
        .join("Microsoft/WindowsApps/winget.exe");
    if std::fs::symlink_metadata(&winget).is_err(){return Err("WinGet is unavailable. Native app names and saved purpose descriptions remain available.".into())}
    let folder=root.join(format!("export-{}-{}",std::process::id(),enrichment::now()));
    std::fs::create_dir(&folder).map_err(|e|e.to_string())?;
    let file=folder.join("packages.json");
    let result=(||{
        let mut child=Command::new(&winget).args(["export","--include-versions","--source","winget","--disable-interactivity","--output"])
            .arg(&file).creation_flags(0x08000000).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .spawn().map_err(|_|"WinGet could not export its installed-product catalog.")?;
        crate::helper::adopt(&child);
        let deadline=Instant::now()+Duration::from_secs(20);
        loop{
            if cancel.load(Ordering::SeqCst)||Instant::now()>=deadline{let _=child.kill();let _=child.wait();return Err("WinGet inventory stopped or timed out.".into())}
            if let Some(status)=child.try_wait().map_err(|e|e.to_string())?{
                if !status.success(){return Err("WinGet could not read its configured community source. Configure WinGet or retry; no source agreements were accepted automatically.".into())}
                break
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        if std::fs::metadata(&file).map_err(|e|e.to_string())?.len()>4_194_304{return Err("WinGet inventory is too large.".into())}
        enrichment::parse_export(&std::fs::read(&file).map_err(|e|e.to_string())?)
    })();
    let _=std::fs::remove_dir_all(folder);result
}
#[cfg(not(windows))]
fn export_inventory(_root:&std::path::Path,_cancel:&AtomicBool)->Result<Vec<Package>,String>{
    Err("Online installed-app metadata is available on Windows.".into())
}

#[cfg(test)]mod tests{
    use super::*;
    #[test]fn failed_refresh_retains_cached_text_and_clear_is_scoped(){
        let root=std::env::temp_dir().join(format!("digup-enrichment-test-{}-{}",std::process::id(),enrichment::now()));
        std::fs::create_dir_all(&root).unwrap();let file=root.join("enrichment.sqlite");
        {
            let db=Cache::open(&file).unwrap();let package=Package{id:"Example.Editor".into(),version:"1.2.3".into()};
            let d=Description{package_id:package.id.clone(),package_version:package.version.clone(),name:"Editor".into(),
                publisher:"Example".into(),description:"Edit photographs".into(),extractor_version:1,..Description::default()};
            db.save(&package,&Ok(d)).unwrap();db.save(&package,&Err("offline".into())).unwrap();
            assert_eq!(db.descriptions().unwrap()[0].description,"Edit photographs");
            assert!(!db.due(&package).unwrap());db.clear().unwrap();assert!(db.descriptions().unwrap().is_empty());
        }
        let _=std::fs::remove_dir_all(root);
    }
}
