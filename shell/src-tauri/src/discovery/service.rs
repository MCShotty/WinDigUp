//! Optional SCM component. It enumerates filesystem metadata; it never launches code, embeds or accesses the network.
use crate::discovery::{ipc::{self,Pipe},ntfs::FileId,store::VolumeStore,volume::{self,HandleValue,wide}};
use serde_json::json;
use sha2::{Digest,Sha256};
use std::{collections::HashSet,ffi::c_void,path::{Path,PathBuf},sync::{Arc,Mutex,OnceLock,atomic::{AtomicBool,AtomicUsize,Ordering}},time::{Duration,Instant}};
#[repr(C)]struct ServiceEntry {name:*mut u16,entry:Option<unsafe extern "system" fn(u32,*mut *mut u16)>}
#[repr(C)]struct Status {kind:u32,state:u32,controls:u32,exit:u32,specific:u32,checkpoint:u32,hint:u32}
#[repr(C)]struct SecurityAttributes {length:u32,descriptor:*mut c_void,inherit:i32}
#[repr(C)]struct Guid {a:u32,b:u16,c:u16,d:[u8;8]}
#[link(name="advapi32")]unsafe extern "system" {
    fn StartServiceCtrlDispatcherW(table:*const ServiceEntry)->i32;
    fn RegisterServiceCtrlHandlerExW(name:*const u16,handler:Option<unsafe extern "system" fn(u32,u32,*mut c_void,*mut c_void)->u32>,context:*mut c_void)->HandleValue;
    fn SetServiceStatus(handle:HandleValue,status:*const Status)->i32;
    fn OpenSCManagerW(machine:*const u16,database:*const u16,access:u32)->HandleValue;
    fn OpenServiceW(manager:HandleValue,name:*const u16,access:u32)->HandleValue;
    fn CreateServiceW(manager:HandleValue,name:*const u16,display:*const u16,access:u32,kind:u32,start:u32,error:u32,binary:*const u16,group:*const u16,tag:*mut u32,dependencies:*const u16,account:*const u16,password:*const u16)->HandleValue;
    fn ChangeServiceConfigW(service:HandleValue,kind:u32,start:u32,error:u32,binary:*const u16,group:*const u16,tag:*mut u32,dependencies:*const u16,account:*const u16,password:*const u16,display:*const u16)->i32;
    fn ControlService(service:HandleValue,code:u32,status:*mut Status)->i32;
    fn QueryServiceStatus(service:HandleValue,status:*mut Status)->i32;
    fn DeleteService(service:HandleValue)->i32;
    fn CloseServiceHandle(handle:HandleValue)->i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl:*const u16,revision:u32,descriptor:*mut *mut c_void,size:*mut u32)->i32;
    fn SetServiceObjectSecurity(service:HandleValue,information:u32,descriptor:*const c_void)->i32;
    fn GetNamedSecurityInfoW(name:*const u16,kind:u32,information:u32,owner:*mut *mut c_void,group:*mut *mut c_void,dacl:*mut *mut c_void,sacl:*mut *mut c_void,descriptor:*mut *mut c_void)->u32;
    fn ConvertSidToStringSidW(sid:*const c_void,text:*mut *mut u16)->i32;
    fn SetFileSecurityW(path:*const u16,information:u32,descriptor:*const c_void)->i32;
}
#[link(name="kernel32")]unsafe extern "system"{
    fn LocalFree(memory:*mut c_void)->*mut c_void;
    fn CreateDirectoryW(path:*const u16,security:*const SecurityAttributes)->i32;
}
#[link(name="shell32")]unsafe extern "system"{fn SHGetKnownFolderPath(id:*const Guid,flags:u32,token:HandleValue,path:*mut *mut u16)->i32;}
#[link(name="ole32")]unsafe extern "system"{fn CoTaskMemFree(pointer:*const c_void);}
static STOP:OnceLock<Arc<AtomicBool>>=OnceLock::new();
static STATUS:AtomicUsize=AtomicUsize::new(0);
fn report(state:u32){
    let handle=STATUS.load(Ordering::SeqCst)as HandleValue;
    if !handle.is_null(){let status=Status{kind:16,state,controls:if state==4{1|4}else{0},exit:0,specific:0,checkpoint:0,hint:if state==2||state==3{5000}else{0}};
        unsafe{SetServiceStatus(handle,&status);}}
}
unsafe extern "system" fn control(code:u32,_kind:u32,_data:*mut c_void,_context:*mut c_void)->u32{
    if code==1||code==5 {if let Some(stop)=STOP.get(){stop.store(true,Ordering::SeqCst);}report(3);}0
}
unsafe extern "system" fn entry(_count:u32,_args:*mut *mut u16){
    let handle=unsafe{RegisterServiceCtrlHandlerExW(wide(ipc::SERVICE_NAME).as_ptr(),Some(control),std::ptr::null_mut())};
    if handle.is_null(){return}
    STATUS.store(handle as usize,Ordering::SeqCst);report(2);
    let stop=STOP.get_or_init(||Arc::new(AtomicBool::new(false))).clone();
    let result=serve(stop);
    if let Err(error)=result{eprintln!("Discovery service: {error}");}
    report(1);
}
struct ServiceHandle(HandleValue);
impl Drop for ServiceHandle {fn drop(&mut self){unsafe{CloseServiceHandle(self.0);}}}
fn known_folder(program_files:bool)->Result<PathBuf,String>{
    let id=if program_files{Guid{a:0x905e63b6,b:0xc1bf,c:0x494e,d:[0xb2,0x9c,0x65,0xb7,0x32,0xd3,0xd2,0x1a]}}
        else{Guid{a:0x62ab5d82,b:0xfdc1,c:0x4dc3,d:[0xa9,0xdd,0x07,0x0d,0x1d,0x49,0x5d,0x97]}};
    let mut path=std::ptr::null_mut();
    if unsafe{SHGetKnownFolderPath(&id,0,std::ptr::null_mut(),&mut path)}<0||path.is_null(){return Err("Windows known-folder lookup failed.".into())}
    let mut length=0;while unsafe{*path.add(length)}!=0&&length<32768{length+=1}
    let text=String::from_utf16_lossy(unsafe{std::slice::from_raw_parts(path,length)});
    unsafe{CoTaskMemFree(path.cast())};Ok(PathBuf::from(text).join("DigUpDiscovery"))
}
fn descriptor(public:bool)->Result<*mut c_void,String>{
    let text=if public{"O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)"}
        else{"O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"};
    let mut result=std::ptr::null_mut();
    if unsafe{ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(text).as_ptr(),1,&mut result,std::ptr::null_mut())}==0{return Err(volume::error())}
    Ok(result)
}
fn secure_directory(path:&Path,public:bool)->Result<(),String>{
    use std::os::windows::fs::MetadataExt;
    let descriptor=descriptor(public)?;
    let attrs=SecurityAttributes{length:std::mem::size_of::<SecurityAttributes>()as u32,descriptor,inherit:0};
    let created=unsafe{CreateDirectoryW(wide(&path.to_string_lossy()).as_ptr(),&attrs)}!=0;
    let result=(||{
        let metadata=std::fs::symlink_metadata(path).map_err(|e|e.to_string())?;
        if !metadata.is_dir()||metadata.file_attributes()&0x400!=0{return Err("Discovery component directory is redirected or invalid.".into())}
        if !created {
            let mut owner=std::ptr::null_mut();let mut security=std::ptr::null_mut();
            let code=unsafe{GetNamedSecurityInfoW(wide(&path.to_string_lossy()).as_ptr(),1,1,&mut owner,std::ptr::null_mut(),std::ptr::null_mut(),std::ptr::null_mut(),&mut security)};
            if code!=0{return Err("Cannot verify discovery component directory ownership.".into())}
            let mut text=std::ptr::null_mut();
            let ok=unsafe{ConvertSidToStringSidW(owner,&mut text)}!=0;
            let trusted=if ok&&!text.is_null(){let mut length=0;while unsafe{*text.add(length)}!=0&&length<256{length+=1}
                let sid=String::from_utf16_lossy(unsafe{std::slice::from_raw_parts(text,length)});
                sid=="S-1-5-32-544"||sid=="S-1-5-18"}else{false};
            if !text.is_null(){unsafe{LocalFree(text.cast());}}
            if !security.is_null(){unsafe{LocalFree(security);}}
            if !trusted{return Err("Existing discovery directory is not administrator-owned. Remove that directory before installing this component.".into())}
            if unsafe{SetFileSecurityW(wide(&path.to_string_lossy()).as_ptr(),0x80000007,descriptor)}==0{return Err(volume::error())}
        }
        Ok(())
    })();
    unsafe{LocalFree(descriptor)};result
}
fn verify_inventory_file(path:&Path)->Result<(),String>{
    use std::os::windows::fs::MetadataExt;
    let metadata=match std::fs::symlink_metadata(path){Ok(metadata)=>metadata,Err(e)if e.kind()==std::io::ErrorKind::NotFound=>return Ok(()),Err(e)=>return Err(e.to_string())};
    if !metadata.is_file()||metadata.file_attributes()&0x400!=0{return Err("Protected discovery cache contains a redirected file.".into())}
    if volume::file_info(&path.to_string_lossy())?.links()!=1{return Err("Protected discovery cache contains a linked file.".into())}
    let mut owner=std::ptr::null_mut();let mut security=std::ptr::null_mut();
    let code=unsafe{GetNamedSecurityInfoW(wide(&path.to_string_lossy()).as_ptr(),1,1,&mut owner,std::ptr::null_mut(),std::ptr::null_mut(),std::ptr::null_mut(),&mut security)};
    if code!=0{return Err("Cannot verify protected discovery cache ownership.".into())}
    let mut text=std::ptr::null_mut();let ok=unsafe{ConvertSidToStringSidW(owner,&mut text)}!=0;
    let trusted=if ok&&!text.is_null(){let mut length=0;while length<256&&unsafe{*text.add(length)}!=0{length+=1}
        let sid=String::from_utf16_lossy(unsafe{std::slice::from_raw_parts(text,length)});sid=="S-1-5-32-544"||sid=="S-1-5-18"}else{false};
    if !text.is_null(){unsafe{LocalFree(text.cast());}}if !security.is_null(){unsafe{LocalFree(security);}}
    if !trusted{return Err("Protected discovery cache file is not administrator-owned.".into())}
    Ok(())
}
fn service_manager()->Result<ServiceHandle,String>{
    let handle=unsafe{OpenSCManagerW(std::ptr::null(),std::ptr::null(),3)};
    if handle.is_null(){Err("Installing or removing fast NTFS discovery requires Windows administrator permission.".into())}else{Ok(ServiceHandle(handle))}
}
fn stop(service:HandleValue)->Result<(),String>{
    let mut status=Status{kind:0,state:0,controls:0,exit:0,specific:0,checkpoint:0,hint:0};
    if unsafe{QueryServiceStatus(service,&mut status)}==0{return Err(volume::error())}
    if status.state==1{return Ok(())}
    if unsafe{ControlService(service,1,&mut status)}==0{
        let code=std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
        if code!=1062{return Err(format!("Cannot stop the discovery component (Windows {code})."))}
    }
    let deadline=Instant::now()+Duration::from_secs(30);
    loop{
        if unsafe{QueryServiceStatus(service,&mut status)}==0{return Err(volume::error())}
        if status.state==1{return Ok(())}
        if Instant::now()>=deadline{return Err("The discovery component is still stopping. Retry the update after it stops.".into())}
        std::thread::sleep(Duration::from_millis(50));
    }
}
pub struct Replacement {target:PathBuf,backup:Option<PathBuf>,pending:PathBuf,committed:bool}
impl Drop for Replacement{
    fn drop(&mut self){
        if !self.committed{
            let _=std::fs::remove_file(&self.target);
            if let Some(backup)=&self.backup{let _=std::fs::rename(backup,&self.target);}
        }else if let Some(backup)=&self.backup{let _=std::fs::remove_file(backup);}
        let _=std::fs::remove_file(&self.pending);
    }
}
fn install()->Result<(),String>{
    let manager=service_manager()?;
    let root=known_folder(true)?;secure_directory(&root,true)?;
    use std::os::windows::fs::OpenOptionsExt;
    let _installation_lock=std::fs::OpenOptions::new().write(true).create(true).truncate(false).share_mode(0)
        .open(root.join("installation.lock")).map_err(|e|format!("Another discovery installation may be in progress: {e}"))?;
    let target=root.join("digup-discovery.exe");
    let existing=unsafe{OpenServiceW(manager.0,wide(ipc::SERVICE_NAME).as_ptr(),0x000f01ff)};
    let existing=(!existing.is_null()).then_some(ServiceHandle(existing));
    if let Some(service)=&existing{stop(service.0)?;}
    let source=std::env::current_exe().map_err(|e|e.to_string())?;
    let mut replacement=None;
    if source!=target {
        let pending=root.join(format!("component-{}.new",std::process::id()));
        let mut from=std::fs::File::open(source).map_err(|e|e.to_string())?;
        let mut to=std::fs::OpenOptions::new().write(true).create_new(true).open(&pending).map_err(|e|e.to_string())?;
        std::io::copy(&mut from,&mut to).map_err(|e|e.to_string())?;to.sync_all().map_err(|e|e.to_string())?;drop(to);
        let backup=if target.exists(){let backup=root.join(format!("component-{}.backup",std::process::id()));
            std::fs::rename(&target,&backup).map_err(|e|e.to_string())?;Some(backup)}else{None};
        replacement=Some(Replacement{target:target.clone(),backup,pending:pending.clone(),committed:false});
        std::fs::rename(&pending,&target).map_err(|e|e.to_string())?;
    }
    let created=existing.is_none();
    let binary=format!("\"{}\" --service",target.display());
    let service=if let Some(service)=existing{
        if unsafe{ChangeServiceConfigW(service.0,16,3,1,wide(&binary).as_ptr(),std::ptr::null(),std::ptr::null_mut(),std::ptr::null(),std::ptr::null(),std::ptr::null(),std::ptr::null())}==0{return Err(volume::error())}
        service
    }else{
        let handle=unsafe{CreateServiceW(manager.0,wide(ipc::SERVICE_NAME).as_ptr(),wide("DigUp optional NTFS discovery").as_ptr(),0x000f01ff,16,3,1,wide(&binary).as_ptr(),std::ptr::null(),std::ptr::null_mut(),std::ptr::null(),std::ptr::null(),std::ptr::null())};
        if handle.is_null(){return Err(volume::error())}ServiceHandle(handle)
    };
    let mut security=std::ptr::null_mut();
    let acl="D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWRPLO;;;AU)";
    if unsafe{ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(acl).as_ptr(),1,&mut security,std::ptr::null_mut())}==0{return Err(volume::error())}
    let ok=unsafe{SetServiceObjectSecurity(service.0,4,security)}!=0;unsafe{LocalFree(security)};
    if !ok{if created{unsafe{DeleteService(service.0);}}return Err(volume::error())}
    if let Some(replacement)=replacement.as_mut(){replacement.committed=true;}
    Ok(())
}
pub fn uninstall()->Result<(),String>{
    let manager=service_manager()?;
    let handle=unsafe{OpenServiceW(manager.0,wide(ipc::SERVICE_NAME).as_ptr(),0x000f01ff)};
    if handle.is_null(){return Ok(())}
    let service=ServiceHandle(handle);stop(service.0)?;
    if unsafe{DeleteService(service.0)}==0{return Err(volume::error())}
    Ok(())
}
struct Shared {stop:Arc<AtomicBool>,held:Mutex<Instant>,disks:Arc<crate::discovery::scheduler::Gate>,clients:AtomicUsize}
impl Shared {
    fn quiet(&self)->Result<(),String>{
        while Instant::now()<*self.held.lock().unwrap(){
            if self.stop.load(Ordering::SeqCst){return Err("Discovery stopped.".into())}
            std::thread::sleep(Duration::from_millis(25));
        }
        if self.stop.load(Ordering::SeqCst){Err("Discovery stopped.".into())}else{Ok(())}
    }
}
fn serve(stop:Arc<AtomicBool>)->Result<(),String>{
    let root=known_folder(false)?;secure_directory(&root,false)?;
    let shared=Arc::new(Shared{stop:stop.clone(),held:Mutex::new(Instant::now()),disks:crate::discovery::scheduler::Gate::new(crate::discovery::scheduler::Mode::Scan),clients:AtomicUsize::new(0)});
    report(4);let mut first=true;let mut last_client=Instant::now();
    while !stop.load(Ordering::SeqCst){
        let pipe=match ipc::listener(first,stop.clone()){Ok(pipe)=>pipe,Err(_)if stop.load(Ordering::SeqCst)=>break,
            Err(e)if e=="idle"||e=="retry"=>{if shared.clients.load(Ordering::SeqCst)==0&&last_client.elapsed()>Duration::from_secs(120){break}first=shared.clients.load(Ordering::SeqCst)==0;continue},Err(e)=>return Err(e)};
        first=false;last_client=Instant::now();
        if shared.clients.load(Ordering::SeqCst)>=8{continue}
        shared.clients.fetch_add(1,Ordering::SeqCst);
        let shared=shared.clone();let root=root.clone();
        std::thread::spawn(move||{
            let result=connection(&pipe,&shared,&root);
            if let Err(message)=result{let _=pipe.send(&json!({"version":1,"kind":"error","message":message.chars().take(512).collect::<String>()}));}
            shared.clients.fetch_sub(1,Ordering::SeqCst);
        });
    }
    let deadline=Instant::now()+Duration::from_secs(4);
    while shared.clients.load(Ordering::SeqCst)>0&&Instant::now()<deadline{std::thread::sleep(Duration::from_millis(25));}
    Ok(())
}
fn connection(pipe:&Pipe,shared:&Shared,root:&Path)->Result<(),String>{
    let request=pipe.receive()?;
    // This also establishes a valid local user token before any volume operation.
    {let _client=ipc::Impersonation::client(pipe)?;}
    match request["op"].as_str(){
        Some("foreground")=>{*shared.held.lock().unwrap()=Instant::now()+Duration::from_secs(1);return pipe.send(&json!({"version":1,"kind":"ok"}))}
        Some("topology")=>{
            let ids=request["volumes"].as_array().ok_or("Select discovery volumes.")?;
            if ids.len()>64 || ids.iter().any(|id|!id.as_str().is_some_and(crate::discovery::valid_volume)){
                return Err("Select valid discovery volumes.".into())
            }
            let rows:Vec<_>=ids.iter().map(|id|json!({"id":id,"topology":volume::topology(id.as_str().unwrap())})).collect();
            return pipe.send(&json!({"version":1,"kind":"topology","schedulerVersion":1,"volumes":rows}))
        },
        Some("status")=>return pipe.send(&json!({"version":1,"kind":"status","service":"ready","protocol":1,"diskSchedulerVersion":1})),
        Some("scan")=>{},
        _=>return Err("Unsupported discovery operation.".into()),
    }
    let id=request["volume"].as_str().ok_or("Choose a discovery volume.")?;
    if !crate::discovery::valid_volume(id){return Err("Invalid discovery volume.".into())}
    use crate::discovery::scheduler::Resource;
    let topology=volume::topology(id);
    let ticket=shared.disks.request(Resource{volume:id.into(),topology});
    let started=Instant::now();let mut last=Instant::now()-Duration::from_secs(1);
    let _lease=loop{
        shared.quiet()?;
        if let Some(lease)=ticket.try_start(){break lease}
        if started.elapsed()>Duration::from_secs(60){return Err("Another scan is still using this physical disk. Retry later.".into())}
        if last.elapsed()>Duration::from_millis(500){
            pipe.send(&json!({"version":1,"kind":"progress","phase":"waiting","total":null,
                "message":"Waiting for another scan on this physical disk."}))?;last=Instant::now();
        }
        std::thread::sleep(Duration::from_millis(25));
    };
    scan(pipe,shared,root,id,request["full"].as_bool().unwrap_or(false),request["knownRevision"].as_str().unwrap_or(""))

}
fn scan(pipe:&Pipe,shared:&Shared,root:&Path,id:&str,full:bool,known:&str)->Result<(),String>{
    let mut timings=crate::discovery::metrics::Timings::default();
    let volume=volume::Volume::open(id)?;let journal=volume.journal()?;
    let name=format!("{:x}.sqlite",Sha256::digest(id.as_bytes()));let file=root.join(name);
    for suffix in ["","-wal","-shm"]{verify_inventory_file(&PathBuf::from(format!("{}{suffix}",file.display())))?;}
    let store=VolumeStore::recovering(&file)?;
    let old_journal=store.get("journal")?.and_then(|s|s.parse::<u64>().ok());
    let old_cursor=store.get("cursor")?.and_then(|s|s.parse::<i64>().ok());
    let old_serial=store.get("serial")?.and_then(|s|s.parse::<u32>().ok());
    let fresh=full||store.get("complete")?.as_deref()!=Some("true")||old_serial!=Some(volume.serial)
        ||old_journal!=Some(journal.id)||old_cursor.is_none_or(|c|c<journal.first||c<journal.lowest||c>journal.next);
    if old_serial.is_some_and(|serial|serial!=volume.serial){
        store.db.run("DELETE FROM launch_links",&[])?;store.db.run("DELETE FROM pending_renames",&[])?;
    }
    let identity_scope=format!("{id}|{}",volume.serial);
    let mut records=0u64;let mut relevant=fresh;
    let mut cursor=if fresh{journal.next}else{old_cursor.unwrap()};
    if fresh{
        store.clear()?;let mut start=0;
        loop{
            shared.quiet()?;
            let measured=Instant::now();
            let next_batch=volume.enumerate(start)?;timings.record("enumeration",measured,next_batch.as_ref().map_or(0,|(_,b)|b.len()as u64));
            let Some((next,batch))=next_batch else{break};
            if next<=start{return Err("NTFS enumeration did not advance.".into())}
            let measured=Instant::now();store.apply(&batch,false)?;timings.record("databaseCommit",measured,batch.len()as u64);
            records+=batch.len()as u64;start=next;
            pipe.send(&json!({"version":1,"kind":"progress","phase":"enumerating","records":records,"total":null,"timings":timings}))?;
        }
    }
    // Replay from the checkpoint taken BEFORE enumeration, covering changes made during the baseline.
    let mut rounds=0u32;
    loop{
        shared.quiet()?;let current=volume.journal()?;
        if current.id!=journal.id||cursor<current.first||cursor<current.lowest{return Err("NTFS journal history changed; a new reconciliation is required.".into())}
        if cursor>=current.next{break}
        let measured=Instant::now();let(next,batch)=volume.changes(cursor,journal.id)?;
        timings.record("enumeration",measured,batch.len()as u64);
        if next<=cursor{return Err("NTFS journal did not advance.".into())}
        relevant|=batch.iter().any(|r|r.executable()||r.reason&0x10000!=0
            ||(r.directory()&&r.reason&(0x100|0x200|0x800|0x1000|0x2000|0x100000)!=0));
        let measured=Instant::now();store.apply(&batch,true)?;timings.record("databaseCommit",measured,batch.len()as u64);
        // Unlinking one hard link must not remove the remaining application's file identity.
        for record in batch.iter().filter(|r|r.reason&(0x200|0x10000)!=0){
            if let Some(live)=volume.live_record(record){
                let file=live.id.text();let linked=!live.directory();store.apply(&[live],false)?;
                if linked{store.db.run("UPDATE nodes SET executable=1 WHERE id=?",&[crate::discovery::db::Value::Text(&file)])?;}
            }
        }
        records+=batch.len()as u64;cursor=next;rounds+=1;
        if rounds>100_000{return Err("NTFS journal is changing too quickly; retry when the volume is quieter.".into())}
        pipe.send(&json!({"version":1,"kind":"progress","phase":"reconciling","records":records,"total":null,"timings":timings}))?;
    }
    store.put("journal",&journal.id.to_string())?;store.put("cursor",&cursor.to_string())?;
    store.put("serial",&volume.serial.to_string())?;store.put("complete","true")?;
    // Unrelated document writes advance the journal cursor without invalidating the executable catalog.
    if relevant||store.get("application_revision")?.is_none(){store.put("application_revision",&cursor.to_string())?;}
    let application_revision=store.get("application_revision")?.unwrap_or_else(||cursor.to_string());
    let revision=format!("{}-{}-{}",volume.serial,journal.id,application_revision);
    if !fresh&&revision==known{return pipe.send(&json!({"version":1,"kind":"complete","revision":revision,"unchanged":true,"records":records,"timings":timings}))}
    let mut after=String::new();let mut candidates=0u64;
    loop{
        let ids=store.executable_ids(&after,256)?;if ids.is_empty(){break}
        for file_id in ids{
            shared.quiet()?;after=file_id.clone();
            let measured=Instant::now();let path=store.path(&file_id,id,&volume.root.text())?;
            timings.record("pathResolution",measured,1);
            let Some(path)=path else{continue};
            // Permission checks and hard-link name retrieval run as the requesting user, never SYSTEM.
            let measured=Instant::now();let permitted={
                let _client=ipc::Impersonation::client(pipe)?;
                match volume::file_info(&path){
                    Ok(info)if info.id().text()==file_id=>{
                        volume::hard_links(&path,id).into_iter().filter(|p|p.to_lowercase().ends_with(".exe"))
                            .filter_map(|p|volume::file_info(&p).ok().filter(|i|i.id().text()==file_id).map(|i|(p,i.stamp()))).collect::<Vec<_>>()
                    },
                    _=>vec![],
                }
            };
            timings.record("permissionChecks",measured,permitted.len()as u64);
            for(path,stamp)in permitted{
                let parent=Path::new(&path).parent().map(|p|p.to_string_lossy().into_owned()).unwrap_or_default();
                let parent_id={let _client=ipc::Impersonation::client(pipe)?;
                    let handle=unsafe{volume::CreateFileW(wide(&parent).as_ptr(),0,7,std::ptr::null(),3,0x02000000,std::ptr::null_mut())};
                    if handle==(-1isize as HandleValue){continue}
                    let handle=volume::Handle(handle);let mut info=volume::FileInfo::default();
                    if unsafe{volume::GetFileInformationByHandle(handle.0,&mut info)}==0{continue}info.id().text()};
                let link_name=Path::new(&path).file_name().unwrap_or_default().to_string_lossy();
                let candidate_id=store.launch_identity(&identity_scope,&file_id,&parent_id,&link_name)?;
                candidates+=1;
                pipe.send(&json!({"version":1,"kind":"candidate","candidate":{"id":candidate_id,"volume":id,
                    "fileId":file_id,"path":path,"fileStamp":stamp}}))?;
            }
        }
        pipe.send(&json!({"version":1,"kind":"progress","phase":"resolving","records":records,"candidates":candidates,"total":null,"timings":timings}))?;
    }
    pipe.send(&json!({"version":1,"kind":"complete","revision":revision,"unchanged":false,"records":records,"candidates":candidates,"timings":timings}))
}
fn probe()->Result<(),String>{
    let args=std::env::args().collect::<Vec<_>>();
    let volume=args.windows(2).find(|a|a[0]=="--volume").map(|a|a[1].clone()).ok_or("Specify --volume with a Windows volume GUID.")?;
    if !crate::discovery::valid_volume(&volume){return Err("Invalid probe volume.".into())}
    let expected=args.windows(2).find(|a|a[0]=="--expect-name").map(|a|a[1].clone());
    let absent=args.windows(2).find(|a|a[0]=="--expect-absent-name").map(|a|a[1].clone());
    let cancel=Arc::new(AtomicBool::new(false));let pipe=Pipe::connect(cancel)?;
    pipe.send(&json!({"version":1,"op":"scan","volume":volume,"full":args.iter().any(|a|a=="--full")}))?;
    let started=Instant::now();let mut candidates=0u64;let mut found=false;let mut forbidden=false;let mut expected_id=String::new();let mut progress=0u64;
    loop{
        if started.elapsed()>Duration::from_secs(180){return Err("Discovery probe exceeded its deadline.".into())}
        let response=pipe.receive()?;
        match response["kind"].as_str(){
            Some("candidate")=>{
                candidates+=1;
                let name=response["candidate"]["path"].as_str().and_then(|p|Path::new(p).file_name()).map(|p|p.to_string_lossy().into_owned());
                if expected.as_ref().is_some_and(|e|name.as_ref()==Some(e)){
                    found=true;expected_id=response["candidate"]["id"].as_str().unwrap_or("").into();
                }
                forbidden|=absent.as_ref().is_some_and(|e|name.as_ref()==Some(e));
            },
            Some("progress")=>progress+=1,
            Some("complete")=>{
                println!("{}",json!({"ok":true,"kind":"probe","candidates":candidates,"foundExpected":found,
                    "progressEvents":progress,"expectedId":expected_id,"forbiddenFound":forbidden,"records":response["records"],"revision":response["revision"],
                    "elapsedMs":started.elapsed().as_secs_f64()*1000.0,"timings":response["timings"]}));
                if forbidden{return Err("Discovery returned an executable denied to this user.".into())}
                if expected.is_some()&&!found{return Err("The expected executable was not discovered for this user.".into())}return Ok(())
            },
            Some("error")=>return Err(response["message"].as_str().unwrap_or("Discovery probe failed.").into()),
            _=>return Err("Unexpected discovery probe reply.".into()),
        }
    }
}
pub fn main()->Result<(),String>{
    match std::env::args().nth(1).as_deref(){
        Some("--probe")=>probe(),
        Some("--install")=>install(),Some("--uninstall")=>uninstall(),
        Some("--service")=>{
            let mut name=wide(ipc::SERVICE_NAME);
            let entries=[ServiceEntry{name:name.as_mut_ptr(),entry:Some(entry)},ServiceEntry{name:std::ptr::null_mut(),entry:None}];
            if unsafe{StartServiceCtrlDispatcherW(entries.as_ptr())}==0{Err("Start this component through Windows Services.".into())}else{Ok(())}
        },
        _=>Err("Use DigUp Settings → Apps to configure optional NTFS discovery.".into()),
    }
}
