use super::{Entry,NativeTarget};
use windows::{core::{Interface,PCWSTR,PWSTR,w},Win32::{Foundation::PROPERTYKEY,System::Com::*,UI::{Shell::*,WindowsAndMessaging::*}}};
struct Apartment;
impl Apartment {fn new()->Result<Self,String>{unsafe{CoInitializeEx(None,COINIT_APARTMENTTHREADED).ok().map_err(|e|e.to_string())?;}Ok(Self)}}
impl Drop for Apartment {fn drop(&mut self){unsafe{CoUninitialize()}}}
fn wide(s:&str)->Vec<u16>{s.encode_utf16().chain([0]).collect()}
unsafe fn owned(p:PWSTR)->String{let s=unsafe{p.to_string().unwrap_or_default()};unsafe{CoTaskMemFree(Some(p.0.cast()))};s}
unsafe fn property(item:&IShellItem2,name:&str)->String {
    let mut key=PROPERTYKEY::default();let name=wide(name);
    unsafe {
        if PropertiesSystem::PSGetPropertyKeyFromName(PCWSTR(name.as_ptr()),&mut key).is_ok(){
            if let Ok(value)=item.GetString(&key){return owned(value)}
        }
    }
    String::new()
}
pub fn discover(source:&str)->Result<Vec<Entry>,String>{
    let _com=Apartment::new()?;
    unsafe {
        let folder:IShellItem=if source=="control_panel" {
            SHGetKnownFolderItem(&FOLDERID_ControlPanelFolder,KF_FLAG_DEFAULT,None).map_err(|e|e.to_string())?
        } else {
            SHCreateItemFromParsingName(w!("::{ED7BA470-8E54-465E-825C-99712043E01C}"),None).map_err(|e|format!("Task links are unavailable: {e}"))?
        };
        let enumerator:IEnumShellItems=folder.BindToHandler(None,&BHID_EnumItems).map_err(|e|e.to_string())?;
        let mut entries=Vec::new();
        loop {
            let mut next=[None];let mut fetched=0;
            enumerator.Next(&mut next,Some(&mut fetched)).map_err(|e|e.to_string())?;
            if fetched==0{break}
            let item=next[0].take().ok_or("Windows returned an empty Control Panel item")?;
            if item.GetAttributes(SFGAO_HIDDEN).is_ok_and(|a|a.contains(SFGAO_HIDDEN)){continue}
            let name=owned(item.GetDisplayName(SIGDN_NORMALDISPLAY).map_err(|e|e.to_string())?);
            let parsing=owned(item.GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING).map_err(|e|e.to_string())?);
            // Preserve Windows' opaque Shell target, never a command extracted from task metadata.
            if name.trim().is_empty()||!parsing.starts_with("::{")||parsing.len()>32768{continue}
            let info=item.cast::<IShellItem2>().ok();
            let description=info.as_ref().map(|i|property(i,"System.InfoTip")).unwrap_or_default();
            let canonical=info.as_ref().map(|i|property(i,"System.ApplicationName")).unwrap_or_default();
            let keywords=info.as_ref().map(|i|property(i,"System.Keywords")).unwrap_or_default();
            let aliases=keywords.split(';').map(str::trim).filter(|s|!s.is_empty()).take(64).map(String::from)
                .chain([format!("control panel {name}"),format!("classic {name}")]).collect();
            entries.push(Entry{key:format!("control-panel-{}",crate::applications::digest(&parsing)),name,
                description,uri:String::new(),hardware:String::new(),aliases,min_build:19041,max_build:None,
                translations:Default::default(),native:Some(NativeTarget::Shell{parsing}),source:source.into(),canonical});
            if entries.len()>8192{return Err("Windows returned too many Control Panel entries; retaining the previous catalog.".into())}
        }
        Ok(entries)
    }
}
pub fn open(target:&NativeTarget)->Result<(),String>{
    let _com=Apartment::new()?;
    unsafe {
        let mut info=SHELLEXECUTEINFOW{cbSize:std::mem::size_of::<SHELLEXECUTEINFOW>()as u32,
            fMask:SEE_MASK_NOASYNC|SEE_MASK_FLAG_NO_UI,lpVerb:w!("open"),nShow:SW_SHOWNORMAL.0,..Default::default()};
        match target {
            NativeTarget::Shell{parsing}=>{
                if !parsing.starts_with("::{")||parsing.contains('\0'){return Err("This Control Panel target is invalid.".into())}
                let name=wide(parsing);let mut pidl=std::ptr::null_mut();
                SHParseDisplayName(PCWSTR(name.as_ptr()),None,&mut pidl,0,None)
                    .map_err(|e|format!("This Control Panel item is no longer available: {e}"))?;
                info.fMask|=SEE_MASK_IDLIST;info.lpIDList=pidl.cast();
                let result=ShellExecuteExW(&mut info).map_err(|e|format!("Windows could not open this Control Panel item: {e}"));
                CoTaskMemFree(Some(pidl.cast()));result
            },
            NativeTarget::Canonical{name,page}=>{
                let allowed=[("Microsoft.PowerOptions","pagePlanSettings"),("Microsoft.PowerOptions","pageGlobalSettings"),
                    ("Microsoft.Mouse","1"),("Microsoft.Mouse","2"),("Microsoft.InternetOptions","6")];
                if !allowed.contains(&(name.as_str(),page.as_str())){return Err("This Control Panel task is not registered.".into())}
                #[link(name="kernel32")]unsafe extern "system"{fn GetSystemDirectoryW(buffer:*mut u16,size:u32)->u32;}
                let mut directory=[0u16;32768];let len=GetSystemDirectoryW(directory.as_mut_ptr(),directory.len()as u32)as usize;
                if len==0||len>=directory.len(){return Err("Windows' system directory is unavailable.".into())}
                let exe=wide(&format!("{}\\control.exe",String::from_utf16_lossy(&directory[..len])));
                let args=wide(&format!("/name {name} /page {page}"));
                info.lpFile=PCWSTR(exe.as_ptr());info.lpParameters=PCWSTR(args.as_ptr());
                ShellExecuteExW(&mut info).map_err(|e|format!("Windows could not open this task: {e}"))
            }
        }
    }
}
