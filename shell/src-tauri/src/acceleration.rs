//! The same explicit inference choice is passed to query, indexing, worker and speed-check processes.
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Acceleration {
    pub backend: String,
    pub gpu: String,
    pub python: String,
    pub models: String,
}

impl Default for Acceleration {
    fn default() -> Self {
        Self { backend: if cfg!(target_os = "macos") { "metal" } else { "vulkan" }.into(),
               gpu: String::new(), python: String::new(), models: String::new() }
    }
}

impl Acceleration {
    pub fn validate(&self) -> Result<(), String> {
        if !["vulkan", "amd-vulkan", "nvidia-vulkan", "openvino-npu", "metal"].contains(&self.backend.as_str()) {
            return Err("Choose a hardware GPU or Intel NPU. CPU inference is disabled.".into());
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

    pub fn environment(&self) -> Vec<(String, String)> {
        vec![("DIGUP_ACCELERATOR".into(), self.backend.clone()), ("DIGUP_GPU".into(), self.gpu.clone()),
             ("DIGUP_OPENVINO_PYTHON".into(), self.python.clone()), ("DIGUP_OPENVINO_MODELS".into(), self.models.clone())]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn never_offers_cpu_or_automatic_openvino_fallback() {
        for backend in ["cpu", "auto", "AUTO:NPU,CPU", "HETERO:NPU,CPU", ""] {
            let value = Acceleration { backend: backend.into(), ..Default::default() };
            assert!(value.validate().is_err());
        }
        for backend in ["vulkan", "amd-vulkan", "nvidia-vulkan"] {
            let value = Acceleration { backend: backend.into(), ..Default::default() };
            assert!(value.validate().is_ok());
            assert_eq!(value.environment()[0].1, backend);
        }
        assert!(Acceleration { backend: "openvino-npu".into(), ..Default::default() }.validate().is_err());
    }
}
