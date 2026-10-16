//! Explicit inference policy, migration and effective storage paths. Discovery never runs a model.
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const SCHEMA: u32 = 2;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Acceleration {
    #[serde(default)]
    pub version: u32,
    pub backend: String,
    pub gpu: String,
    pub python: String,
    pub models: String,
    pub selection_required: bool,
    #[serde(default)]
    pub discovery_pending: bool,
    pub discovery_error: Option<String>,
    pub legacy_vulkan_automatic: bool,
    pub migration_notice: Option<String>,
}

impl Default for Acceleration {
    fn default() -> Self {
        Self { version: SCHEMA, backend: if cfg!(target_os = "macos") { "metal" } else { "vulkan" }.into(),
            gpu: String::new(), python: String::new(), models: String::new(), selection_required: false,
            discovery_pending: !cfg!(target_os = "macos"), discovery_error: None, legacy_vulkan_automatic: false, migration_notice: None }
    }
}

impl Acceleration {
    /// Only stored settings use migration. Explicit CLI/backend requests cannot execute the removed mode.
    pub fn migrate(&mut self) -> bool {
        if self.version >= SCHEMA { return false; }
        self.version = SCHEMA;
        self.discovery_pending = false;
        self.discovery_error = None;
        match self.backend.as_str() {
            "nvidia-vulkan" => {
                self.backend = "nvidia-cuda".into(); self.gpu.clear();
                self.migration_notice = Some("NVIDIA acceleration now uses CUDA. The old Vulkan device selection was cleared.".into());
            }
            "vulkan" | "amd-vulkan" if !self.gpu.is_empty() => {
                self.selection_required = true;
                self.migration_notice = Some("Re-select your GPU: legacy Vulkan numbers may identify a different adapter after NVIDIA devices are excluded.".into());
            }
            "vulkan" => { self.discovery_pending = true; self.legacy_vulkan_automatic = true; },
            _ => {}
        }
        true
    }

    pub fn confirmed(mut self) -> Self {
        self.version = SCHEMA; self.selection_required = false; self.discovery_pending = false;
        self.discovery_error = None; self.migration_notice = None; self.legacy_vulkan_automatic = false; self
    }

    pub fn ready(&self) -> bool {
        !self.discovery_pending && !self.selection_required && self.discovery_error.is_none()
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.version > SCHEMA { return Err("These accelerator settings require a newer DigUp.".into()); }
        if self.backend == "nvidia-vulkan" {
            return Err("NVIDIA Vulkan has been removed. Select NVIDIA CUDA for RTX 20-series and newer.".into());
        }
        if !["vulkan", "amd-vulkan", "nvidia-cuda", "openvino-npu", "metal"].contains(&self.backend.as_str()) {
            return Err("Choose NVIDIA CUDA, AMD Vulkan or Intel NPU. CPU inference is disabled.".into());
        }
        if self.backend == "nvidia-cuda" && (self.gpu.starts_with("Vulkan") || self.gpu.starts_with("VK-"))
            || matches!(self.backend.as_str(), "vulkan" | "amd-vulkan") && (self.gpu.starts_with("CUDA") || self.gpu.starts_with("GPU-")) {
            return Err("The selected GPU identifier belongs to another backend. Re-select the GPU.".into());
        }
        if self.backend == "openvino-npu" {
            if !Path::new(&self.python).is_absolute() || !Path::new(&self.python).is_file() {
                return Err("Choose the absolute path to the OpenVINO environment's python.exe.".into());
            }
            if !Path::new(&self.models).is_absolute() || !Path::new(&self.models).join("manifest.json").is_file() {
                return Err("Choose an exported OpenVINO model bundle containing manifest.json.".into());
            }
        }
        Ok(())
    }

    /// Both the CLI and shell receive a base index; scoping is applied once, never guessed from its name.
    pub fn index_directory(&self, base: &Path) -> PathBuf {
        if matches!(self.backend.as_str(), "nvidia-cuda" | "openvino-npu") { base.join(&self.backend) }
        else { base.to_owned() }
    }

    pub fn environment(&self) -> Vec<(String, String)> {
        vec![("DIGUP_ACCELERATOR".into(), self.backend.clone()), ("DIGUP_GPU".into(), self.gpu.clone()),
            ("DIGUP_OPENVINO_PYTHON".into(), self.python.clone()), ("DIGUP_OPENVINO_MODELS".into(), self.models.clone()),
            ("DIGUP_GPU_SELECTION_REQUIRED".into(), if self.selection_required { "1" } else { "0" }.into()),
            ("DIGUP_ACCELERATOR_DISCOVERY_PENDING".into(), if self.discovery_pending { "1" } else { "0" }.into()),
            ("DIGUP_ACCELERATOR_ERROR".into(), self.discovery_error.clone().unwrap_or_default())]
    }

    /// A one-time default resolution; never used to recover from an explicit backend's inference failure.
    pub fn resolve_discovery(&mut self, probe: &serde_json::Value) -> Result<(), String> {
        if !self.discovery_pending { return Ok(()); }
        if probe["schemaVersion"] != 1 { return Err("Unsupported accelerator discovery response.".into()); }
        let devices = probe["devices"].as_array().ok_or("Accelerator discovery returned no device list.")?;
        let eligible: Vec<_> = devices.iter().filter(|d| d["available"] == true && d["hardware"] == true).collect();
        let cuda=eligible.iter().find(|d| d["backend"] == "cuda" && d["vendorID"] == 0x10de && d["computeCapability"].as_u64().unwrap_or(0) >= 75);
        let vulkan=eligible.iter().find(|d| d["backend"] == "vulkan" && d["vendorID"] == 0x1002)
            .or_else(|| eligible.iter().find(|d| d["backend"] == "vulkan" && d["vendorID"].as_u64().is_some_and(|v| v != 0 && v != 0x10de)));
        let found=if self.legacy_vulkan_automatic { vulkan.or(cuda) } else { cuda.or(vulkan) };
        let Some(device) = found else { return Err("No supported GPU is available. NVIDIA requires CUDA and an RTX 20-series or newer GPU. Choose an accelerator in Settings; app launching remains available.".into()); };
        self.backend = if device["backend"] == "cuda" { "nvidia-cuda" } else if device["vendorID"] == 0x1002 { "amd-vulkan" } else { "vulkan" }.into();
        self.gpu = device["stableID"].as_str().filter(|s| !s.is_empty()).or_else(|| device["id"].as_str()).unwrap_or("").into();
        self.discovery_pending = false; self.legacy_vulkan_automatic = false;
        self.migration_notice = Some(format!("Selected {} through {}. Model inference is verified separately.", device["name"].as_str().unwrap_or("GPU"), self.backend));
        Ok(())
    }
}

pub fn compatible_update(url: &str) -> bool {
    url.starts_with("https://github.com/MCShotty/WinDigUp/releases/download/")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn updates_keep_the_forks_execution_policy() {
        assert!(compatible_update("https://github.com/MCShotty/WinDigUp/releases/download/v1/DigUp.exe"));
        assert!(!compatible_update("https://github.com/ARahim3/DigUp/releases/download/v1/DigUp.exe"));
        assert!(!compatible_update("https://github.com/MCShotty/WinDigUp-other/releases/download/v1/DigUp.exe"));
    }
    #[test]
    fn explicit_backends_never_accept_removed_or_cpu_modes() {
        for backend in ["cpu", "auto", "AUTO:NPU,CPU", "HETERO:NPU,CPU", "nvidia-vulkan", ""] {
            assert!(Acceleration { backend: backend.into(), ..Default::default() }.validate().is_err());
        }
        for backend in ["vulkan", "amd-vulkan", "nvidia-cuda"] {
            assert!(Acceleration { backend: backend.into(), ..Default::default() }.validate().is_ok());
        }
        assert!(Acceleration { backend:"nvidia-cuda".into(),gpu:"Vulkan0".into(),..Default::default() }.validate().is_err());
    }
    #[test]
    fn legacy_migration_is_idempotent_and_does_not_alias_numbered_devices() {
        let mut nv: Acceleration = serde_json::from_value(json!({"backend":"nvidia-vulkan","gpu":"Vulkan1"})).unwrap();
        assert!(nv.migrate()); assert_eq!(nv.backend,"nvidia-cuda"); assert!(nv.gpu.is_empty()); assert!(nv.ready());
        assert!(!nv.migrate());
        for backend in ["vulkan","amd-vulkan"] {
            let mut old: Acceleration = serde_json::from_value(json!({"backend":backend,"gpu":"Vulkan1"})).unwrap();
            old.migrate(); assert!(old.selection_required); assert!(!old.ready());
            assert_eq!(old.backend,backend); assert_eq!(old.gpu,"Vulkan1");
            assert!(!old.migrate()); assert!(old.confirmed().ready());
        }
        for backend in ["metal","openvino-npu"] {
            let mut old: Acceleration=serde_json::from_value(json!({"backend":backend,"python":"keep","models":"bundle"})).unwrap();
            old.migrate(); assert_eq!(old.python,"keep"); assert_eq!(old.models,"bundle"); assert!(old.ready());
        }
    }
    #[test]
    fn initial_discovery_filters_unsupported_nvidia_and_never_runs_as_fallback() {
        let explicit:Acceleration=serde_json::from_value(json!({"version":2,"backend":"nvidia-cuda"})).unwrap();
        assert!(!explicit.discovery_pending);
        let probe=json!({"schemaVersion":1,"devices":[
            {"id":"Vulkan0","stableID":"vk-amd","name":"AMD","backend":"vulkan","vendorID":4098,"hardware":true,"available":true},
            {"id":"CUDA0","stableID":"GPU-nv","name":"RTX 2060","backend":"cuda","vendorID":4318,"computeCapability":75,"hardware":true,"available":true}]});
        let mut config=Acceleration { discovery_pending:true,..Default::default() };
        config.resolve_discovery(&probe).unwrap(); assert_eq!(config.backend,"nvidia-cuda"); assert_eq!(config.gpu,"GPU-nv");
        let mut legacy:Acceleration=serde_json::from_value(json!({"backend":"vulkan"})).unwrap();
        legacy.migrate(); legacy.resolve_discovery(&probe).unwrap(); assert_eq!(legacy.backend,"amd-vulkan");
        let no_devices=json!({"schemaVersion":1,"devices":[]});
        config.resolve_discovery(&no_devices).unwrap(); assert_eq!(config.backend,"nvidia-cuda");
        let mut unsupported=Acceleration { discovery_pending:true,..Default::default() };
        assert!(unsupported.resolve_discovery(&json!({"schemaVersion":1,"devices":[{"backend":"vulkan","vendorID":4318,"hardware":true,"available":true}]})).is_err());
    }
    #[test]
    fn index_names_are_base_directories_even_when_named_like_a_backend() {
        let config=Acceleration { backend:"nvidia-cuda".into(),..Default::default() };
        assert_eq!(config.index_directory(Path::new("nvidia-cuda")), Path::new("nvidia-cuda").join("nvidia-cuda"));
    }
}
