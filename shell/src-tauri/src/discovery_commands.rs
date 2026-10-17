use crate::{discovery::{Options,store::CandidateStore},Shell};
use serde_json::{json,Value};
use std::{sync::Arc,path::PathBuf};
use tauri::{AppHandle,State};

#[tauri::command]
pub fn discovery_status(shell:State<'_,Arc<Shell>>)->Value{shell.discovery.info()}
#[tauri::command]
pub fn discovery_volumes(shell:State<'_,Arc<Shell>>)->Value{shell.discovery.info()["volumes"].clone()}
#[tauri::command]
pub fn refresh_discovery_volumes(shell:State<'_,Arc<Shell>>)->Value{
    shell.discovery.request_volumes();shell.discovery.info()
}
#[tauri::command]
pub fn refresh_discovery(shell:State<'_,Arc<Shell>>,full:Option<bool>)->Value{
    shell.discovery.schedule(full.unwrap_or(false));shell.discovery.info()
}
#[tauri::command]
pub fn set_discovery_options(shell:State<'_,Arc<Shell>>,mut options:Options)->Result<Value,String>{
    options.validate()?;
    let mut current=shell.settings.lock().unwrap();let mut next=current.clone();
    options.included=current.discovery.included.clone();options.hidden=current.discovery.hidden.clone();
    options.revision=current.discovery.revision.checked_add(1).ok_or("Discovery settings revision overflowed.")?;
    next.discovery=options.clone();
    next.save(&shell.settings_path).map_err(|e|e.to_string())?;*current=next;drop(current);
    shell.discovery.configure(options);Ok(shell.discovery.info())
}
#[tauri::command]
pub async fn discovery_candidates(shell:State<'_,Arc<Shell>>,q:Option<String>,classification:Option<String>,
    offset:Option<usize>,limit:Option<usize>,generation:Option<u64>)->Result<Value,String>{
    let q=q.unwrap_or_default();if q.chars().count()>4096{return Err("Candidate query is too long.".into())}
    let classification=classification.unwrap_or_else(||"review".into());
    if !["review","accepted","hidden","excluded","all"].contains(&classification.as_str()){return Err("Unknown candidate filter.".into())}
    let file=shell.discovery.root().join("discovery.sqlite");
    tauri::async_runtime::spawn_blocking(move||{
        if !file.is_file(){return Ok(json!({"hits":[],"total":0,"generation":generation}))}
        let db=CandidateStore::read(&file)?;
        let(hits,total)=db.list(&q,&classification,offset.unwrap_or(0),limit.unwrap_or(50))?;
        let catalog_total=db.list("","all",0,1)?.1;
        Ok(json!({"hits":hits,"total":total,"catalogTotal":catalog_total,"generation":generation}))
    }).await.map_err(|e|e.to_string())?
}
#[tauri::command]
pub async fn set_discovery_candidate(shell:State<'_,Arc<Shell>>,candidate_id:String,action:String)->Result<Value,String>{
    if !crate::discovery::valid_candidate_id(&candidate_id)||!["include","hide","reset"].contains(&action.as_str()){
        return Err("Invalid executable discovery action.".into())
    }
    let file=shell.discovery.root().join("discovery.sqlite");let id=candidate_id.clone();
    let candidate=tauri::async_runtime::spawn_blocking(move||CandidateStore::read(&file)?.get(&id))
        .await.map_err(|e|e.to_string())??.ok_or("This executable is no longer available.")?;
    if action=="include"&&!candidate.portable{return Err("This file could not be identified as a Windows executable.".into())}
    let options={
        let mut current=shell.settings.lock().unwrap();let mut next=current.clone();
        next.discovery.revision=next.discovery.revision.checked_add(1).ok_or("Discovery settings revision overflowed.")?;
        next.discovery.included.remove(&candidate_id);next.discovery.hidden.remove(&candidate_id);
        if action=="include"{next.discovery.included.insert(candidate_id);}
        else if action=="hide"{next.discovery.hidden.insert(candidate_id);}
        next.save(&shell.settings_path).map_err(|e|e.to_string())?;*current=next;current.discovery.clone()
    };
    shell.discovery.configure(options);Ok(shell.discovery.info())
}
fn component(shell:&Shell)->Result<PathBuf,String>{
    let sibling=shell.options.helper.parent().ok_or("Cannot locate the packaged discovery component.")?.join("digup-discovery.exe");
    if sibling.is_file(){return Ok(sibling)}
    let development=std::env::current_exe().ok().and_then(|p|p.parent().map(|p|p.join("digup-discovery.exe")));
    development.filter(|p|p.is_file()).ok_or("The optional discovery component is missing. Install the complete Windows package.".into())
}
#[tauri::command]
pub async fn install_discovery_component(shell:State<'_,Arc<Shell>>)->Result<Value,String>{
    let executable=component(&shell)?;
    tauri::async_runtime::spawn_blocking(move||install(&executable)).await.map_err(|e|e.to_string())??;
    shell.discovery.schedule(false);Ok(shell.discovery.info())
}
#[cfg(windows)]
fn install(path:&std::path::Path)->Result<(),String>{
    use windows::{core::PCWSTR,Win32::UI::{Shell::{ShellExecuteExW,SHELLEXECUTEINFOW,SEE_MASK_NOCLOSEPROCESS,SEE_MASK_NOASYNC,SEE_MASK_FLAG_NO_UI},
        WindowsAndMessaging::SW_SHOWNORMAL}};
    use std::ffi::c_void;
    #[link(name="kernel32")]unsafe extern "system"{
        fn WaitForSingleObject(handle:*mut c_void,ms:u32)->u32;
        fn GetExitCodeProcess(handle:*mut c_void,code:*mut u32)->i32;
    }
    use windows::Win32::System::Com::{CoInitializeEx,CoUninitialize,COINIT_APARTMENTTHREADED};
    struct Apartment(bool);impl Drop for Apartment{fn drop(&mut self){if self.0{unsafe{CoUninitialize()}}}}
    let _apartment=Apartment(unsafe{CoInitializeEx(None,COINIT_APARTMENTTHREADED)}.is_ok());
    let verb=crate::discovery::volume::wide("runas");
    let file=crate::discovery::volume::wide(&path.to_string_lossy());
    let args=crate::discovery::volume::wide("--install");
    let mut info=SHELLEXECUTEINFOW{cbSize:std::mem::size_of::<SHELLEXECUTEINFOW>()as u32,
        fMask:SEE_MASK_NOCLOSEPROCESS|SEE_MASK_NOASYNC|SEE_MASK_FLAG_NO_UI,lpVerb:PCWSTR(verb.as_ptr()),lpFile:PCWSTR(file.as_ptr()),
        lpParameters:PCWSTR(args.as_ptr()),nShow:SW_SHOWNORMAL.0,..Default::default()};
    unsafe{ShellExecuteExW(&mut info)}.map_err(|e|if e.code().0&0xffff==1223{
        "Administrator permission was declined. Directory discovery remains available.".into()
    }else{format!("Windows could not install fast discovery: {e}")})?;
    if info.hProcess.is_invalid(){return Err("Windows did not return an installer process.".into())}
    let process=crate::discovery::volume::Handle(info.hProcess.0);
    if unsafe{WaitForSingleObject(process.0,60_000)}!=0{
        return Err("The discovery installer has not completed. Check the Windows permission dialog before trying again.".into())
    }
    let mut code=1;if unsafe{GetExitCodeProcess(process.0,&mut code)}==0||code!=0{
        return Err("The discovery component was not installed. Directory discovery remains available; see Activity.".into())
    }
    Ok(())
}
#[cfg(not(windows))]
fn install(_path:&std::path::Path)->Result<(),String>{Err("Fast NTFS discovery is available on Windows.".into())}
