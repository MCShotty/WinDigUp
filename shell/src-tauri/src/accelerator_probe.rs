//! An isolated, bounded metadata process. A busy inference worker never owns this request path.
use crate::helper::Launch;
use serde_json::{json, Value};
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub fn run(launch: &Launch, timeout: Duration) -> Result<Value, String> {
    let mut command = Command::new(&launch.program);
    command.args(&launch.args).envs(launch.env.iter().map(|(k,v)|(k,v)))
        .stdin(Stdio::null()).stdout(Stdio::piped());
    command.stderr(launch.log.as_ref().and_then(|path| std::fs::OpenOptions::new().create(true).append(true).open(path).ok())
        .map(Stdio::from).unwrap_or_else(Stdio::null));
    #[cfg(windows)] {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    let mut child=command.spawn().map_err(|e| format!("Can't start accelerator discovery: {e}"))?;
    crate::helper::adopt(&child);
    let output=child.stdout.take().ok_or("Discovery has no output pipe")?;
    let (send,receive)=std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes=Vec::new();
        let result=output.take(262_145).read_to_end(&mut bytes).map(|_|bytes);
        let _=send.send(result);
    });
    let started=Instant::now();
    let status=loop {
        match child.try_wait() {
            Ok(Some(status))=>break status,
            Err(error)=>{ let _=child.kill();let _=child.wait();return Err(format!("Discovery stopped: {error}")); }
            _=>{}
        }
        if started.elapsed() >= timeout {
            let _=child.kill();let _=child.wait();
            return Err("Accelerator discovery timed out. App name search and launching remain available; retry discovery in Settings.".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let bytes=receive.recv_timeout(Duration::from_secs(1)).map_err(|_|"Discovery output is unavailable")?
        .map_err(|e|e.to_string())?;
    if bytes.len()>262_144 { return Err("Accelerator discovery exceeded its output limit.".into()); }
    let mut value: Value=String::from_utf8_lossy(&bytes).lines().rev()
        .find_map(|line|serde_json::from_str::<Value>(line).ok()).ok_or("Discovery returned no structured result.")?;
    if !status.success() { return Err(value["error"].as_str().unwrap_or("Accelerator discovery failed; inspect the accelerator log.").into()); }
    if value["schemaVersion"]!=1 || value["probeOnly"]!=true || !value["devices"].is_array() {
        return Err("Unsupported accelerator discovery contract.".into());
    }
    value["windowsAdapters"]=windows_adapters();
    Ok(value)
}

#[cfg(not(windows))]
fn windows_adapters()->Value { json!([]) }

#[cfg(windows)]
fn windows_adapters()->Value {
    use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIFactory1};
    let mut adapters=Vec::new();
    unsafe {
        if let Ok(factory)=CreateDXGIFactory1::<IDXGIFactory1>() {
            for i in 0..64 {
                let Ok(adapter)=factory.EnumAdapters1(i) else { break };
                let Ok(info)=adapter.GetDesc1() else { continue };
                let length=info.Description.iter().position(|c|*c==0).unwrap_or(info.Description.len());
                adapters.push(json!({"name":String::from_utf16_lossy(&info.Description[..length]),
                    "vendorID":info.VendorId,"deviceID":info.DeviceId,"dedicatedMemory":info.DedicatedVideoMemory,
                    "software":info.Flags & 2 != 0,"discoveredBy":"Windows DXGI"}));
            }
        }
    }
    json!(adapters)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn python(script:&str)->Launch {
        Launch { program:if cfg!(windows) { "python" } else { "python3" }.into(),
            args:vec!["-u".into(),"-c".into(),script.into()],env:vec![],log:None,background:false }
    }
    #[test]
    fn discovery_is_bounded_and_requires_metadata_contract() {
        let good=python("import json; print(json.dumps({'schemaVersion':1,'probeOnly':True,'devices':[]}))");
        assert_eq!(run(&good,Duration::from_secs(15)).unwrap()["devices"],json!([]));
        assert!(run(&python("print('{\"ready\":true}')"),Duration::from_secs(15)).is_err());
        let start=Instant::now();
        assert!(run(&python("import time; time.sleep(30)"),Duration::from_millis(200)).unwrap_err().contains("timed out"));
        assert!(start.elapsed()<Duration::from_secs(20));
    }
}
