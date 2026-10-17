//! User-owned app discovery. No database handle is shared between workers.
use crate::{applications::{self,Catalog,Record,Target},discovery::{self,Candidate,Options}};
use serde_json::{json,Value};
use std::{collections::HashSet,path::PathBuf,sync::{Arc,Mutex,RwLock,atomic::{AtomicBool,Ordering}},time::{Duration,Instant}};
pub struct Manager {
    configuring:Mutex<()>,last_notification:Mutex<Instant>,
    root:PathBuf,apps:Arc<Catalog>,options:RwLock<Options>,progress:RwLock<Value>,volumes:RwLock<Vec<Value>>,
    source_errors:RwLock<std::collections::BTreeMap<String,String>>,
    by_volume:RwLock<std::collections::BTreeMap<String,Value>>,
    #[cfg(windows)]metadata_gate:Arc<discovery::scheduler::Gate>,
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
        let phase=if !options.enabled{"disabled"}else if options.paused{"paused"}else{"waiting"};
        let manager=Arc::new(Self{configuring:Mutex::new(()),last_notification:Mutex::new(Instant::now()-Duration::from_secs(1)),root,apps,options:RwLock::new(options),progress:RwLock::new(json!({"version":1,"phase":phase,"total":null})),
            source_errors:RwLock::new(std::collections::BTreeMap::new()),by_volume:RwLock::new(std::collections::BTreeMap::new()),
            #[cfg(windows)]metadata_gate:discovery::scheduler::Gate::new(discovery::scheduler::Mode::Metadata),volumes:RwLock::new(vec![]),cancel:Mutex::new(None),wake:AtomicBool::new(true),full:AtomicBool::new(false),
            running:AtomicBool::new(false),last_foreground:Mutex::new(Instant::now().checked_sub(Duration::from_secs(10)).unwrap_or_else(Instant::now)),
            renewing:AtomicBool::new(false),dirty_options:AtomicBool::new(true),failed:AtomicBool::new(false),
            #[cfg(windows)]metadata_pool:Mutex::new(None),
            #[cfg(windows)]watcher:Mutex::new(None),
            #[cfg(windows)]watched:Mutex::new(String::new()),
            #[cfg(windows)]last_fallback:Mutex::new(std::collections::HashMap::new()),
            notify:Arc::new(notify)});
        manager.apply_sources();
        {let options=manager.options.read().unwrap();manager.apps.discovery_running(options.enabled&&!options.paused&&!options.volumes.is_empty()&&manager.apps.enabled());}
        manager
    }
    fn source(volume:&str)->String{format!("drive:{}",applications::digest(volume))}
    fn apply_sources(&self){
        let options=self.options.read().unwrap();
        let sources=if options.enabled{options.volumes.iter().map(|v|Self::source(v)).collect()}else{HashSet::new()};
        self.apps.configure_discovery(sources,options.hidden.iter().cloned().collect());
    }
    pub fn root(&self)->PathBuf{self.root.clone()}
    pub fn info(&self)->Value{
        json!({"version":2,"supported":cfg!(windows),"options":self.options.read().unwrap().clone(),
            "progress":self.progress.read().unwrap().clone(),"byVolume":self.by_volume.read().unwrap().clone(),"volumes":self.volumes.read().unwrap().clone(),
            "sourceErrors":self.source_errors.read().unwrap().clone(),"running":self.running.load(Ordering::SeqCst)})
    }
    fn update(&self,mut value:Value){
        let now=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs_f64();
        value["capturedAt"]=json!(now);value["lastProgressAt"]=json!(now);
        if let Some(volume)=value["volume"].as_str().map(str::to_owned){
            let mut rows=self.by_volume.write().unwrap();
            let mut row=rows.get(&volume).cloned().unwrap_or_else(||json!({}));
            if let(Some(old),Some(next))=(row.as_object_mut(),value.as_object()){for(key,value)in next{old.insert(key.clone(),value.clone());}}
            rows.insert(volume,row);
        }
        let urgent=matches!(value["phase"].as_str(),Some("failed"|"unavailable"|"paused"|"disabled"|"watching"));
        *self.progress.write().unwrap()=value;
        let send={let mut last=self.last_notification.lock().unwrap();if urgent||last.elapsed()>=Duration::from_millis(250){*last=Instant::now();true}else{false}};
        if send{(self.notify)(self.info());}
    }
    pub fn configure(&self,options:Options){
        let _serial=self.configuring.lock().unwrap();
        if options.revision<self.options.read().unwrap().revision{return}
        self.stop();self.by_volume.write().unwrap().retain(|id,_|options.volumes.contains(id));self.source_errors.write().unwrap().retain(|id,_|options.volumes.contains(id));
        self.dirty_options.store(true,Ordering::SeqCst);*self.options.write().unwrap()=options;self.apply_sources();self.schedule(false);
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
                    manager.apps.discovery_running(false);
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
                            let mut state=manager.progress.read().unwrap().clone();state["phase"]=json!("failed");state["message"]=json!(message);manager.update(state);
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
        use discovery::{store::CandidateStore,scheduler::{Gate,Mode,Resource}};
        use std::{collections::BTreeMap,sync::mpsc};
        std::fs::create_dir_all(&self.root).map_err(|e|e.to_string())?;
        let db=CandidateStore::recovering(&self.root.join("discovery.sqlite"))?;
        if self.dirty_options.swap(false,Ordering::SeqCst){for volume in &options.volumes{db.set_revision(volume,"")?;}}
        self.publish_cached(&db,options)?;
        if let Ok(pipe)=discovery::ipc::Pipe::connect(cancel.clone()){
            if pipe.send(&json!({"version":1,"op":"topology","volumes":options.volumes})).is_ok(){
                if let Ok(reply)=pipe.receive(){
                    if reply["version"]==1&&reply["kind"]=="topology"{
                        if let Some(rows)=reply["volumes"].as_array(){
                            let mut volumes=self.volumes.write().unwrap();
                            for row in rows.iter().take(64){
                                let Some(id)=row["id"].as_str()else{continue};
                                if !options.volumes.iter().any(|selected|selected==id){continue}
                                if let Ok(mut topology)=serde_json::from_value::<discovery::scheduler::Topology>(row["topology"].clone()){
                                    if topology.disks.len()>128{continue}
                                    topology.disks.sort_unstable();topology.disks.dedup();
                                    if topology.disks.is_empty(){topology.known=false;}
                                    if let Some(volume)=volumes.iter_mut().find(|value|value["id"]==id){
                                        volume["topology"]=serde_json::to_value(topology).unwrap();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        let gate=Gate::new(Mode::Scan);
        let mut waiting=vec![];
        let mut passes=BTreeMap::<String,Pass>::new();
        let mut failures=vec![];
        for selected in &options.volumes {
            let volume=self.volumes.read().unwrap().iter().find(|v|v["id"]==selected.as_str()).cloned();
            let Some(volume)=volume else{
                let message="This volume is disconnected or unavailable.".to_string();
                self.source_errors.write().unwrap().insert(selected.clone(),message.clone());failures.push(message.clone());
                self.update(json!({"version":2,"phase":"unavailable","volume":selected,"message":message,"total":null}));continue
            };
            if volume["filesystem"]!="NTFS"&&!requested&&!full&&!self.fallback_due(selected){continue}
            let topology=serde_json::from_value(volume["topology"].clone()).unwrap_or_default();
            let ticket=gate.request(Resource{volume:selected.clone(),topology});
            self.update(json!({"version":2,"phase":"waiting","volume":selected,"records":null,"candidates":null,
                "message":"Waiting for discovery capacity on this physical disk.","total":null,"topology":volume["topology"],"timings":null,"serviceTimings":null,"metadataDone":null,"metadataQueued":null}));
            waiting.push((selected.clone(),volume,ticket));
        }
        let (events,received)=mpsc::sync_channel::<ScanEvent>(128);
        let (results,metadata)=mpsc::sync_channel::<MetadataResult>(128);
        let pool=self.metadata_sender();let mut threads=vec![];
        let job_options=Arc::new(options.clone());
        let result=(||{
            let mut last_publish=Instant::now();let mut dirty=false;
            while !waiting.is_empty()||!passes.is_empty(){
                self.quiet(&cancel)?;
                let mut index=0;
                while index<waiting.len(){
                    let Some(lease)=waiting[index].2.try_start()else{index+=1;continue};
                    let(selected,volume,_ticket)=waiting.remove(index);
                    let revision=format!("pass-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
                    let known=db.revision(&selected)?;
                    let topology=serde_json::from_value(volume["topology"].clone()).unwrap_or_default();
                    passes.insert(selected.clone(),Pass{revision,seen:0,finished:0,complete:None,error:None,pending:vec![],
                        timings:Default::default(),topology,_lease:lease});
                    let sender=events.clone();let manager=self.clone();let cancel=cancel.clone();
                    threads.push(std::thread::spawn(move||{
                        let outcome=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||manager.stream_volume(&selected,&volume,full,&known,cancel,&sender)));
                        match outcome{
                            Ok(Ok(complete))=>{let _=sender.send(ScanEvent::Complete(selected,complete));},
                            Ok(Err(message))=>{let _=sender.send(ScanEvent::Failed(selected,message));},
                            Err(_)=>{let _=sender.send(ScanEvent::Failed(selected,"The discovery worker stopped unexpectedly. Retry explicitly.".into()));}
                        }
                    }));
                }
                dirty|=Self::drain_metadata(&db,&metadata,&mut passes)?;
                match received.recv_timeout(Duration::from_millis(20)){
                    Ok(ScanEvent::Progress(id,mut state))=>{
                        state["volume"]=json!(id);state["version"]=json!(2);
                        if let Some(timings)=state.get("timings").cloned(){state["serviceTimings"]=timings;state.as_object_mut().unwrap().remove("timings");}
                        if let Some(pass)=passes.get(&id){state["timings"]=serde_json::to_value(&pass.timings).unwrap();}
                        self.update(state);
                    },
                    Ok(ScanEvent::Candidate(id,candidate))=>{
                        let old=db.get(&candidate.id)?;
                        let pass=passes.get_mut(&id).ok_or("Discovery returned an obsolete volume.")?;
                        pass.seen+=1;
                        let mut job=MetadataJob{wire:candidate,old,options:job_options.clone(),cancel:cancel.clone(),
                            topology:pass.topology.clone(),enqueued:Instant::now(),reply:results.clone()};
                        let mut progress=Instant::now();
                        loop{
                            self.quiet(&cancel)?;
                            match pool.try_send(job){
                                Ok(())=>break,
                                Err(mpsc::TrySendError::Full(pending))=>{
                                    job=pending;
                                    if Self::drain_metadata(&db,&metadata,&mut passes)?{dirty=true;progress=Instant::now();}
                                    if progress.elapsed()>Duration::from_secs(60){return Err("Executable metadata workers stopped making progress. Retry explicitly.".into())}
                                    std::thread::sleep(Duration::from_millis(5));
                                },
                                Err(_)=>return Err("Executable metadata workers stopped.".into())
                            }
                        }
                    },
                    Ok(ScanEvent::Complete(id,value))=>{if let Some(pass)=passes.get_mut(&id){pass.complete=Some(value);}},
                    Ok(ScanEvent::Failed(id,message))=>{if let Some(pass)=passes.get_mut(&id){pass.error=Some(message);pass.complete=Some(json!({"partial":true}));}},
                    Err(mpsc::RecvTimeoutError::Timeout)=>{},
                    Err(_)=>return Err("Discovery workers stopped.".into())
                }
                let finished:Vec<_>=passes.iter().filter(|(_,pass)|pass.complete.is_some()&&pass.finished==pass.seen).map(|(id,_)|id.clone()).collect();
                for id in finished{
                    let mut pass=passes.remove(&id).unwrap();
                    Self::flush_metadata(&db,&mut pass)?;
                    let complete=pass.complete.as_ref().unwrap();
                    if let Some(message)=pass.error{
                        self.source_errors.write().unwrap().insert(id.clone(),message.clone());failures.push(message.clone());
                        self.update(json!({"version":2,"phase":"failed","volume":id,"message":message,"total":null,"timings":pass.timings}));
                    }else{
                        let measured=Instant::now();
                        if complete["unchanged"]!=true&&complete["partial"]!=true{db.finish(&id,&pass.revision)?;}
                        if let Some(revision)=complete["revision"].as_str(){db.set_revision(&id,revision)?;}
                        pass.timings.record("databaseCommit",measured,0);
                        self.source_errors.write().unwrap().remove(&id);
                        self.update(json!({"version":2,"phase":"watching","volume":id,"message":null,"records":complete["records"],
                            "candidates":complete["candidates"].as_u64().unwrap_or(pass.seen),"accepted":db.accepted_for(&id)?.len(),
                            "skipped":complete["skipped"],"partial":complete["partial"],"mode":complete["mode"],
                            "total":null,"timings":pass.timings,"serviceTimings":complete["timings"]}));
                    }
                    dirty=true;
                }
                if dirty&&last_publish.elapsed()>=Duration::from_millis(500){
                    for pass in passes.values_mut(){Self::flush_metadata(&db,pass)?;}
                    let measured=Instant::now();self.publish_cached(&db,options)?;
                    for (id,pass) in &mut passes{
                        pass.timings.record("catalogPublication",measured,0);
                        self.update(json!({"version":2,"phase":"metadata","volume":id,"timings":pass.timings,
                            "metadataDone":pass.finished,"metadataQueued":pass.seen,"accepted":db.accepted_for(id)?.len(),"total":null}));
                    }
                    dirty=false;last_publish=Instant::now();
                }
            }
            self.publish_cached(&db,options)?;
            if failures.is_empty(){Ok(())}else{Err(failures.join("; "))}
        })();
        if let Err(message)=&result{if !cancel.load(Ordering::SeqCst){
            self.failed.store(true,Ordering::SeqCst);
            for id in passes.keys(){self.source_errors.write().unwrap().insert(id.clone(),message.clone());self.update(json!({"version":2,"volume":id,"phase":"failed","message":message,"total":null}));}
            self.update(json!({"version":2,"phase":"failed","message":message,"total":null}));
            cancel.store(true,Ordering::SeqCst);
        }}
        drop(received);
        for thread in threads{let _=thread.join();}
        result
    }
    #[cfg(windows)]
    fn stream_volume(self:&Arc<Self>,id:&str,volume:&Value,full:bool,known:&str,cancel:Arc<AtomicBool>,
        events:&std::sync::mpsc::SyncSender<ScanEvent>)->Result<Value,String>{
        if volume["filesystem"]=="NTFS"{
            let result=(||{
                let pipe=discovery::ipc::Pipe::connect(cancel.clone())?;
                pipe.send(&json!({"version":1,"op":"scan","volume":id,"full":full,"knownRevision":known}))?;
                loop{
                    self.quiet(&cancel)?;
                    let response=pipe.receive()?;
                    match response["kind"].as_str(){
                        Some("progress")=>events.send(ScanEvent::Progress(id.into(),response)).map_err(|_|"Discovery cancelled.")?,
                        Some("candidate")=>{
                            let candidate:Candidate=serde_json::from_value(response["candidate"].clone()).map_err(|e|e.to_string())?;
                            if !discovery::valid_candidate_id(&candidate.id)||candidate.file_id.len()!=32||
                                !candidate.file_id.bytes().all(|b|b.is_ascii_hexdigit())||candidate.volume!=id||
                                candidate.path.len()>32768||!candidate.path.starts_with(id){return Err("Invalid executable identity from the discovery service.".into())}
                            events.send(ScanEvent::Candidate(id.into(),candidate)).map_err(|_|"Discovery cancelled.")?;
                        },
                        Some("complete")=>{let mut response=response;response["mode"]=json!("ntfs");return Ok(response)},
                        Some("error")=>return Err(response["message"].as_str().unwrap_or("NTFS discovery failed.").to_string()),
                        _=>return Err("Unexpected discovery response.".into())
                    }
                }
            })();
            match result{
                Ok(value)=>return Ok(value),
                Err(error)if cancel.load(Ordering::SeqCst)=>return Err(error),
                Err(error)=>{events.send(ScanEvent::Progress(id.into(),json!({"phase":"waiting","message":format!("{error} Using directory discovery."),"total":null}))).map_err(|_|"Discovery cancelled.")?;}
            }
        }
        self.fallback(id,volume,&cancel,events)
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
        let accepted=db.accepted()?;
        for volume in &options.volumes{
            let records=accepted.iter().filter(|c|&c.volume==volume&&!options.hidden.contains(&c.id)).map(|candidate|{
                let directory=std::path::Path::new(&candidate.path).parent().map(|p|p.to_string_lossy().into_owned()).unwrap_or_default();
                let mut record=Record::new(format!("discovered:{}",candidate.id),candidate.name.clone(),&Self::source(volume),
                    Target::Executable{path:candidate.path.clone(),working_directory:directory.clone()});
                record.publisher=candidate.publisher.clone();record.description=candidate.description.clone();record.product=candidate.product.clone();
                record.executable=candidate.path.clone();record.working_directory=directory;record.icon_revision=candidate.file_stamp.clone();
                record.launch_key=candidate.launch_key.clone();record
            }).collect();
            self.apps.publish_discovery(&Self::source(volume),records,true);
        }
        Ok(())
    }
    #[cfg(windows)]
    fn fallback(&self,id:&str,volume:&Value,cancel:&AtomicBool,events:&std::sync::mpsc::SyncSender<ScanEvent>)->Result<Value,String>{
        use discovery::volume as fs;
        use std::os::windows::fs::MetadataExt;
        self.last_fallback.lock().unwrap().insert(id.into(),Instant::now());
        let root=volume["paths"].as_array().and_then(|p|p.first()).and_then(Value::as_str).ok_or("This volume has no usable mount point.")?;
        let mut stack=vec![std::fs::read_dir(root).map_err(|e|e.to_string())?];
        let mut records=0u64;let mut skipped=0u64;let mut candidates=0u64;let mut last=Instant::now();
        let mut timings=discovery::metrics::Timings::default();
        while !stack.is_empty(){
            self.quiet(cancel)?;
            let measured=Instant::now();
            let next=stack.last_mut().unwrap().next();
            timings.record("enumeration",measured,u64::from(next.is_some()));
            let Some(entry)=next else{stack.pop();continue};
            let entry=match entry{Ok(entry)=>entry,Err(_)=>{skipped+=1;continue}};
            records+=1;
            let metadata=match std::fs::symlink_metadata(entry.path()){Ok(m)=>m,Err(_)=>{skipped+=1;continue}};
            if metadata.file_attributes()&0x1400!=0{continue}
            if metadata.is_dir(){
                if stack.len()>=256{skipped+=1;continue}
                match std::fs::read_dir(entry.path()){Ok(dir)=>stack.push(dir),Err(_)=>skipped+=1}
            }else if metadata.is_file()&&entry.path().extension().is_some_and(|x|x.eq_ignore_ascii_case("exe")){
                let measured=Instant::now();let path=entry.path().to_string_lossy().into_owned();
                let Ok(info)=fs::file_info(&path)else{skipped+=1;continue};
                let parent_path=entry.path().parent().unwrap().to_path_buf();
                let Ok(parent)=fs::directory_info(&parent_path.to_string_lossy())else{skipped+=1;continue};
                let identity=format!("{id}|{}|{}|{}|{}",info.serial(),info.id().text(),parent.id().text(),entry.file_name().to_string_lossy());
                let candidate=Candidate{id:format!("exe:{}",applications::digest(&identity)),
                    volume:id.into(),file_id:info.id().text(),path,file_stamp:info.stamp(),..Candidate::default()};
                timings.record("pathResolution",measured,1);
                events.send(ScanEvent::Candidate(id.into(),candidate)).map_err(|_|"Discovery cancelled.")?;candidates+=1;
            }
            if last.elapsed()>Duration::from_millis(500){
                events.send(ScanEvent::Progress(id.into(),json!({"version":2,"phase":"enumerating","mode":"directory",
                    "records":records,"candidates":candidates,"skipped":skipped,"total":null,"timings":timings}))).map_err(|_|"Discovery cancelled.")?;
                last=Instant::now();
            }
        }
        Ok(json!({"records":records,"candidates":candidates,"skipped":skipped,"partial":skipped!=0,"mode":"directory","timings":timings}))
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
                let id=job.wire.volume.clone();
                let ticket=manager.metadata_gate.request(discovery::scheduler::Resource{volume:id.clone(),topology:job.topology});
                let result=ticket.wait(&job.cancel,Duration::from_secs(120));
                let queued=job.enqueued.elapsed();
                let started=Instant::now();
                let candidate=match result{
                    Ok(_lease)=>manager.prepare_metadata(job.wire,job.old,&job.options,&job.cancel),
                    Err(error)=>Err(error)
                };
                let _=job.reply.send(MetadataResult{volume:id,candidate,elapsed:started.elapsed(),queued});
            });
        }
        *owner=Some(tx.clone());tx
    }
    #[cfg(windows)]
    fn drain_metadata(db:&discovery::store::CandidateStore,received:&std::sync::mpsc::Receiver<MetadataResult>,
        passes:&mut std::collections::BTreeMap<String,Pass>)->Result<bool,String>{
        let mut changed=false;
        while let Ok(result)=received.try_recv(){
            let Some(pass)=passes.get_mut(&result.volume)else{continue};
            pass.finished+=1;
            pass.timings.stages.entry("metadataReads".into()).or_default().record(result.elapsed,1);
            pass.timings.stages.entry("metadataQueue".into()).or_default().record(result.queued,1);
            match result.candidate{
                Ok(candidate)=>pass.pending.push(candidate),
                Err(message)=>pass.error=Some(message)
            }
            if pass.pending.len()>=64{Self::flush_metadata(db,pass)?;}
            changed=true;
        }
        Ok(changed)
    }
    #[cfg(windows)]
    fn flush_metadata(db:&discovery::store::CandidateStore,pass:&mut Pass)->Result<(),String>{
        let measured=Instant::now();db.save_batch(&pass.pending,&pass.revision)?;
        if !pass.pending.is_empty(){pass.timings.record("databaseCommit",measured,pass.pending.len()as u64);}
        pass.pending.clear();Ok(())
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
    topology:discovery::scheduler::Topology,enqueued:Instant,reply:std::sync::mpsc::SyncSender<MetadataResult>,
}
#[cfg(windows)]
struct MetadataResult{volume:String,candidate:Result<Candidate,String>,elapsed:Duration,queued:Duration}
#[cfg(windows)]
enum ScanEvent{Progress(String,Value),Candidate(String,Candidate),Complete(String,Value),Failed(String,String)}
#[cfg(windows)]
struct Pass{
    revision:String,seen:u64,finished:u64,complete:Option<Value>,error:Option<String>,pending:Vec<Candidate>,
    timings:discovery::metrics::Timings,topology:discovery::scheduler::Topology,_lease:discovery::scheduler::Lease,
}
