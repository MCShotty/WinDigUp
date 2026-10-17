//! Windows filesystem controls. Handles are read-only and confined to their owning scan.
use super::{ntfs::{self,FileId,Record},valid_volume,MAX_FRAME_BYTES};
use serde::{Deserialize,Serialize};
use std::{ffi::c_void,path::Path,io::{Read,Seek,SeekFrom}};
pub type HandleValue=*mut c_void;
const INVALID:HandleValue=-1isize as HandleValue;
pub struct Handle(pub HandleValue);
unsafe impl Send for Handle {}
impl Drop for Handle {fn drop(&mut self){if !self.0.is_null()&&self.0!=INVALID{unsafe{CloseHandle(self.0);}}}}
pub fn wide(s:&str)->Vec<u16>{s.encode_utf16().chain(Some(0)).collect()}
pub fn error()->String {std::io::Error::last_os_error().to_string()}
#[repr(C)]#[derive(Default)]pub struct FileInfo {
    attrs:u32,created:[u32;2],accessed:[u32;2],written:[u32;2],serial:u32,
    size_high:u32,size_low:u32,links:u32,index_high:u32,index_low:u32,
}
impl FileInfo {
    pub fn serial(&self)->u32{self.serial}
    pub fn links(&self)->u32{self.links}
    pub fn id(&self)->FileId {let mut bytes=[0;16];bytes[..8].copy_from_slice(&(((self.index_high as u64)<<32)|self.index_low as u64).to_le_bytes());FileId(bytes)}
    pub fn stamp(&self)->String{format!("{}:{}:{}:{}:{}",self.serial,self.size_high,self.size_low,self.written[0],self.written[1])}
}
#[link(name="kernel32")]unsafe extern "system" {
    pub fn CloseHandle(handle:HandleValue)->i32;
    pub fn CreateFileW(path:*const u16,access:u32,share:u32,security:*const c_void,creation:u32,flags:u32,template:HandleValue)->HandleValue;
    pub fn DeviceIoControl(handle:HandleValue,code:u32,input:*const c_void,input_size:u32,output:*mut c_void,output_size:u32,returned:*mut u32,overlapped:*mut c_void)->i32;
    pub fn GetFileInformationByHandle(handle:HandleValue,info:*mut FileInfo)->i32;
    fn SetThreadErrorMode(mode:u32,old:*mut u32)->i32;
    fn FindFirstVolumeW(name:*mut u16,length:u32)->HandleValue;
    fn FindNextVolumeW(handle:HandleValue,name:*mut u16,length:u32)->i32;
    fn FindVolumeClose(handle:HandleValue)->i32;
    fn GetVolumePathNamesForVolumeNameW(volume:*const u16,paths:*mut u16,length:u32,needed:*mut u32)->i32;
    fn GetVolumeInformationW(root:*const u16,name:*mut u16,name_size:u32,serial:*mut u32,max_component:*mut u32,flags:*mut u32,fs:*mut u16,fs_size:u32)->i32;
    fn GetDriveTypeW(root:*const u16)->u32;
    fn GetFinalPathNameByHandleW(handle:HandleValue,path:*mut u16,length:u32,flags:u32)->u32;
    fn FindFirstFileNameW(file:*const u16,flags:u32,length:*mut u32,name:*mut u16)->HandleValue;
    fn FindNextFileNameW(handle:HandleValue,length:*mut u32,name:*mut u16)->i32;
    fn FindClose(handle:HandleValue)->i32;
    fn OpenFileById(volume:HandleValue,id:*const FileIdDescriptor,access:u32,share:u32,security:*const c_void,flags:u32)->HandleValue;
}
#[derive(Clone,Debug,Serialize,Deserialize)]
#[serde(rename_all="camelCase")]
pub struct VolumeInfo {pub id:String,pub name:String,pub paths:Vec<String>,pub filesystem:String,pub fixed:bool,pub available:bool}
pub fn volumes()->Vec<VolumeInfo>{
    struct ErrorMode(u32,bool);impl Drop for ErrorMode{fn drop(&mut self){if self.1{unsafe{SetThreadErrorMode(self.0,std::ptr::null_mut());}}}}
    let mut old_mode=0;let changed=unsafe{SetThreadErrorMode(0x8001,&mut old_mode)}!=0;let _mode=ErrorMode(old_mode,changed);
    let mut results=vec![];let mut name=vec![0u16;1024];
    let handle=unsafe{FindFirstVolumeW(name.as_mut_ptr(),name.len()as u32)};
    if handle==INVALID{return results}
    loop {
        let id=String::from_utf16_lossy(&name[..name.iter().position(|c|*c==0).unwrap_or(name.len())]);
        if valid_volume(&id) {
            let mut paths=vec![0u16;32768];let mut needed=0;
            let got_paths=unsafe{GetVolumePathNamesForVolumeNameW(wide(&id).as_ptr(),paths.as_mut_ptr(),paths.len()as u32,&mut needed)}!=0;
            let paths:Vec<String>=if got_paths{paths.split(|c|*c==0).take_while(|s|!s.is_empty()).map(String::from_utf16_lossy).collect()}else{vec![]};
            let mut label=[0u16;256];let mut fs=[0u16;64];let mut serial=0;
            let available=unsafe{GetVolumeInformationW(wide(&id).as_ptr(),label.as_mut_ptr(),label.len()as u32,&mut serial,std::ptr::null_mut(),std::ptr::null_mut(),fs.as_mut_ptr(),fs.len()as u32)}!=0;
            let text=|v:&[u16]|String::from_utf16_lossy(&v[..v.iter().position(|c|*c==0).unwrap_or(v.len())]);
            let fixed=unsafe{GetDriveTypeW(wide(&id).as_ptr())}==3;
            if !paths.is_empty(){results.push(VolumeInfo{id,name:text(&label),paths,filesystem:text(&fs),fixed,available});}
        }
        name.fill(0);if unsafe{FindNextVolumeW(handle,name.as_mut_ptr(),name.len()as u32)}==0{break}
    }
    unsafe{FindVolumeClose(handle)};results.sort_by(|a,b|a.paths.cmp(&b.paths));results
}
#[repr(C)]struct FileIdDescriptor {size:u32,kind:u32,id:[u64;2]}
#[repr(C)]struct EnumData {start:u64,low:i64,high:i64}
#[repr(C)]struct ReadJournal {start:i64,reasons:u32,close_only:u32,timeout:u64,wait_for:u64,journal:u64}
#[derive(Clone,Copy,Debug)]pub struct Journal {pub id:u64,pub first:i64,pub next:i64,pub lowest:i64}
pub struct Volume {pub handle:Handle,pub root:FileId,pub serial:u32,pub id:String}
impl Volume {
    pub fn open(id:&str)->Result<Self,String>{
        if !valid_volume(id){return Err("Invalid volume identity.".into())}
        let handle=unsafe{CreateFileW(wide(id.trim_end_matches('\\')).as_ptr(),0x80000000,7,std::ptr::null(),3,0,std::ptr::null_mut())};
        if handle==INVALID{return Err(format!("NTFS volume access requires the discovery service: {}",error()))}
        let handle=Handle(handle);
        let root_handle=unsafe{CreateFileW(wide(id).as_ptr(),0,7,std::ptr::null(),3,0x02000000,std::ptr::null_mut())};
        if root_handle==INVALID{return Err(error())}
        let root_handle=Handle(root_handle);let mut info=FileInfo::default();
        if unsafe{GetFileInformationByHandle(root_handle.0,&mut info)}==0{return Err(error())}
        Ok(Self{handle,root:info.id(),serial:info.serial,id:id.into()})
    }
    fn ioctl(&self,code:u32,input:*const c_void,size:u32)->Result<Vec<u8>,u32>{
        let mut buffer=vec![0u8;MAX_FRAME_BYTES];let mut returned=0;
        if unsafe{DeviceIoControl(self.handle.0,code,input,size,buffer.as_mut_ptr().cast(),buffer.len()as u32,&mut returned,std::ptr::null_mut())}==0 {
            return Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(1)as u32)
        }
        buffer.truncate(returned as usize);Ok(buffer)
    }
    pub fn journal(&self)->Result<Journal,String>{
        let bytes=self.ioctl(0x000900f4,std::ptr::null(),0).map_err(|code|format!("NTFS change journal unavailable (Windows {code})."))?;
        if bytes.len()<56{return Err("Invalid NTFS journal response.".into())}
        Ok(Journal{id:u64::from_le_bytes(bytes[..8].try_into().unwrap()),first:i64::from_le_bytes(bytes[8..16].try_into().unwrap()),
            next:i64::from_le_bytes(bytes[16..24].try_into().unwrap()),lowest:i64::from_le_bytes(bytes[24..32].try_into().unwrap())})
    }
    pub fn enumerate(&self,start:u64)->Result<Option<(u64,Vec<Record>)>,String>{
        let request=EnumData{start,low:0,high:i64::MAX};
        match self.ioctl(0x000900b3,(&request as *const EnumData).cast(),std::mem::size_of::<EnumData>()as u32) {
            Ok(bytes)=>ntfs::parse(&bytes).map(Some),
            Err(38)=>Ok(None),Err(code)=>Err(format!("NTFS enumeration failed (Windows {code}).")),
        }
    }
    pub fn changes(&self,start:i64,journal:u64)->Result<(i64,Vec<Record>),String>{
        let request=ReadJournal{start,reasons:u32::MAX,close_only:0,timeout:0,wait_for:0,journal};
        let bytes=self.ioctl(0x000900bb,(&request as *const ReadJournal).cast(),std::mem::size_of::<ReadJournal>()as u32)
            .map_err(|code|format!("NTFS journal changed or became unavailable (Windows {code}); reconciliation required."))?;
        ntfs::parse(&bytes).map(|(next,records)|(next as i64,records))
    }
    /// Repair a link-change record from the live file identity. The path stays inside the protected graph.
    pub fn live_record(&self,record:&Record)->Option<Record>{
        let descriptor=FileIdDescriptor{size:std::mem::size_of::<FileIdDescriptor>()as u32,
            kind:if record.id.0[8..].iter().any(|b|*b!=0){2}else{0},
            id:[u64::from_le_bytes(record.id.0[..8].try_into().ok()?),u64::from_le_bytes(record.id.0[8..].try_into().ok()?)]};
        let handle=unsafe{OpenFileById(self.handle.0,&descriptor,0,7,std::ptr::null(),0x02000000|0x00200000)};
        if handle==INVALID{return None}let handle=Handle(handle);let mut info=FileInfo::default();
        if unsafe{GetFileInformationByHandle(handle.0,&mut info)}==0{return None}
        let mut path=vec![0u16;32768];let length=unsafe{GetFinalPathNameByHandleW(handle.0,path.as_mut_ptr(),path.len()as u32,1)}as usize;
        if length==0||length>=path.len(){return None}
        let path=String::from_utf16_lossy(&path[..length]);if !path.starts_with(&self.id){return None}
        let parent=Path::new(&path).parent()?;let name=Path::new(&path).file_name()?.to_string_lossy().into_owned();
        let parent_handle=unsafe{CreateFileW(wide(&parent.to_string_lossy()).as_ptr(),0,7,std::ptr::null(),3,0x02000000,std::ptr::null_mut())};
        if parent_handle==INVALID{return None}let parent_handle=Handle(parent_handle);let mut parent_info=FileInfo::default();
        if unsafe{GetFileInformationByHandle(parent_handle.0,&mut parent_info)}==0{return None}
        Some(Record{id:record.id,parent:parent_info.id(),name,attributes:info.attrs,usn:record.usn,reason:0})
    }
    pub fn disk_numbers(&self)->Vec<u32>{
        let Ok(bytes)=self.ioctl(0x00560000,std::ptr::null(),0)else{return vec![]};
        if bytes.len()<8{return vec![]}
        let count=u32::from_le_bytes(bytes[..4].try_into().unwrap())as usize;
        (0..count.min(128)).filter_map(|i|{let p=8+i*24;(p+4<=bytes.len()).then(||u32::from_le_bytes(bytes[p..p+4].try_into().unwrap()))}).collect()
    }
}
pub fn file_info(path:&str)->Result<FileInfo,String>{
    let handle=unsafe{CreateFileW(wide(path).as_ptr(),0x80000000,7,std::ptr::null(),3,0x00200000,std::ptr::null_mut())};
    if handle==INVALID{return Err(error())}
    let handle=Handle(handle);let mut info=FileInfo::default();
    if unsafe{GetFileInformationByHandle(handle.0,&mut info)}==0{return Err(error())}
    if info.attrs&(0x400|0x1000|0x10)!=0{return Err("Executable is offline, redirected or not a regular file.".into())}
    Ok(info)
}
pub fn hard_links(path:&str,volume:&str)->Vec<String>{
    let mut buffer=vec![0u16;32768];let mut length=buffer.len()as u32;
    let handle=unsafe{FindFirstFileNameW(wide(path).as_ptr(),0,&mut length,buffer.as_mut_ptr())};
    if handle==INVALID{return vec![path.into()]}
    let mut results=vec![];
    loop {
        let name=String::from_utf16_lossy(&buffer[..buffer.iter().position(|c|*c==0).unwrap_or(buffer.len())]);
        if name.starts_with('\\')&&!name.contains('\0') {results.push(format!("{}{}",volume.trim_end_matches('\\'),name));}
        buffer.fill(0);length=buffer.len()as u32;
        if results.len()>=128||unsafe{FindNextFileNameW(handle,&mut length,buffer.as_mut_ptr())}==0{break}
    }
    unsafe{FindClose(handle)};if results.is_empty(){results.push(path.into())}results
}
pub fn pe_info(path:&Path)->Result<(bool,bool),String>{
    let mut file=std::fs::File::open(path).map_err(|e|e.to_string())?;
    let length=file.metadata().map_err(|e|e.to_string())?.len();
    let mut dos=[0u8;64];file.read_exact(&mut dos).map_err(|e|e.to_string())?;
    if &dos[..2]!=b"MZ"{return Ok((false,false))}
    let offset=u32::from_le_bytes(dos[60..64].try_into().unwrap())as u64;
    if offset<64||offset>4_194_304||offset+96>length{return Ok((false,false))}
    file.seek(SeekFrom::Start(offset)).map_err(|e|e.to_string())?;
    let mut pe=[0u8;96];file.read_exact(&mut pe).map_err(|e|e.to_string())?;
    if &pe[..4]!=b"PE\0\0"{return Ok((false,false))}
    let characteristics=u16::from_le_bytes(pe[22..24].try_into().unwrap());
    let magic=u16::from_le_bytes(pe[24..26].try_into().unwrap());
    if !matches!(magic,0x10b|0x20b)||characteristics&0x2000!=0{return Ok((false,false))}
    let subsystem=u16::from_le_bytes(pe[92..94].try_into().unwrap());
    Ok((true,subsystem==2))
}
#[link(name="version")]unsafe extern "system" {
    fn GetFileVersionInfoSizeW(path:*const u16,handle:*mut u32)->u32;
    fn GetFileVersionInfoW(path:*const u16,handle:u32,length:u32,data:*mut c_void)->i32;
    fn VerQueryValueW(data:*const c_void,sub:*const u16,value:*mut *mut c_void,length:*mut u32)->i32;
}
pub fn metadata(path:&str)->(String,String,String){
    let mut ignored=0;let size=unsafe{GetFileVersionInfoSizeW(wide(path).as_ptr(),&mut ignored)};
    if size==0||size>MAX_FRAME_BYTES as u32{return Default::default()}
    let mut bytes=vec![0u8;size as usize];
    if unsafe{GetFileVersionInfoW(wide(path).as_ptr(),0,size,bytes.as_mut_ptr().cast())}==0{return Default::default()}
    let mut translations=std::ptr::null_mut();let mut len=0;
    let got=unsafe{VerQueryValueW(bytes.as_ptr().cast(),wide(r"\VarFileInfo\Translation").as_ptr(),&mut translations,&mut len)}!=0;
    let pairs=if got&&len>=4&&!translations.is_null(){let p=unsafe{std::slice::from_raw_parts(translations.cast::<u16>(),(len as usize/2).min(128))};
        p.chunks_exact(2).map(|v|(v[0],v[1])).collect::<Vec<_>>()}else{vec![(0x0409,0x04b0)]};
    let property=|name:&str|{
        for (lang,cp)in &pairs {
            let key=format!(r"\StringFileInfo\{lang:04x}{cp:04x}\{name}");let mut value=std::ptr::null_mut();let mut len=0;
            if unsafe{VerQueryValueW(bytes.as_ptr().cast(),wide(&key).as_ptr(),&mut value,&mut len)}!=0&&!value.is_null()&&len>0&&len<=4096 {
                let chars=unsafe{std::slice::from_raw_parts(value.cast::<u16>(),len as usize)};
                return String::from_utf16_lossy(chars).trim_end_matches('\0').trim().to_string()
            }
        }
        String::new()
    };
    (property("ProductName"),property("CompanyName"),property("FileDescription"))
}

pub fn canonical_path(path:&str)->Option<String>{
    let handle=unsafe{CreateFileW(wide(path).as_ptr(),0,7,std::ptr::null(),3,0x02000000|0x00200000,std::ptr::null_mut())};
    if handle==INVALID{return None}
    let handle=Handle(handle);let mut info=FileInfo::default();
    if unsafe{GetFileInformationByHandle(handle.0,&mut info)}==0||info.attrs&0x400!=0{return None}
    let mut result=vec![0u16;32768];
    let length=unsafe{GetFinalPathNameByHandleW(handle.0,result.as_mut_ptr(),result.len()as u32,1)}as usize;
    if length==0||length>=result.len(){return None}
    Some(String::from_utf16_lossy(&result[..length]))
}
pub fn launch_key(executable:&str,arguments:&str,working_directory:&str)->Option<String>{
    if working_directory.is_empty(){return None}
    let executable=canonical_path(executable)?;let directory=canonical_path(working_directory)?;
    use sha2::{Digest,Sha256};
    Some(format!("{:x}",Sha256::digest(format!("{executable}\0{arguments}\0{directory}").as_bytes())))
}

pub fn shell_path(path:&str)->Option<String>{
    // Shell activation uses a mounted DOS path; volume GUIDs remain the persistent discovery identity.
    let canonical=canonical_path(path)?;
    let end=canonical.find("}\\")?+2;let volume=&canonical[..end];if !valid_volume(volume){return None}
    let mut mounts=vec![0u16;32768];let mut needed=0;
    if unsafe{GetVolumePathNamesForVolumeNameW(wide(volume).as_ptr(),mounts.as_mut_ptr(),mounts.len()as u32,&mut needed)}==0{return None}
    let mount=mounts.split(|c|*c==0).take_while(|s|!s.is_empty()).map(String::from_utf16_lossy).min_by_key(String::len)?;
    Some(format!("{}{}",mount,canonical[end..].trim_start_matches('\\')))
}

pub fn directory_info(path:&str)->Result<FileInfo,String>{
    let handle=unsafe{CreateFileW(wide(path).as_ptr(),0,7,std::ptr::null(),3,0x02000000|0x00200000,std::ptr::null_mut())};
    if handle==INVALID{return Err(error())}let handle=Handle(handle);let mut info=FileInfo::default();
    if unsafe{GetFileInformationByHandle(handle.0,&mut info)}==0{return Err(error())}
    if info.attrs&0x10==0||info.attrs&(0x400|0x1000)!=0{return Err("Application directory is redirected or offline.".into())}
    Ok(info)
}
