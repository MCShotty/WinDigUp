//! User-owned app discovery. No database handle is shared between workers.
use crate::{applications::{self,Catalog,Record,Target},discovery::{self,Candidate,Options}};
use serde_json::{json,Value};
use std::{collections::HashSet,path::PathBuf,sync::{Arc,Mutex,RwLock,atomic::{AtomicBool,Ordering}},time::{Duration,Instant}};
pub struct Manager {
    root:PathBuf,apps:Arc<Catalog>,options:RwLock<Options>,progress:RwLock<Value>,volumes:RwLock<Vec<Value>>,
    cancel:Mutex<Option<Arc<AtomicBool>>>,wake:AtomicBool,full:AtomicBool,running:AtomicBool,
    last_foreground:Mutex<Instant>,renewing:AtomicBool,
    #[cfg(windows)]metadata_pool:Mutex<Option<std::sync::mpsc::SyncSender<MetadataJob>>>,
    #[cfg(windows)]watcher:Mutex<Option<notify::RecommendedWatcher>>,
    #[cfg(windows)]watched:Mutex<String>,
    #[cfg(windows)]last_fallback:Mutex<std::collections::HashMap<String,Instant>>,
    dirty_options:AtomicBool,failed:AtomicBool,notify:Arc<dyn Fn(Value)+Send+Sync>,
}
impl Manager {
    pub fn new(root:PathBuf,options:Options,apps:Arc<Catalog>,notify:impl Fn(Value)+Send+Sync+'static)->Arc<Self>{
        let manager=Arc::new(Self{root,apps,options:RwLock::new(options),progress:RwLock::new(json!({"version":1,"phase":"disabled","total":null})),
            volumes:RwLock::new(vec![]),cancel:Mutex::new(None),wake:AtomicBool::new(true),full:AtomicBool::new(false),
            running:AtomicBool::new(false),last_foreground:Mutex::new(Instant::now().checked_sub(Duration::from_secs(10)).unwrap_or_else(Instant::now)),
            renewing:AtomicBool::new(false),dirty_options:AtomicBool::new(true),failed:AtomicBool::new(false),
            #[cfg(windows)]metadata_pool:Mutex::new(None),
            #[cfg(windows)]watcher:Mutex::new(None),
            #[cfg(windows)]watched:Mutex::new(String::new()),
            #[cfg(windows)]last_fallback:Mutex::new(std::collections::HashMap::new()),
            notify:Arc::new(notify)});
        manager.apply_sources();manager
    }
    fn source(volume:&str)->String{format!("drive:{}",applications::digest(volume))}
    fn apply_sources(&self){
        let options=self.options.read().unwrap();
        let sources=if options.enabled{options.volumes.iter().map(|v|Self::source(v)).collect()}else{HashSet::new()};
        self.apps.configure_discovery(sources,options.hidden.iter().cloned().collect());
    }
    pub fn root(&self)->PathBuf{self.root.clone()}
    pub fn info(&self)->Value{
        json!({"version":1,"supported":cfg!(windows),"options":self.options.read().unwrap().clone(),
            "progress":self.progress.read().unwrap().clone(),"volumes":self.volumes.read().unwrap().clone(),
            "running":self.running.load(Ordering::SeqCst)})
    }
    fn update(&self,value:Value){*self.progress.write().unwrap()=value;(self.notify)(self.info());}
    pub fn configure(&self,options:Options){
        self.stop();self.dirty_options.store(true,Ordering::SeqCst);*self.options.write().unwrap()=options;self.apply_sources();self.schedule(false);
    }
    pub fn stop(&self){if let Some(cancel)=self.cancel.lock().unwrap().as_ref(){cancel.store(true,Ordering::SeqCst);}}
    pub fn schedule(&self,full:bool){self.failed.store(false,Ordering::SeqCst);if full{self.full.store(true,Ordering::SeqCst);}self.wake.store(true,Ordering::SeqCst);}
    pub fn foreground(self:&Arc<Self>){
        *self.last_foreground.lock().unwrap()=Instant::now();
        #[cfg(windows)]{
            if !self.running.load(Ordering::SeqCst)||self.renewing.swap(true,Ordering::SeqCst){return}
            let weak=Arc::downgrade(self);
            std::thread::spawn(move||{if let Some(manager)=weak.upgrade(){
                let cancel=Arc::new(AtomicBool::new(false));
                if let Ok(pipe)=discovery::ipc::Pipe::connect(cancel){
                    let _=pipe.send(&json!({"version":1,"op":"foreground"}));let _=pipe.receive();
                }
                manager.renewing.store(false,Ordering::SeqCst);
            }});
        }
    }
    fn quiet(&self,cancel:&AtomicBool)->Result<(),String>{
        loop{
            if cancel.load(Ordering::SeqCst)||!self.apps.enabled(){return Err("Discovery cancelled.".into())}
            let options=self.options.read().unwrap();
            if !options.enabled||options.paused{return Err("Discovery paused.".into())}
            drop(options);
            if self.last_foreground.lock().unwrap().elapsed()>=Duration::from_secs(1){return Ok(())}
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    pub fn start(self:&Arc<Self>){
        let weak=Arc::downgrade(self);
        std::thread::spawn(move||{
            #[cfg(windows)]if let Some(manager)=weak.upgrade(){
                *manager.volumes.write().unwrap()=discovery::volume::volumes().into_iter().map(|v|serde_json::to_value(v).unwrap()).collect();
                (manager.notify)(manager.info());
            }
            let mut last=Instant::now();
            loop{
                std::thread::sleep(Duration::from_millis(250));
                let Some(manager)=weak.upgrade()else{break};
                let options=manager.options.read().unwrap().clone();
                if !options.enabled||options.paused||!manager.apps.enabled(){
                    let phase=if !options.enabled{"disabled"}else if options.paused{"paused"}else{"waiting"};
                    let mut state=manager.progress.read().unwrap().clone();
                    if state["phase"]!=phase{state["phase"]=json!(phase);manager.update(state);}
                    continue;
                }
                let requested=manager.wake.swap(false,Ordering::SeqCst);
                if !requested&&(manager.failed.load(Ordering::SeqCst)||last.elapsed()<Duration::from_secs(15)){continue}
                let full=manager.full.swap(false,Ordering::SeqCst);last=Instant::now();
                #[cfg(windows)]{
                    *manager.volumes.write().unwrap()=discovery::volume::volumes().into_iter().map(|v|serde_json::to_value(v).unwrap()).collect();
                    let cancel=Arc::new(AtomicBool::new(false));*manager.cancel.lock().unwrap()=Some(cancel.clone());
                    manager.running.store(true,Ordering::SeqCst);manager.apps.discovery_running(true);
                    manager.install_watcher(&options);
                    let result=manager.run_pass(&options,full,requested,cancel.clone());
                    let cancelled=cancel.load(Ordering::SeqCst);
                    manager.running.store(false,Ordering::SeqCst);manager.apps.discovery_running(false);*manager.cancel.lock().unwrap()=None;
                    if let Err(message)=result{
                        if !cancelled&&manager.options.read().unwrap().enabled&&!manager.options.read().unwrap().paused {
                            manager.failed.store(true,Ordering::SeqCst);
                            manager.update(json!({"version":1,"phase":"failed","total":null,"message":message}));
                        }
                    }
                }
                #[cfg(not(windows))]{
                    let _=full;manager.update(json!({"version":1,"phase":"unavailable","message":"Drive discovery is available on Windows.","total":null}));
                }
            }
        });
    }
    #[cfg(windows)]
    fn run_pass(self:&Arc<Self>,options:&Options,full:bool,requested:bool,cancel:Arc<AtomicBool>)->Result<(),String>{
        use discovery::{store::CandidateStore,volume,ipc::Pipe};
        std::fs::create_dir_all(&self.root).map_err(|e|e.to_string())?;
        let db=CandidateStore::open(&self.root.join("discovery.sqlite"))?;
        if self.dirty_options.swap(false,Ordering::SeqCst){for volume in &options.volumes{db.set_revision(volume,"")?;}}
        self.publish_cached(&db,options)?;
        for selected in &options.volumes {
            self.quiet(&cancel)?;
            let volume=self.volumes.read().unwrap().iter().find(|v|v["id"]==selected.as_str()).cloned()
                ;
            let Some(volume)=volume else{self.update(json!({"version":1,"phase":"unavailable","volume":selected,"message":"This volume is disconnected or unavailable.","total":null}));continue};
            if volume["filesystem"]!="NTFS" {
                if requested||full||self.fallback_due(selected){self.fallback(&db,selected,&volume,options,&cancel)?;}
                continue;
            }
            let result=(||{
                let pipe=Pipe::connect(cancel.clone())?;
                pipe.send(&json!({"version":1,"op":"scan","volume":selected,"full":full,"knownRevision":db.revision(selected)?}))?;
                let revision=format!("pass-{}",std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
                let mut seen=0;let mut finished=0;
                let (results,received)=std::sync::mpsc::sync_channel(128);
                let pool=self.metadata_sender();let job_options=Arc::new(options.clone());
                let mut last_publish=Instant::now();
                loop{
                    self.quiet(&cancel)?;
                    let response=pipe.receive()?;
                    match response["kind"].as_str(){
                        Some("progress")=>{
                            let mut state=response.clone();state["volume"]=json!(selected);
                            state["accepted"]=json!(self.apps.records().iter().filter(|r|r.source==Self::source(selected)).count());
                            self.update(state);
                        },
                        Some("candidate")=>{
                            let mut candidate:Candidate=serde_json::from_value(response["candidate"].clone()).map_err(|e|e.to_string())?;
                            if !discovery::valid_candidate_id(&candidate.id)||candidate.file_id.len()!=32||!candidate.file_id.bytes().all(|b|b.is_ascii_hexdigit())||candidate.volume!=*selected
                                ||candidate.path.len()>32768||!candidate.path.starts_with(selected){return Err("Invalid executable identity from the discovery service.".into())}
                            Self::drain_metadata(&db,&received,&revision,&mut finished)?;
                            let old=db.get(&candidate.id)?;
                            let mut job=MetadataJob{wire:candidate,old,options:job_options.clone(),cancel:cancel.clone(),reply:results.clone()};
                            let deadline=Instant::now()+Duration::from_secs(60);
                            loop{
                                self.quiet(&cancel)?;
                                match pool.try_send(job){
                                    Ok(())=>{seen+=1;break},
                                    Err(std::sync::mpsc::TrySendError::Full(pending))=>{
                                        job=pending;Self::drain_metadata(&db,&received,&revision,&mut finished)?;
                                        if Instant::now()>=deadline{return Err("Executable metadata workers stopped making progress. Retry discovery explicitly.".into())}
                                        std::thread::sleep(Duration::from_millis(10));
                                    },
                                    Err(_)=>return Err("Executable metadata workers stopped.".into()),
                                }
                            }
                            if last_publish.elapsed()>Duration::from_millis(500){self.publish_cached(&db,options)?;last_publish=Instant::now();}
                        },
                        Some("complete")=>{
                            let deadline=Instant::now()+Duration::from_secs(60);
                            while finished<seen{
                                self.quiet(&cancel)?;
                                Self::drain_metadata(&db,&received,&revision,&mut finished)?;
                                if finished>=seen{break}
                                if Instant::now()>=deadline{return Err("Executable metadata workers stopped making progress. Retry discovery explicitly.".into())}
                                std::thread::sleep(Duration::from_millis(10));
                            }
                            if response["unchanged"]!=true{db.finish(selected,&revision)?;}
                            db.set_revision(selected,response["revision"].as_str().unwrap_or_default())?;
                            self.publish_cached(&db,options)?;
                            self.update(json!({"version":1,"phase":"watching","volume":selected,"records":response["records"],
                                "candidates":response["candidates"].as_u64().unwrap_or(seen),"accepted":self.apps.records().iter().filter(|r|r.source==Self::source(selected)).count(),
                                "total":null,"revision":response["revision"],"mode":"ntfs"}));return Ok(())
                        },
                        Some("error")=>return Err(response["message"].as_str().unwrap_or("NTFS discovery failed.").into()),
                        _=>return Err("Unexpected discovery response.".into()),
                    }
                }
            })();
            if let Err(error)=result {
                if cancel.load(Ordering::SeqCst){return Err(error)}
                self.update(json!({"version":1,"phase":"waiting","volume":selected,"message":format!("{error} Using directory discovery."),"total":null}));
                if requested||full||self.fallback_due(selected){self.fallback(&db,selected,&volume,options,&cancel)?;}
            }
        }
        Ok(())
    }
    #[cfg(windows)]
    fn fallback_due(&self,id:&str)->bool{self.last_fallback.lock().unwrap().get(id).is_none_or(|last|last.elapsed()>Duration::from_secs(300))}
    fn options_on_candidate(candidate:&mut Candidate,options:&Options){
        let (classification,reason)=discovery::classify(candidate);
        candidate.classification=classification.into();candidate.reason=reason.into();
        if options.included.contains(&candidate.id)&&candidate.portable{candidate.classification="accepted".into();candidate.reason="user_selected".into();}
        if options.hidden.contains(&candidate.id){candidate.classification="hidden".into();candidate.reason="user_hidden".into();}
    }
    #[cfg(windows)]
    fn publish_cached(&self,db:&discovery::store::CandidateStore,options:&Options)->Result<(),String>{
        for volume in &options.volumes{
            let mut records=vec![];
            for candidate in db.accepted()?.into_iter().filter(|c|&c.volume==volume&&!options.hidden.contains(&c.id)){
                let directory=std::path::Path::new(&candidate.path).parent().map(|p|p.to_string_lossy().into_owned()).unwrap_or_default();
                let mut record=Record::new(format!("discovered:{}",candidate.id),candidate.name.clone(),&Self::source(volume),
                    Target::Executable{path:candidate.path.clone(),working_directory:directory.clone()});
                record.publisher=candidate.publisher;record.description=candidate.description;record.product=candidate.product;
                record.executable=candidate.path;record.working_directory=directory;record.icon_revision=candidate.file_stamp;
                record.launch_key=candidate.launch_key;
                records.push(record);
            }
            self.apps.publish_discovery(&Self::source(volume),records,true);
        }
        Ok(())
    }
    #[cfg(windows)]
    fn fallback(&self,db:&discovery::store::CandidateStore,id:&str,volume:&Value,options:&Options,cancel:&AtomicBool)->Result<(),String>{
        use discovery::volume as fs;
        use std::os::windows::fs::MetadataExt;
        self.last_fallback.lock().unwrap().insert(id.into(),Instant::now());
        let root=volume["paths"].as_array().and_then(|p|p.first()).and_then(Value::as_str).ok_or("This volume has no usable mount point.")?;
        let mut stack=vec![std::fs::read_dir(root).map_err(|e|e.to_string())?];
        let revision=format!("walk-{}",std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
        let mut records=0u64;let mut skipped=0u64;let mut candidates=0u64;let mut last=Instant::now();
        while !stack.is_empty(){
            self.quiet(cancel)?;
            let Some(entry)=stack.last_mut().unwrap().next()else{stack.pop();continue};
            let entry=match entry{Ok(entry)=>entry,Err(_)=>{skipped+=1;continue}};
            records+=1;
            let metadata=match std::fs::symlink_metadata(entry.path()){Ok(m)=>m,Err(_)=>{skipped+=1;continue}};
            if metadata.file_attributes()&(0x400|0x1000)!=0{continue}
            if metadata.is_dir(){
                if stack.len()<256{match std::fs::read_dir(entry.path()){Ok(dir)=>stack.push(dir),Err(_)=>skipped+=1}}
            }else if metadata.is_file()&&entry.path().extension().is_some_and(|x|x.eq_ignore_ascii_case("exe")){
                let path=entry.path().to_string_lossy().into_owned();
                let Ok(info)=fs::file_info(&path)else{skipped+=1;continue};
                let mut candidate=Candidate{id:format!("exe:{}",applications::digest(&format!("{id}|{}|{path}",info.id().text()))),
                    volume:id.into(),file_id:info.id().text(),path:path.clone(),file_stamp:info.stamp(),..Candidate::default()};
                let (portable,gui)=fs::pe_info(&entry.path()).unwrap_or((false,false));
                let (product,publisher,description)=fs::metadata(&path);candidate.name=if product.is_empty(){entry.path().file_stem().unwrap_or_default().to_string_lossy().into_owned()}else{product.clone()};
                candidate.product=product;candidate.publisher=publisher;candidate.description=description;candidate.portable=portable;candidate.gui=gui;
                candidate.launch_key=fs::launch_key(&candidate.path,"",&entry.path().parent().unwrap().to_string_lossy()).unwrap_or_default();
                Self::options_on_candidate(&mut candidate,options);db.save(&candidate,&revision)?;candidates+=1;
            }
            if last.elapsed()>Duration::from_millis(500){self.update(json!({"version":1,"phase":"metadata","mode":"directory","volume":id,"records":records,
                "candidates":candidates,"skipped":skipped,"total":null}));self.publish_cached(db,options)?;last=Instant::now();}
        }
        // A partial walk retains previous candidates; it is never interpreted as mass removal.
        if skipped==0{db.finish(id,&revision)?;}
        self.publish_cached(db,options)?;
        self.update(json!({"version":1,"phase":"watching","mode":"directory","volume":id,"records":records,"candidates":candidates,
            "skipped":skipped,"partial":skipped!=0,"total":null}));Ok(())
    }
    #[cfg(windows)]
    fn install_watcher(self:&Arc<Self>,options:&Options){
        use notify::Watcher;
        let key=options.volumes.join("|");
        if *self.watched.lock().unwrap()==key{return}
        let weak=Arc::downgrade(self);
        let watcher=notify::recommended_watcher(move|event:Result<notify::Event,notify::Error>|{
            let Some(manager)=weak.upgrade()else{return};
            if manager.failed.load(Ordering::SeqCst){return}
            let relevant=match event{
                Ok(event)=>{
                    use notify::{EventKind,event::{CreateKind,RemoveKind,ModifyKind}};
                    event.paths.iter().any(|p|!p.starts_with(&manager.root)&&p.extension().is_some_and(|e|e.eq_ignore_ascii_case("exe")))
                    ||matches!(event.kind,EventKind::Create(CreateKind::Folder)|EventKind::Remove(RemoveKind::Folder))
                    ||(matches!(event.kind,EventKind::Modify(ModifyKind::Name(_)))&&event.paths.iter().any(|p|p.is_dir()))
                },
                Err(_)=>true,
            };
            if relevant{manager.wake.store(true,Ordering::SeqCst);}
        });
        if let Ok(mut watcher)=watcher{
            let volumes=self.volumes.read().unwrap();
            for volume in volumes.iter().filter(|v|options.volumes.iter().any(|id|v["id"]==id.as_str())){
                if let Some(root)=volume["paths"].as_array().and_then(|p|p.first()).and_then(Value::as_str){
                    let _=watcher.watch(std::path::Path::new(root),notify::RecursiveMode::Recursive);
                }
            }
            *self.watcher.lock().unwrap()=Some(watcher);*self.watched.lock().unwrap()=key;
        }
    }
    #[cfg(windows)]
    fn metadata_sender(self:&Arc<Self>)->std::sync::mpsc::SyncSender<MetadataJob>{
        let mut owner=self.metadata_pool.lock().unwrap();
        if let Some(sender)=owner.as_ref(){return sender.clone()}
        let(tx,rx)=std::sync::mpsc::sync_channel::<MetadataJob>(64);
        let rx=Arc::new(Mutex::new(rx));
        for _ in 0..4{
            let rx=rx.clone();let manager=Arc::downgrade(self);
            std::thread::spawn(move||loop{
                let job=match rx.lock().unwrap().recv(){Ok(job)=>job,Err(_)=>break};
                let Some(manager)=manager.upgrade()else{break};
                let result=manager.prepare_metadata(job.wire,job.old,&job.options,&job.cancel);
                let _=job.reply.send(result);
            });
        }
        *owner=Some(tx.clone());tx
    }
    #[cfg(windows)]
    fn drain_metadata(db:&discovery::store::CandidateStore,received:&std::sync::mpsc::Receiver<Result<Candidate,String>>,
        revision:&str,finished:&mut u64)->Result<(),String>{
        while let Ok(result)=received.try_recv(){
            let candidate=result?;db.save(&candidate,revision)?;*finished+=1;
        }
        Ok(())
    }
    #[cfg(windows)]
    fn prepare_metadata(&self,mut candidate:Candidate,old:Option<Candidate>,options:&Options,cancel:&AtomicBool)->Result<Candidate,String>{
        use discovery::volume;
        self.quiet(cancel)?;
        let unchanged=old.as_ref().is_some_and(|old|old.file_stamp==candidate.file_stamp&&old.path==candidate.path);
        if unchanged{
            let path=candidate.path;candidate=old.unwrap();candidate.path=path;
        }else{
            let info=match volume::file_info(&candidate.path){
                Ok(info)=>info,
                Err(_)=>{
                    if let Some(mut old)=old{old.reason="metadata_temporarily_unavailable".into();return Ok(old)}
                    candidate.name=std::path::Path::new(&candidate.path).file_stem().unwrap_or_default().to_string_lossy().into_owned();
                    candidate.classification="review".into();candidate.reason="metadata_unavailable".into();return Ok(candidate)
                }
            };
            if info.id().text()!=candidate.file_id{return Err("An executable changed identity during discovery; retry the pass.".into())}
            let (portable,gui)=volume::pe_info(std::path::Path::new(&candidate.path)).unwrap_or((false,false));
            let (product,publisher,description)=volume::metadata(&candidate.path);
            candidate.product=product;candidate.publisher=publisher;candidate.description=description;
            candidate.portable=portable;candidate.gui=gui;candidate.file_stamp=info.stamp();
            candidate.name=if !candidate.product.is_empty(){candidate.product.clone()}else{
                std::path::Path::new(&candidate.path).file_stem().unwrap_or_default().to_string_lossy().into_owned()};
            let directory=std::path::Path::new(&candidate.path).parent().map(|p|p.to_string_lossy().into_owned()).unwrap_or_default();
            candidate.launch_key=volume::launch_key(&candidate.path,"",&directory).unwrap_or_default();
            let after=volume::file_info(&candidate.path)?;
            if after.id()!=info.id()||after.stamp()!=info.stamp(){return Err("An executable changed while its metadata was being read; retry the pass.".into())}
        }
        Self::options_on_candidate(&mut candidate,options);Ok(candidate)
    }

}

#[cfg(windows)]
struct MetadataJob{
    wire:Candidate,old:Option<Candidate>,options:Arc<Options>,cancel:Arc<AtomicBool>,
    reply:std::sync::mpsc::SyncSender<Result<Candidate,String>>,
}
