use crate::{acceleration::Acceleration, accelerator_probe, helper};
use serde_json::{json, Value};
use std::{fs, io::{BufRead, BufReader, Read}, path::{Path, PathBuf}, process::{Command, Stdio},
    sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}}, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};

pub struct Setup {
    root: PathBuf,
    worker: PathBuf,
    log: PathBuf,
    state: Mutex<Value>,
    busy: AtomicBool,
    cancel: AtomicBool,
    probe: Mutex<()>,
}

impl Setup {
    pub fn new(base: PathBuf, helper: &Path, log: PathBuf) -> Arc<Self> {
        let current=std::env::current_dir().unwrap_or_else(|_|PathBuf::from("."));
        let base=if base.is_absolute(){base}else{current.join(base)};
        let helper=if helper.is_absolute(){helper.to_path_buf()}else{current.join(helper)};
        Arc::new(Self { root: base.join("openvino-models"),
            worker: helper.parent().unwrap_or(Path::new(".")).join("openvino"), log,
            state: Mutex::new(json!({"phase":"idle"})), busy: AtomicBool::new(false), cancel: AtomicBool::new(false), probe: Mutex::new(()) })
    }

    pub fn resolve(&self, mut config: Acceleration) -> Acceleration {
        if !config.is_openvino() { return config; }
        if config.python.is_empty() { config.python = self.worker.join("python/python.exe").display().to_string(); }
        if config.models.is_empty() {
            if let Ok(bytes) = fs::read(self.root.join("current.json")) {
                if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
                    if let Some(name) = value["bundle"].as_str().filter(|name| name.starts_with("bundle-") && !name.contains('/') && !name.contains('\\')) {
                        let folder = self.root.join(name);
                        if folder.join("manifest.json").is_file() { config.models = folder.display().to_string(); }
                    }
                }
            }
        }
        config
    }

    pub fn snapshot(&self) -> Value { self.state.lock().unwrap().clone() }

    pub fn inspect(&self, config: Acceleration) -> Result<Value, String> {
        if !config.is_openvino() { return Err("Choose Intel OpenVINO before checking Intel setup.".into()); }
        let _probe = self.probe.try_lock().map_err(|_| "An Intel setup check is already running. Wait for it to finish, then choose Check Intel setup.")?;
        let config = self.resolve(config);
        let mut value = if !Path::new(&config.python).is_absolute() || !Path::new(&config.python).is_file() {
            json!({"schemaVersion":1,"probeOnly":true,"devices":[],"runtimeReady":false,"bundleReady":false,
                "backends":[{"backend":config.backend,"state":"unavailable","message":"The bundled OpenVINO runtime is missing. Install the Windows build with Intel support, or choose an environment under Advanced."}],
                "modelMessage":"Choose or prepare an exported OpenVINO model bundle."})
        } else {
            let launch = helper::Launch { program: PathBuf::from(&config.python),
                args: vec!["-I".into(),self.worker.join("setup_probe.py").display().to_string(),
                    "--backend".into(),config.backend.clone(),"--models".into(),config.models.clone()],
                env: vec![("HF_HUB_OFFLINE".into(),"1".into()),("PYTHONUTF8".into(),"1".into())],
                log: Some(self.log.clone()),background:true };
            accelerator_probe::run(&launch,Duration::from_secs(120))?
        };
        value["python"] = json!(config.python);
        value["models"] = json!(config.models);
        value["preparation"] = self.snapshot();
        Ok(value)
    }

    pub fn ready_config(&self, config: Acceleration) -> Result<Acceleration, String> {
        let mut config = self.resolve(config);
        if !config.is_openvino() { config.validate()?; return Ok(config); }
        let result = self.inspect(config.clone())?;
        if result["runtimeReady"] != true {
            return Err(result["backends"][0]["message"].as_str().unwrap_or("OpenVINO runtime is unavailable.").into());
        }
        let devices: Vec<_> = result["devices"].as_array().ok_or("OpenVINO device discovery failed.")?.iter()
            .filter(|device| device["available"] == true && device["backend"] == config.backend).collect();
        let selected = if config.gpu.is_empty() {
            if devices.len()!=1 { return Err("OpenVINO needs one available selected device. Check the Intel driver or choose a listed device.".into()); }
            devices[0]
        } else {
            devices.into_iter().find(|device| device["stableID"] == config.gpu || device["id"] == config.gpu)
                .ok_or("The selected Intel device is unavailable. Refresh devices and re-select it; no fallback was attempted.")?
        };
        if result["bundleReady"] != true {
            return Err(format!("OpenVINO model preparation is required: {}",result["modelMessage"].as_str().unwrap_or("Choose or prepare a bundle under Intel setup.")));
        }
        config.gpu=selected["stableID"].as_str().ok_or("Intel device identity is unavailable.")?.into();
        config.validate()?;
        Ok(config)
    }

    pub fn start(self: &Arc<Self>, config: Acceleration, source: String, revision: String) -> Result<Value,String> {
        if !config.is_openvino() { return Err("Choose Intel NPU or Intel integrated GPU first.".into()); }
        if revision.len()!=40 || !revision.bytes().all(|byte|byte.is_ascii_digit()||(b'a'..=b'f').contains(&byte)) {
            return Err("Use the full 40-character checkpoint revision. Snapshot folders normally use this name.".into());
        }
        let source=PathBuf::from(source);
        if !source.is_absolute() || !source.join("config.json").is_file() {
            return Err("Choose a complete local Transformers checkpoint folder containing config.json; GGUF weights cannot be exported by OpenVINO.".into());
        }
        self.start_internal(config,source,revision,false,String::new())
    }

    pub fn download(self: &Arc<Self>, config: Acceleration, token: String) -> Result<Value,String> {
        if token.len()>512 || (!token.is_empty() && (!token.starts_with("hf_") || !token.bytes().all(|byte|byte.is_ascii_alphanumeric()||byte==b'_'))) {
            return Err("Use a Hugging Face read-only access token, or leave Download access empty.".into());
        }
        self.start_internal(config,PathBuf::new(),String::new(),true,token)
    }

    fn start_internal(self: &Arc<Self>, config: Acceleration, source: PathBuf, revision: String, download: bool, token: String) -> Result<Value,String> {
        if !config.is_openvino() { return Err("Choose Intel NPU or Intel integrated GPU first.".into()); }
        let config=self.resolve(config);
        if !Path::new(&config.python).is_absolute() || !Path::new(&config.python).is_file() { return Err("The bundled OpenVINO Python runtime is missing; install the Intel-enabled Windows build.".into()); }
        if self.busy.compare_exchange(false,true,Ordering::SeqCst,Ordering::SeqCst).is_err() { return Err("A model preparation is already running.".into()); }
        self.cancel.store(false,Ordering::SeqCst);
        *self.state.lock().unwrap()=json!({"phase":"starting","message":"Starting offline model preparation."});
        let owner=self.clone();
        std::thread::spawn(move || {
            let result=owner.prepare(config,source,revision,download,token);
            if let Err(error)=result {
                let cancelled=owner.cancel.load(Ordering::SeqCst);
                *owner.state.lock().unwrap()=json!({"phase":if cancelled{"cancelled"}else{"failed"},"message":error});
            }
            owner.busy.store(false,Ordering::SeqCst);
        });
        Ok(self.snapshot())
    }

    pub fn cancel(&self) -> Value {
        if self.busy.load(Ordering::SeqCst) { self.cancel.store(true,Ordering::SeqCst); }
        self.snapshot()
    }

    fn prepare(&self, config: Acceleration, source: PathBuf, revision: String, download: bool, token: String) -> Result<(),String> {
        fs::create_dir_all(&self.root).map_err(|error|error.to_string())?;
        let identity=format!("bundle-{}-{}",std::process::id(),SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos());
        let folder=self.root.join(&identity);
        let result=self.export(&config,&source,&revision,&folder,download,&token);
        if let Err(error)=result { let _=fs::remove_dir_all(&folder);return Err(error); }
        let temporary=self.root.join("current.json.new");
        fs::write(&temporary,serde_json::to_vec(&json!({"schemaVersion":1,"bundle":identity})).unwrap()).map_err(|error|error.to_string())?;
        fs::rename(temporary,self.root.join("current.json")).map_err(|error|error.to_string())?;
        *self.state.lock().unwrap()=json!({"phase":"ready","message":"Model prepared. Check the selected Intel device, then Apply and Restart.","bundle":folder.display().to_string()});
        Ok(())
    }

    fn export(&self, config:&Acceleration, source:&Path, revision:&str, folder:&Path, download: bool, token:&str) -> Result<(),String> {
        let log=fs::OpenOptions::new().create(true).append(true).open(&self.log).map_err(|error|error.to_string())?;
        let mut command=Command::new(&config.python);
        command.args(["-I",self.worker.join("prepare_model.py").to_str().ok_or("Invalid worker path")?,
            "--output",folder.to_str().ok_or("Invalid destination")?,"--json"])
            .env("HF_HUB_OFFLINE",if download {"0"}else{"1"}).env("HF_HUB_DISABLE_TELEMETRY","1")
            .env("DO_NOT_TRACK","1").env("PYTHONUTF8","1").env("HF_ENDPOINT","https://huggingface.co")
            .env("HF_HUB_VERBOSITY","error").env("DIGUP_HF_DOWNLOAD_TOKEN",token)
            .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::from(log));
        if download {
            command.arg("--download").arg("--cache-root").arg(self.root.join("source"));
        } else {
            command.arg("--source").arg(source).arg("--revision").arg(revision);
        }
        #[cfg(windows)] { use std::os::windows::process::CommandExt;command.creation_flags(0x08004000); }
        let mut child=command.spawn().map_err(|error|format!("Cannot start offline preparation: {error}"))?;
        helper::adopt(&child);
        let output=child.stdout.take().ok_or("Preparation output is unavailable.")?;
        let (send,receive)=std::sync::mpsc::sync_channel::<Value>(32);
        let reader=std::thread::spawn(move || {
            let mut input=BufReader::new(output.take(8_388_608));
            let mut bytes=Vec::new();
            while input.read_until(b'\n',&mut bytes).ok().is_some_and(|count|count>0) {
                if bytes.len()<16384 {
                    if let Ok(value)=serde_json::from_slice::<Value>(&bytes) { let _=send.try_send(value); }
                }
                bytes.clear();
            }
        });
        let started=Instant::now();
        let status=loop {
            while let Ok(event)=receive.try_recv() {
                if event["event"]=="preparation" && event["phase"]!="ready" {
                    *self.state.lock().unwrap()=json!({"phase":event["phase"],"message":event["message"]});
                }
            }
            if self.cancel.load(Ordering::SeqCst) || started.elapsed()>Duration::from_secs(7200) {
                let _=child.kill();let _=child.wait();let _=reader.join();
                return Err(if self.cancel.load(Ordering::SeqCst) {"Model preparation cancelled."}else{"Model preparation timed out; existing bundles and settings were retained."}.into());
            }
            match child.try_wait() {
                Ok(Some(status))=>break status,
                Err(error)=>{let _=child.kill();let _=child.wait();return Err(error.to_string());}
                _=>std::thread::sleep(Duration::from_millis(100)),
            }
        };
        let _=reader.join();
        while let Ok(event)=receive.try_recv() {
            if event["event"]=="preparation" && event["phase"]=="failed" {
                return Err(event["message"].as_str().unwrap_or("Offline model preparation failed.").into());
            }
        }
        if !status.success() || !folder.join("manifest.json").is_file() {
            let state=self.state.lock().unwrap();
            return Err(if state["phase"]=="failed" { state["message"].as_str().unwrap_or("Model preparation failed.").to_string() }
                else { "Model preparation failed. Review the OpenVINO setup log; existing bundles were retained.".into() });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_runtime_and_invalid_preparation_are_actionable_without_changing_settings() {
        let root=std::env::temp_dir().join(format!("digup-ov-{}",std::process::id()));
        let setup=Setup::new(root.clone(),&root.join("helper/digup.exe"),root.join("setup.log"));
        let config=Acceleration{backend:"openvino-gpu".into(),..Default::default()};
        let result=setup.inspect(config.clone()).unwrap();
        assert_eq!(result["runtimeReady"],false);
        assert_eq!(result["devices"],json!([]));
        assert!(setup.ready_config(config.clone()).unwrap_err().contains("runtime"));
        assert!(setup.start(config.clone(),root.display().to_string(),"short".into()).unwrap_err().contains("40-character"));
        assert_eq!(setup.snapshot()["phase"],"idle");
        assert!(Path::new(&setup.resolve(config).python).ends_with(Path::new("openvino/python/python.exe")));
    }
    #[test]
    fn relative_development_paths_resolve_inside_the_requested_scope() {
        let base=PathBuf::from(format!("relative-intel-scope-{}",std::process::id()));
        let setup=Setup::new(base.clone(),Path::new("helper/digup.exe"),PathBuf::from("setup.log"));
        assert_eq!(setup.root,std::env::current_dir().unwrap().join(base).join("openvino-models"));
        assert!(setup.worker.is_absolute());
    }

    #[test]
    fn managed_bundle_pointer_cannot_escape_the_custom_index() {
        let root=std::env::temp_dir().join(format!("digup-ov-pointer-{}",std::process::id()));
        let setup=Setup::new(root.clone(),&root.join("helper/digup.exe"),root.join("setup.log"));
        fs::create_dir_all(&setup.root).unwrap();
        fs::write(setup.root.join("current.json"),br#"{"bundle":"bundle-../../outside"}"#).unwrap();
        let config=Acceleration{backend:"openvino-npu".into(),..Default::default()};
        assert!(setup.resolve(config.clone()).models.is_empty());
        let keep=Acceleration{python:"custom-python".into(),models:"custom-model".into(),..config};
        assert_eq!(setup.resolve(keep.clone()).python,keep.python);
        assert_eq!(setup.resolve(keep.clone()).models,keep.models);
        let _=fs::remove_dir_all(root);
    }
    #[test]
    fn preparation_is_serial_cancellable_and_retains_the_previous_bundle() {
        let root=std::env::temp_dir().join(format!("digup-ov-cancel-{}",std::process::id()));
        let worker=root.join("helper/openvino");fs::create_dir_all(&worker).unwrap();
        let source=root.join("source");fs::create_dir_all(&source).unwrap();fs::write(source.join("config.json"),"{}").unwrap();
        fs::write(worker.join("prepare_model.py"),"import json,time\nprint(json.dumps({'event':'preparation','phase':'exporting','message':'fixture waiting'}),flush=True)\ntime.sleep(60)\n").unwrap();
        let executable=Command::new(if cfg!(windows){"python"}else{"python3"}).args(["-c","import sys;print(sys.executable)"]).output().unwrap();
        assert!(executable.status.success());
        let python=String::from_utf8(executable.stdout).unwrap().trim().to_string();
        let setup=Setup::new(root.clone(),&root.join("helper/digup.exe"),root.join("setup.log"));
        fs::create_dir_all(&setup.root).unwrap();
        let previous=br#"{"schemaVersion":1,"bundle":"bundle-previous"}"#;
        fs::write(setup.root.join("current.json"),previous).unwrap();
        let config=Acceleration{backend:"openvino-gpu".into(),python,..Default::default()};
        setup.start(config.clone(),source.display().to_string(),"a".repeat(40)).unwrap();
        assert!(setup.start(config,source.display().to_string(),"a".repeat(40)).unwrap_err().contains("already running"));
        let started=Instant::now();
        while setup.snapshot()["phase"]!="exporting" && started.elapsed()<Duration::from_secs(15) { std::thread::sleep(Duration::from_millis(10)); }
        assert_eq!(setup.snapshot()["phase"],"exporting");
        setup.cancel();
        let started=Instant::now();
        while setup.busy.load(Ordering::SeqCst) && started.elapsed()<Duration::from_secs(5) { std::thread::sleep(Duration::from_millis(10)); }
        assert!(!setup.busy.load(Ordering::SeqCst));
        assert_eq!(setup.snapshot()["phase"],"cancelled");
        assert_eq!(fs::read(setup.root.join("current.json")).unwrap(),previous);
        let _=fs::remove_dir_all(root);
    }

}
