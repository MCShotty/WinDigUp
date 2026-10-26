//! Local authenticated service transport. Frames are bounded; reads/writes have cancellation and deadlines.
use super::{volume::{Handle,HandleValue,wide,error},MAX_FRAME_BYTES,PROTOCOL_VERSION};
use serde_json::Value;
use std::{ffi::c_void,sync::{Arc,atomic::{AtomicBool,Ordering}},time::{Duration,Instant}};
pub const SERVICE_NAME:&str="DigUpDiscovery";
pub const PIPE_NAME:&str=r"\\.\pipe\DigUp.Discovery.v1";
#[link(name="kernel32")]unsafe extern "system" {
    fn ReadFile(handle:HandleValue,buffer:*mut c_void,count:u32,read:*mut u32,overlapped:*mut c_void)->i32;
    fn WriteFile(handle:HandleValue,buffer:*const c_void,count:u32,written:*mut u32,overlapped:*mut c_void)->i32;
    fn CreateNamedPipeW(name:*const u16,open:u32,mode:u32,instances:u32,out_buffer:u32,in_buffer:u32,timeout:u32,security:*const SecurityAttributes)->HandleValue;
    fn ConnectNamedPipe(handle:HandleValue,overlapped:*mut c_void)->i32;
    fn SetNamedPipeHandleState(handle:HandleValue,mode:*const u32,max:*const u32,timeout:*const u32)->i32;
    fn GetNamedPipeClientProcessId(handle:HandleValue,pid:*mut u32)->i32;
    fn GetNamedPipeServerProcessId(handle:HandleValue,pid:*mut u32)->i32;
    fn LocalFree(memory:*mut c_void)->*mut c_void;
}
#[link(name="advapi32")]unsafe extern "system" {
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl:*const u16,revision:u32,descriptor:*mut *mut c_void,size:*mut u32)->i32;
    fn OpenSCManagerW(machine:*const u16,database:*const u16,access:u32)->HandleValue;
    fn OpenServiceW(manager:HandleValue,name:*const u16,access:u32)->HandleValue;
    fn StartServiceW(service:HandleValue,count:u32,args:*const *const u16)->i32;
    fn QueryServiceStatusEx(service:HandleValue,kind:u32,status:*mut u8,size:u32,needed:*mut u32)->i32;
    fn CloseServiceHandle(handle:HandleValue)->i32;
    pub fn ImpersonateNamedPipeClient(pipe:HandleValue)->i32;
    pub fn RevertToSelf()->i32;
}
#[repr(C)]struct SecurityAttributes {length:u32,descriptor:*mut c_void,inherit:i32}
struct ServiceHandle(HandleValue);
impl Drop for ServiceHandle {fn drop(&mut self){unsafe{CloseServiceHandle(self.0);}}}
#[repr(C)]#[derive(Default)]struct ServiceStatus {kind:u32,state:u32,controls:u32,exit:u32,specific:u32,checkpoint:u32,hint:u32,pid:u32,flags:u32}
fn service_pid(start:bool)->Result<u32,String>{
    let manager=unsafe{OpenSCManagerW(std::ptr::null(),std::ptr::null(),1)};
    if manager.is_null(){return Err(error())}
    let manager=ServiceHandle(manager);
    let service=unsafe{OpenServiceW(manager.0,wide(SERVICE_NAME).as_ptr(),4|if start{16}else{0})};
    if service.is_null(){return Err("Fast NTFS discovery is not installed. Enable it in Settings → Apps, or use directory scanning.".into())}
    let service=ServiceHandle(service);let mut status=ServiceStatus::default();let mut needed=0;
    if unsafe{QueryServiceStatusEx(service.0,0,(&mut status as *mut ServiceStatus).cast(),std::mem::size_of::<ServiceStatus>()as u32,&mut needed)}==0{return Err(error())}
    if status.state==1&&start {
        if unsafe{StartServiceW(service.0,0,std::ptr::null())}==0 {
            let code=std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            if code!=1056{return Err(format!("The discovery service could not start: {}",error()))}
        }
        return Ok(0)
    }
    Ok(if status.state==4{status.pid}else{0})
}
pub struct Pipe {pub handle:Handle,cancel:Arc<AtomicBool>}
impl Pipe {
    pub fn new(handle:Handle,cancel:Arc<AtomicBool>)->Self{Self{handle,cancel}}
    pub fn connect(cancel:Arc<AtomicBool>)->Result<Self,String>{
        let _=service_pid(true)?;
        let deadline=Instant::now()+Duration::from_secs(5);
        loop {
            if cancel.load(Ordering::SeqCst){return Err("Discovery cancelled.".into())}
            let handle=unsafe{super::volume::CreateFileW(wide(PIPE_NAME).as_ptr(),0x12019b,0,std::ptr::null(),3,0,std::ptr::null_mut())};
            if handle!=(-1isize as HandleValue) {
                let handle=Handle(handle);let mut pid=0;
                if unsafe{GetNamedPipeServerProcessId(handle.0,&mut pid)}==0||pid==0||service_pid(false)?!=pid {
                    return Err("The discovery pipe does not belong to the installed Windows service.".into())
                }
                let mode=1u32;
                if unsafe{SetNamedPipeHandleState(handle.0,&mode,std::ptr::null(),std::ptr::null())}==0{return Err(error())}
                return Ok(Self{handle,cancel})
            }
            if Instant::now()>=deadline{return Err(format!("The discovery service is unavailable: {}",error()))}
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    fn transfer(&self,bytes:&mut[u8],write:bool)->Result<(),String>{
        let deadline=Instant::now()+Duration::from_secs(90);
        let mut offset=0;
        while offset<bytes.len() {
            if self.cancel.load(Ordering::SeqCst){return Err("Discovery cancelled.".into())}
            let mut transferred=0;
            let ok=unsafe{if write {WriteFile(self.handle.0,bytes[offset..].as_ptr().cast(),(bytes.len()-offset)as u32,&mut transferred,std::ptr::null_mut())}
                else{ReadFile(self.handle.0,bytes[offset..].as_mut_ptr().cast(),(bytes.len()-offset)as u32,&mut transferred,std::ptr::null_mut())}};
            if ok!=0&&transferred>0{offset+=transferred as usize;continue}
            let code=std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            if ok==0&&code!=232{return Err(format!("Discovery connection ended (Windows {code})."))}
            if Instant::now()>=deadline{return Err("The discovery service stopped responding.".into())}
            std::thread::sleep(Duration::from_millis(10));
        }
        Ok(())
    }
    pub fn send(&self,value:&Value)->Result<(),String>{
        let data=serde_json::to_vec(value).map_err(|e|e.to_string())?;
        if data.len()>MAX_FRAME_BYTES{return Err("Discovery message is too large.".into())}
        let mut frame=Vec::with_capacity(4+data.len());frame.extend_from_slice(&(data.len()as u32).to_le_bytes());frame.extend(data);
        self.transfer(&mut frame,true)
    }
    pub fn receive(&self)->Result<Value,String>{
        let mut header=[0u8;4];self.transfer(&mut header,false)?;
        let count=u32::from_le_bytes(header)as usize;
        if count==0||count>MAX_FRAME_BYTES{return Err("Invalid discovery message length.".into())}
        let mut bytes=vec![0;count];self.transfer(&mut bytes,false)?;
        let value:Value=serde_json::from_slice(&bytes).map_err(|_|"Invalid discovery message.")?;
        if value["version"].as_u64()!=Some(PROTOCOL_VERSION as u64){return Err("Discovery component version mismatch. Update DigUp and its optional component.".into())}
        Ok(value)
    }
}
pub fn listener(first:bool,cancel:Arc<AtomicBool>)->Result<Pipe,String>{
    let mut descriptor=std::ptr::null_mut();
    // Explicit rights exclude FILE_CREATE_PIPE_INSTANCE, which generic write would grant.
    if unsafe{ConvertStringSecurityDescriptorToSecurityDescriptorW(wide("D:P(A;;GA;;;SY)(A;;0x12019b;;;AU)").as_ptr(),1,&mut descriptor,std::ptr::null_mut())}==0{return Err(error())}
    let attributes=SecurityAttributes{length:std::mem::size_of::<SecurityAttributes>()as u32,descriptor,inherit:0};
    let handle=unsafe{CreateNamedPipeW(wide(PIPE_NAME).as_ptr(),3|if first{0x00080000}else{0},1|8,8,65536,65536,1000,&attributes)};
    unsafe{LocalFree(descriptor)};
    if handle==(-1isize as HandleValue){return Err(error())}
    let pipe=Pipe::new(Handle(handle),cancel.clone());
    let started=Instant::now();
    loop {
        if cancel.load(Ordering::SeqCst){return Err("Discovery service stopped.".into())}
        let ready=unsafe{ConnectNamedPipe(pipe.handle.0,std::ptr::null_mut())}!=0;
        let code=if ready{536}else{std::io::Error::last_os_error().raw_os_error().unwrap_or(0)};
        let mut client=0;
        if unsafe{GetNamedPipeClientProcessId(pipe.handle.0,&mut client)}!=0&&client!=0{return Ok(pipe)}
        if code==232||code==109{return Err("retry".into())}
        if code!=536&&code!=535{return Err(format!("Cannot accept discovery client (Windows {code})."))}
        if started.elapsed()>Duration::from_secs(1){return Err("idle".into())}
        std::thread::sleep(Duration::from_millis(25));
    }
}
pub struct Impersonation;
impl Impersonation {
    pub fn client(pipe:&Pipe)->Result<Self,String>{
        if unsafe{ImpersonateNamedPipeClient(pipe.handle.0)}==0 {Err("Cannot verify discovery client permissions.".into())}else{Ok(Self)}
    }
}
impl Drop for Impersonation {fn drop(&mut self){if unsafe{RevertToSelf()}==0{std::process::abort();}}}
