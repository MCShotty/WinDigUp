//! COM objects stay on their owning thread. Only strings and owned records cross threads.
use super::{Catalog, Record, Target};
use std::path::{Path, PathBuf};
use std::sync::Weak;
use windows::core::{w, Interface, PCWSTR, PWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, PROPERTYKEY, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Com::StructuredStorage::{PropVariantClear, PropVariantToStringAlloc};
use windows::Win32::System::Com::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::Common::ITEMIDLIST;
use windows::Win32::UI::Shell::PropertiesSystem::PSGetPropertyKeyFromName;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

struct Apartment;
impl Apartment {
    fn new() -> Result<Self, String> {
        // Every caller owns a fresh background thread or initializes the COM apartment for this operation.
        unsafe {
            CoInitializeEx(None, COINIT_APARTMENTTHREADED)
                .ok()
                .map_err(|e| e.to_string())?;
        }
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            CoUninitialize();
        }
    }
}
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain([0]).collect()
}
fn string(buffer: &[u16]) -> String {
    String::from_utf16_lossy(&buffer[..buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len())])
}
unsafe fn owned(value: PWSTR) -> String {
    let text = unsafe { value.to_string().unwrap_or_default() };
    unsafe {
        CoTaskMemFree(Some(value.0.cast()));
    }
    text
}
unsafe fn property_value(item: &IShellItem2, name: &str) -> Option<String> {
    let mut key = PROPERTYKEY::default();
    let name = wide(name);
    unsafe {
        if PSGetPropertyKeyFromName(PCWSTR(name.as_ptr()), &mut key).is_ok() {
            if let Ok(value) = item.GetString(&key) {
                return Some(owned(value));
            }
        }
    }
    None
}
unsafe fn property(item: &IShellItem2, name: &str) -> String {
    unsafe { property_value(item, name).unwrap_or_default() }
}
unsafe fn formatted_property(item: &IShellItem2, name: &str) -> String {
    let mut key = PROPERTYKEY::default();
    let name = wide(name);
    unsafe {
        if PSGetPropertyKeyFromName(PCWSTR(name.as_ptr()), &mut key).is_err() {
            return String::new();
        }
        let Ok(mut value) = item.GetProperty(&key) else {
            return String::new();
        };
        let text = PropVariantToStringAlloc(&value)
            .map(|p| owned(p))
            .unwrap_or_default();
        let _ = PropVariantClear(&mut value);
        text
    }
}
fn file_revision(path: &Path) -> String {
    std::fs::metadata(path)
        .map(|m| format!("{:?}:{}", m.modified().ok(), m.len()))
        .unwrap_or_default()
}
fn shell_target(parsing: &str) -> String {
    if parsing.starts_with("::")
        || parsing.to_ascii_lowercase().starts_with("shell:")
        || Path::new(parsing).is_absolute()
    {
        parsing.into()
    } else {
        format!("shell:AppsFolder\\{parsing}")
    }
}
unsafe fn folder(id: &windows::core::GUID) -> Result<PathBuf, String> {
    unsafe {
        SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None)
            .map(|p| PathBuf::from(owned(p)))
            .map_err(|e| e.to_string())
    }
}
fn desktop_identity(path: &str, args: &str, cwd: &str) -> String {
    // Do not rewrite argument strings: even whitespace/quoting can distinguish valid shortcuts.
    format!(
        "desktop:{}\0{}\0{}",
        path.replace('/', "\\").to_lowercase(),
        args,
        cwd.replace('/', "\\").to_lowercase()
    )
}
unsafe fn shortcut(path: &Path, source: &str) -> Option<Record> {
    let spelling = path.to_string_lossy().to_string();
    let mut record = Record::new(
        format!("shortcut:{}", spelling.to_lowercase()),
        path.file_stem()?.to_string_lossy().into(),
        source,
        Target::Shortcut {
            path: spelling.clone(),
        },
    );
    record.icon_revision = file_revision(path);
    unsafe {
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).ok()?;
        let persistence: IPersistFile = link.cast().ok()?;
        let name = wide(&spelling);
        if persistence.Load(PCWSTR(name.as_ptr()), STGM_READ).is_err() {
            return None;
        }
        let mut target = vec![0u16; 32768];
        let mut args = vec![0u16; 32768];
        let mut cwd = vec![0u16; 32768];
        let _ = link.GetPath(&mut target, std::ptr::null_mut(), SLGP_RAWPATH.0 as u32);
        let arguments_known = link.GetArguments(&mut args).is_ok();
        let directory_known = link.GetWorkingDirectory(&mut cwd).is_ok();
        let target = string(&target);
        if !target.is_empty() {
            if Path::new(&target).is_dir() {
                return None;
            }
            let ext = Path::new(&target)
                .extension()
                .unwrap_or_default()
                .to_string_lossy()
                .to_lowercase();
            if Path::new(&target).exists() && !["exe", "com", "cmd", "bat"].contains(&ext.as_str())
            {
                return None;
            }
            if arguments_known && directory_known {
                record.identity = desktop_identity(&target, &string(&args), &string(&cwd));
                record.executable=target.clone();record.arguments=string(&args);record.working_directory=string(&cwd);
            }
            record
                .icon_revision
                .push_str(&file_revision(Path::new(&target)));
            record.id = format!("app:{}", super::digest(&record.identity));
        }
        let mut description = vec![0u16; 4096];
        let _ = link.GetDescription(&mut description);
        record.description = string(&description);
    }
    Some(record)
}
fn walk(
    folder: &Path,
    source: &str,
    records: &mut Vec<Record>,
    enabled: &dyn Fn() -> bool,
) -> Result<(), String> {
    for entry in std::fs::read_dir(folder).map_err(|e| e.to_string())? {
        if !enabled() {
            return Err("Application discovery is disabled.".into());
        }
        let entry = entry.map_err(|e| e.to_string())?;
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_dir() {
            walk(&entry.path(), source, records, enabled)?;
        } else if kind.is_file()
            && entry
                .path()
                .extension()
                .is_some_and(|s| s.eq_ignore_ascii_case("lnk"))
        {
            if let Some(record) = unsafe { shortcut(&entry.path(), source) } {
                records.push(record);
            }
        }
    }
    Ok(())
}
unsafe fn programs(
    id: &windows::core::GUID,
    source: &str,
    enabled: &dyn Fn() -> bool,
) -> Result<Vec<Record>, String> {
    let root = unsafe { folder(id)? };
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut records = Vec::new();
    walk(&root, source, &mut records, enabled)?;
    Ok(records)
}
unsafe fn apps_folder(enabled: &dyn Fn() -> bool) -> Result<Vec<Record>, String> {
    unsafe {
        let folder: IShellItem = SHGetKnownFolderItem(&FOLDERID_AppsFolder, KF_FLAG_DEFAULT, None)
            .map_err(|e| e.to_string())?;
        let entries: IEnumShellItems = folder
            .BindToHandler(None, &BHID_EnumItems)
            .map_err(|e| e.to_string())?;
        let mut records = Vec::new();
        loop {
            if !enabled() {
                return Err("Application discovery is disabled.".into());
            }
            let mut next = [None];
            let mut fetched = 0;
            entries
                .Next(&mut next, Some(&mut fetched))
                .map_err(|e| e.to_string())?;
            if fetched == 0 {
                break;
            }
            let item = next[0]
                .take()
                .ok_or("Windows returned an empty application entry")?;
            let name = owned(
                item.GetDisplayName(SIGDN_NORMALDISPLAY)
                    .map_err(|e| e.to_string())?,
            );
            let parsing = owned(
                item.GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING)
                    .map_err(|e| e.to_string())?,
            );
            if name.trim().is_empty() || parsing.is_empty() {
                continue;
            }
            let mut record = Record::new(
                format!("shell:{}", shell_target(&parsing)),
                name,
                "appsFolder",
                Target::Shell {
                    parsing_name: shell_target(&parsing),
                },
            );
            if let Ok(item) = item.cast::<IShellItem2>() {
                let target = property(&item, "System.Link.TargetParsingPath");
                if !target.is_empty() {
                    if let (Some(args), Some(cwd)) = (
                        property_value(&item, "System.Link.Arguments"),
                        property_value(&item, "System.Link.WorkingDirectory"),
                    ) {
                        record.identity = desktop_identity(&target, &args, &cwd);
                        record.id = format!("app:{}", super::digest(&record.identity));
                    }
                }
            }
            // An AppsFolder desktop entry may itself resolve to its original Start menu shortcut.
            if Path::new(&parsing)
                .extension()
                .is_some_and(|s| s.eq_ignore_ascii_case("lnk"))
            {
                if let Some(link) = shortcut(Path::new(&parsing), "appsFolder") {
                    record = link;
                }
            }
            records.push(record);
        }
        Ok(records)
    }
}
unsafe fn enrich(record: &mut Record) {
    unsafe {
        let path = match &record.target {
            Target::Shortcut { path } | Target::Executable { path,.. } => path,
            Target::Shell { parsing_name } => parsing_name,
        };
        let spelling = wide(path);
        let Ok(mut item) =
            SHCreateItemFromParsingName::<_, _, IShellItem2>(PCWSTR(spelling.as_ptr()), None)
        else {
            return;
        };
        if matches!(record.target, Target::Shortcut { .. }) {
            let target = property(&item, "System.Link.TargetParsingPath");
            if !target.is_empty() {
                let target = wide(&target);
                if let Ok(resolved) =
                    SHCreateItemFromParsingName::<_, _, IShellItem2>(PCWSTR(target.as_ptr()), None)
                {
                    item = resolved;
                }
            }
        }
        if !record.executable.is_empty(){record.launch_key=crate::discovery::volume::launch_key(&record.executable,&record.arguments,&record.working_directory).unwrap_or_default();}
        record.product=property(&item,"System.Software.ProductName");
        record.publisher = property(&item, "System.Company");
        record.keywords = formatted_property(&item, "System.Keywords");
        let mut description = property(&item, "System.FileDescription");
        if description.is_empty() {
            description = property(&item, "System.Comment");
        }
        if !description.is_empty() && !record.description.contains(&description) {
            if !record.description.is_empty() {
                record.description.push('\n');
            }
            record.description.push_str(&description);
        }
        record.icon_revision.push_str(
            &(property(&item, "System.AppUserModel.PackageFullName")
                + &property(&item, "System.FileVersion")),
        );
    }
}
pub fn scan(
    mut publish: impl FnMut(&str, Result<Vec<Record>, String>, bool),
    enabled: impl Fn() -> bool,
) {
    let apartment = Apartment::new();
    if let Err(error) = apartment {
        for source in ["userPrograms", "commonPrograms", "appsFolder"] {
            publish(source, Err(error.clone()), false);
        }
        return;
    }
    // Publish stable names/launch identities before asking optional property handlers for metadata.
    let mut discovered = Vec::new();
    for source in ["userPrograms", "commonPrograms", "appsFolder"] {
        if !enabled() {
            return;
        }
        let result = unsafe {
            match source {
                "userPrograms" => programs(&FOLDERID_Programs, source, &enabled),
                "commonPrograms" => programs(&FOLDERID_CommonPrograms, source, &enabled),
                _ => apps_folder(&enabled),
            }
        };
        if let Ok(records) = &result {
            discovered.push((source, records.clone()));
        }
        publish(source, result, false);
    }
    for (source, mut records) in discovered {
        for record in &mut records {
            if !enabled() {
                return;
            }
            unsafe {
                enrich(record);
            }
        }
        if !enabled() {
            return;
        }
        publish(source, Ok(records), true);
    }
}

pub fn launch(target: &Target) -> Result<(), String> {
    let _apartment = Apartment::new()?;
    unsafe {
        let mut info = SHELLEXECUTEINFOW {
            cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
            fMask: SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI,
            lpVerb: w!("open"),
            nShow: SW_SHOWNORMAL.0,
            ..Default::default()
        };
        let mut pidl = std::ptr::null_mut();
        let spelling = wide(match target {
            Target::Shortcut { path } | Target::Executable { path,.. } => path,
            Target::Shell { parsing_name } => parsing_name,
        });
        match target {
            Target::Shortcut { path } => {
                if !Path::new(path).is_file() {
                    return Err("The application's shortcut is no longer available.".into());
                }
                info.lpFile = PCWSTR(spelling.as_ptr());
            }
            Target::Executable { path,working_directory } => {
                let metadata=std::fs::symlink_metadata(path).map_err(|_|"The discovered executable is no longer available.")?;
                if !metadata.is_file()||!path.to_ascii_lowercase().ends_with(".exe"){
                    return Err("This discovered target is not an executable application.".into())
                }
                let executable=crate::discovery::volume::shell_path(path).ok_or("The application's volume is unavailable.")?;
                let executable=wide(&executable);info.lpFile=PCWSTR(executable.as_ptr());
                // The original path is never combined with query text or invented arguments.
                let directory=crate::discovery::volume::shell_path(working_directory).ok_or("The application's working directory is unavailable.")?;
                let directory=wide(&directory);
                info.lpDirectory=PCWSTR(directory.as_ptr());
                return ShellExecuteExW(&mut info).map_err(|e|format!("Windows could not launch this application: {e}"));
            }
            Target::Shell { .. } => {
                SHParseDisplayName(PCWSTR(spelling.as_ptr()), None, &mut pidl, 0, None)
                    .map_err(|e| e.to_string())?;
                info.fMask |= SEE_MASK_IDLIST;
                info.lpIDList = pidl.cast();
            }
        }
        // This process is deliberately never assigned to DigUp's worker job.
        let result = ShellExecuteExW(&mut info)
            .map_err(|e| format!("Windows could not launch this application: {e}"));
        if !pidl.is_null() {
            CoTaskMemFree(Some(pidl.cast()));
        }
        result
    }
}

pub fn icon(target: &Target, size: u32, path: &Path) -> Result<(), String> {
    let _apartment = Apartment::new()?;
    unsafe {
        let spelling = wide(match target {
            Target::Shortcut { path } | Target::Executable { path,.. } => path,
            Target::Shell { parsing_name } => parsing_name,
        });
        let item: IShellItemImageFactory =
            SHCreateItemFromParsingName(PCWSTR(spelling.as_ptr()), None)
                .map_err(|e| e.to_string())?;
        let bitmap = item
            .GetImage(
                SIZE {
                    cx: size as i32,
                    cy: size as i32,
                },
                SIIGBF_ICONONLY,
            )
            .map_err(|e| e.to_string())?;
        let mut data = BITMAP::default();
        if GetObjectW(
            HGDIOBJ(bitmap.0),
            std::mem::size_of::<BITMAP>() as i32,
            Some((&mut data as *mut BITMAP).cast()),
        ) == 0
        {
            let _ = DeleteObject(HGDIOBJ(bitmap.0));
            return Err("Windows could not read the application icon.".into());
        }
        let width = data.bmWidth as u32;
        let height = data.bmHeight.unsigned_abs();
        if width == 0 || height == 0 || width > 512 || height > 512 {
            let _ = DeleteObject(HGDIOBJ(bitmap.0));
            return Err("Unexpected icon size.".into());
        }
        let mut pixels = vec![0u8; (width * height * 4) as usize];
        let mut header = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width as i32,
                biHeight: -(height as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let dc = GetDC(None);
        let rows = GetDIBits(
            dc,
            bitmap,
            0,
            height,
            Some(pixels.as_mut_ptr().cast()),
            &mut header,
            DIB_RGB_COLORS,
        );
        ReleaseDC(None, dc);
        let _ = DeleteObject(HGDIOBJ(bitmap.0));
        if rows != height as i32 {
            return Err("Windows could not decode the icon.".into());
        }
        let opaque = pixels.chunks_exact(4).all(|p| p[3] == 0);
        for p in pixels.chunks_exact_mut(4) {
            p.swap(0, 2);
            if opaque {
                p[3] = 255;
            }
            if p[3] > 0 && p[3] < 255 {
                for i in 0..3 {
                    p[i] = ((u32::from(p[i]) * 255 / u32::from(p[3])).min(255)) as u8;
                }
            }
        }
        image::save_buffer_with_format(
            path,
            &pixels,
            width,
            height,
            image::ColorType::Rgba8,
            image::ImageFormat::Png,
        )
        .map_err(|e| e.to_string())
    }
}

const CHANGE: u32 = WM_APP + 37;
unsafe extern "system" fn procedure(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        if message == WM_NCCREATE {
            let created = &*(lp.0 as *const CREATESTRUCTW);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, created.lpCreateParams as isize);
        }
        let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const Weak<Catalog>;
        if message == CHANGE {
            SetTimer(Some(hwnd), 1, 750, None);
            return LRESULT(0);
        }
        if message == WM_TIMER && !ptr.is_null() {
            if let Some(service) = (*ptr).upgrade() {
                if wp.0 == 1 {
                    let _ = KillTimer(Some(hwnd), 1);
                    service.refresh();
                } else {
                    service.refresh_if_stale();
                }
            } else {
                PostQuitMessage(0);
            }
            return LRESULT(0);
        }
        DefWindowProcW(hwnd, message, wp, lp)
    }
}
pub fn watch(service: Weak<Catalog>) {
    std::thread::spawn(move || {
        let Ok(_apartment) = Apartment::new() else {
            return;
        };
        unsafe {
            let class = w!("DigUpApplicationCatalogWatcher");
            let Ok(module) = GetModuleHandleW(None) else {
                return;
            };
            let instance = windows::Win32::Foundation::HINSTANCE(module.0);
            let _ = RegisterClassW(&WNDCLASSW {
                hInstance: instance,
                lpfnWndProc: Some(procedure),
                lpszClassName: class,
                ..Default::default()
            });
            let state = Box::new(service);
            let Ok(hwnd) = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                class,
                w!(""),
                WINDOW_STYLE::default(),
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                Some(instance),
                Some((&*state as *const Weak<Catalog>).cast()),
            ) else {
                return;
            };
            let mut pidls: Vec<*mut ITEMIDLIST> = Vec::new();
            for text in std::iter::once("shell:AppsFolder".to_string()).chain(
                [FOLDERID_Programs, FOLDERID_CommonPrograms]
                    .iter()
                    .filter_map(|id| folder(id).ok().map(|p| p.to_string_lossy().into())),
            ) {
                let name = wide(&text);
                let mut pidl = std::ptr::null_mut();
                if SHParseDisplayName(PCWSTR(name.as_ptr()), None, &mut pidl, 0, None).is_ok() {
                    pidls.push(pidl);
                }
            }
            let entries: Vec<_> = pidls
                .iter()
                .map(|p| SHChangeNotifyEntry {
                    pidl: *p,
                    fRecursive: true.into(),
                })
                .collect();
            let registration = SHChangeNotifyRegister(
                hwnd,
                SHCNRF_ShellLevel | SHCNRF_InterruptLevel,
                SHCNE_ALLEVENTS.0 as i32,
                CHANGE,
                entries.len() as i32,
                entries.as_ptr(),
            );
            SetTimer(Some(hwnd), 2, 60_000, None);
            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).0 > 0 {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            if registration != 0 {
                let _ = SHChangeNotifyDeregister(registration);
            }
            let _ = DestroyWindow(hwnd);
            for pidl in pidls {
                CoTaskMemFree(Some(pidl.cast()));
            }
            drop(state);
        }
    });
}
