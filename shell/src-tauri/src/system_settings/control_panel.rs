use super::{Entry,NativeTarget};
use windows::{core::{Interface,PCWSTR,PWSTR,w},Win32::{Foundation::PROPERTYKEY,System::{Com::*,SystemServices::SFGAO_HIDDEN},UI::{Shell::*,WindowsAndMessaging::*}}};
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

const CHANGE:u32=WM_APP+119;
unsafe extern "system" fn procedure(hwnd:windows::Win32::Foundation::HWND,message:u32,wp:windows::Win32::Foundation::WPARAM,lp:windows::Win32::Foundation::LPARAM)->windows::Win32::Foundation::LRESULT {
    use windows::Win32::Foundation::LRESULT;
    unsafe{
        if message==WM_NCCREATE{let create=&*(lp.0 as *const CREATESTRUCTW);SetWindowLongPtrW(hwnd,GWLP_USERDATA,create.lpCreateParams as isize);}
        let ptr=GetWindowLongPtrW(hwnd,GWLP_USERDATA)as *const super::Catalog;
        if message==CHANGE{SetTimer(Some(hwnd),1,600,None);return LRESULT(0)}
        if message==WM_TIMER&&!ptr.is_null(){
            if wp.0==1{let _=KillTimer(Some(hwnd),1);(*ptr).refresh();}else{(*ptr).refresh_if_stale();}
            return LRESULT(0)
        }
        DefWindowProcW(hwnd,message,wp,lp)
    }
}
pub fn watch(catalog:super::Catalog){
    std::thread::spawn(move||{
        let Ok(_com)=Apartment::new()else{return};
        unsafe{
            use windows::Win32::{Foundation::{HINSTANCE,HWND},System::LibraryLoader::GetModuleHandleW,UI::Shell::Common::ITEMIDLIST};
            let Ok(module)=GetModuleHandleW(None)else{return};let instance=HINSTANCE(module.0);
            let class=w!("WinDigUpControlPanelWatcher");
            let _=RegisterClassW(&WNDCLASSW{hInstance:instance,lpfnWndProc:Some(procedure),lpszClassName:class,..Default::default()});
            let state=Box::new(catalog);
            let Ok(hwnd)=CreateWindowExW(WINDOW_EX_STYLE::default(),class,w!(""),WINDOW_STYLE::default(),0,0,0,0,Some(HWND_MESSAGE),None,Some(instance),Some((&*state as *const super::Catalog).cast()))else{return};
            let mut pidls:Vec<*mut ITEMIDLIST>=vec![];
            for name in ["::{26EE0668-A00A-44D7-9371-BEB064C98683}","::{ED7BA470-8E54-465E-825C-99712043E01C}"]{
                let name=wide(name);let mut pidl=std::ptr::null_mut();
                if SHParseDisplayName(PCWSTR(name.as_ptr()),None,&mut pidl,0,None).is_ok(){pidls.push(pidl);}
            }
            let entries=pidls.iter().map(|p|SHChangeNotifyEntry{pidl:*p,fRecursive:true.into()}).collect::<Vec<_>>();
            let registration=SHChangeNotifyRegister(hwnd,SHCNRF_ShellLevel|SHCNRF_InterruptLevel,SHCNE_ALLEVENTS.0 as i32,CHANGE,entries.len()as i32,entries.as_ptr());
            SetTimer(Some(hwnd),2,60_000,None);let mut message=MSG::default();
            while GetMessageW(&mut message,None,0,0).0>0{let _=TranslateMessage(&message);DispatchMessageW(&message);}
            if registration!=0{let _=SHChangeNotifyDeregister(registration);}
            let _=DestroyWindow(hwnd);for pidl in pidls{CoTaskMemFree(Some(pidl.cast()));}drop(state);
        }
    });
}
