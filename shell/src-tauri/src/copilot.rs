use serde_json::{json,Value};
use tauri::AppHandle;
pub const PACKAGE_NAME:&str="MCShotty.WinDigUp.Launcher";
#[tauri::command]
pub async fn copilot_status()->Value {
    #[cfg(windows)] {
        return tauri::async_runtime::spawn_blocking(probe).await.unwrap_or_else(|e|json!({"supported":true,"registered":false,"message":e.to_string()}));
    }
    #[cfg(not(windows))] json!({"supported":false,"registered":false})
}
#[cfg(windows)]fn probe()->Value {
    use std::{process::{Command,Stdio},os::windows::process::CommandExt,time::{Duration,Instant}};
    let mut command=Command::new("powershell.exe");
    command.args(["-NoProfile","-NonInteractive","-Command",
        "$p=Get-AppxPackage -Name MCShotty.WinDigUp.Launcher; $k=Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\Shell\\BrandedKey' -ErrorAction SilentlyContinue; @{registered=[bool]$p; aumid=$(if($p){$p.PackageFamilyName+'!Launcher'}else{''}); assigned=$($p -and $k.BrandedKeyChoiceType -in @('App','AppEnforcedByPolicy') -and $k.AppAumid -eq ($p.PackageFamilyName+'!Launcher')); managed=($k.BrandedKeyChoiceType -eq 'AppEnforcedByPolicy')} | ConvertTo-Json -Compress"])
        .creation_flags(0x08000000).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child=match command.spawn(){Ok(c)=>c,Err(e)=>return json!({"supported":true,"registered":false,"message":e.to_string()})};
    let started=Instant::now();
    loop{match child.try_wait(){Ok(Some(_))=>break,Err(_)=>break,_=>{}}
        if started.elapsed()>Duration::from_secs(5){let _=child.kill();let _=child.wait();return json!({"supported":true,"registered":false,"message":"Windows package status timed out."})}
        std::thread::sleep(Duration::from_millis(25));
    }
    let mut value=child.wait_with_output().ok().and_then(|o|serde_json::from_slice::<Value>(&o.stdout).ok())
        .unwrap_or(json!({"registered":false,"message":"Windows package status is unavailable."}));
    value["supported"]=json!(true);value["packageName"]=json!(PACKAGE_NAME);value
}
#[tauri::command]
pub fn configure_copilot_key(app:AppHandle)->Result<(),String>{
    let _=app;
    #[cfg(windows)] {
        use windows::{core::w,Win32::UI::{Shell::{ShellExecuteExW,SHELLEXECUTEINFOW,SEE_MASK_NOASYNC},WindowsAndMessaging::SW_SHOWNORMAL}};
        let mut info=SHELLEXECUTEINFOW{cbSize:std::mem::size_of::<SHELLEXECUTEINFOW>()as u32,fMask:SEE_MASK_NOASYNC,
            lpVerb:w!("open"),lpFile:w!("ms-settings:personalization-textinput-copilot-hardwarekey"),nShow:SW_SHOWNORMAL.0,..Default::default()};
        return unsafe{ShellExecuteExW(&mut info)}.map_err(|e|format!("Windows could not open the Copilot-key setting: {e}"));
    }
    #[cfg(not(windows))] Err("Copilot-key mapping is available in supported Windows 11 versions.".into())
}
