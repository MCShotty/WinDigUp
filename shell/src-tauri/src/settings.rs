//! What the person chose: the folders DigUp searches, what it skips in them, the hotkey, and whether setup is done. A
//! JSON file in the app's config folder (%APPDATA%\com.abdurrahim.DigUp on Windows, ~/.config/com.abdurrahim.DigUp on
//! Linux). Launch arguments (`--roots`, `--hotkey`) stand in for it in dev runs.

use crate::hours::Hours;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub applications: crate::applications::Options,
    pub windows_settings: crate::system_settings::Options,
    pub discovery: crate::discovery::Options,
    pub enrichment: crate::applications::enrichment::Options,
    pub acceleration: crate::acceleration::Acceleration,
    /// The folders searched and kept indexed.
    pub folders: Vec<String>,
    /// Folders inside them that aren't (`FolderSelection` in the engine).
    pub skipped: Vec<String>,
    /// File extensions left out ("heic", "txt").
    pub skip_types: Vec<String>,
    /// The panel's hotkey (Tauri's accelerator form); empty: the default.
    pub hotkey: String,
    /// Onboarding is done: the shell starts in the tray.
    pub set_up: bool,
    /// The panel sits centered where the desktop places windows itself (Wayland), in a window that fills the screen.
    pub center_panel: bool,
    /// Index only between these times of day (hours.rs); the times are kept while it's off.
    pub index_hours_on: bool,
    pub index_hours: Hours,
    /// Code search: its folders (an index of its own, code.sqlite), the folders skipped inside them, and the editor its
    /// results open in (editors.rs: an editor's id, "" for the first one found, "default" for the file's default app).
    pub code_folders: Vec<String>,
    pub code_skipped: Vec<String>,
    pub code_editor: String,
    /// Code search was turned off and its index is still to be deleted (Windows won't delete a file a helper has open).
    pub delete_code_index: bool,
    /// Where the window was left, for the next time it opens.
    pub window: Option<WindowPlace>,
    /// A click on the tray icon (Windows): "panel" shows the search panel, anything else opens the window.
    pub tray_click: String,
    /// The daily check for updates was turned off (Settings → General; it's on by default).
    pub update_checks_off: bool,
    /// When DigUp last checked for updates (seconds since 1970).
    pub update_checked: u64,
}

/// The window's size inside its frame (logical pixels), where it was (physical; Wayland doesn't tell), and whether it
/// filled the screen.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct WindowPlace {
    pub width: f64,
    pub height: f64,
    pub x: Option<i32>,
    pub y: Option<i32>,
    pub maximized: bool,
}

impl Settings {
    /// The file's settings, or the defaults when there's none (or it can't be read).
    pub fn load(path: &Path) -> Settings {
        let read = std::fs::read(path);
        if read.as_ref().is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound) { return Settings::default(); }
        let mut settings: Settings = match read.ok().and_then(|data| serde_json::from_slice(&data).ok()) {
            Some(settings) => settings,
            None => {
                let mut settings = Settings::default();
                settings.acceleration.discovery_pending = false;
                settings.acceleration.discovery_error = Some("Settings could not be read. The original settings file was preserved; restore it or review Settings before enabling inference.".into());
                return settings;
            }
        };
        if settings.acceleration.migrate() {
            if let Err(error) = settings.save(path) {
                settings.acceleration.discovery_error = Some(format!("Can't save accelerator settings migration: {error}"));
            }
        }
        settings
    }

    /// Written whole to a temporary file first, so a crash never leaves half of it.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(folder) = path.parent() {
            std::fs::create_dir_all(folder)?;
        }
        let temporary = path.with_extension("json.new");
        std::fs::write(&temporary, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(temporary, path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn migration_is_atomic_isolated_and_preserves_annotations_and_folders() {
        let dir=std::env::temp_dir().join(format!("digup-settings-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&dir).unwrap();
        let path=dir.join("custom-settings.json");
        let original=json!({"acceleration":{"backend":"nvidia-vulkan","gpu":"Vulkan1"},
            "folders":["C:/Users/Zoë/Documents"],"codeFolders":["C:/src"],"indexHoursOn":true,
            "applications":{"enabled":true,"overrides":{"app:one":{"aliases":["写真"],"purpose":"Edit images","hidden":true}}}});
        std::fs::write(&path,serde_json::to_vec(&original).unwrap()).unwrap();
        let migrated=Settings::load(&path);
        assert_eq!(migrated.acceleration.backend,"nvidia-cuda"); assert!(migrated.acceleration.gpu.is_empty());
        assert_eq!(migrated.folders,vec!["C:/Users/Zoë/Documents"]); assert!(migrated.index_hours_on);
        assert_eq!(migrated.applications.overrides["app:one"].aliases,vec!["写真"]);
        assert!(migrated.applications.overrides["app:one"].hidden);
        assert_eq!(migrated.applications.mixed_search,crate::applications::MixedSearch::Smart);
        let mut changed=migrated.clone();changed.applications.mixed_search=crate::applications::MixedSearch::AppsOnly;
        changed.save(&path).unwrap();
        assert_eq!(Settings::load(&path).applications.mixed_search,crate::applications::MixedSearch::AppsOnly);
        assert_eq!(Settings::load(&path).applications.overrides["app:one"].aliases,vec!["写真"]);
        let once=std::fs::read(&path).unwrap();
        let again=Settings::load(&path); assert_eq!(again.acceleration.version,2);
        assert_eq!(std::fs::read(&path).unwrap(),once);
        assert!(!dir.join("settings.json").exists());
        std::fs::write(&path,b"{broken").unwrap(); let _=Settings::load(&path);
        assert_eq!(std::fs::read(&path).unwrap(),b"{broken");
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[cfg(test)]mod discovery_preferences_tests{
    use super::*;
    #[test]fn optional_sources_roundtrip_without_changing_existing_preferences(){
        let root=std::env::temp_dir().join(format!("digup-sources-{}-{}",std::process::id(),crate::applications::digest(&format!("{:?}",std::time::SystemTime::now()))));
        std::fs::create_dir_all(&root).unwrap();let file=root.join("custom-settings.json");
        let volume=r"\\?\Volume{12345678-1234-abcd-9876-1234567890ab}\";
        let input=serde_json::json!({"folders":["C:\\Documents"],"setUp":true,"skipTypes":["tmp"],"indexHoursOn":true,
            "applications":{"enabled":true,"overrides":{"app:fixture":{"aliases":["Editor"],"purpose":"My work","hidden":true}}},
            "discovery":{"enabled":true,"volumes":[volume],"paused":true,"included":[format!("exe:{}","1".repeat(64))]},
            "windowsSettings":{"enabled":true,"semanticEnabled":false,"ordinarySearches":false},
            "enrichment":{"enabled":true,"publisherPages":false}});
        let settings:Settings=serde_json::from_value(input).unwrap();settings.discovery.validate().unwrap();settings.save(&file).unwrap();
        let saved=Settings::load(&file);assert_eq!(saved.folders,settings.folders);assert_eq!(saved.skip_types,settings.skip_types);
        assert!(saved.index_hours_on&&saved.set_up&&saved.discovery.paused&&saved.enrichment.enabled);
        assert!(!saved.enrichment.publisher_pages&&!saved.windows_settings.semantic_enabled&&!saved.windows_settings.ordinary_searches);
        assert_eq!(saved.applications.overrides["app:fixture"].purpose,"My work");
        assert_eq!(saved.discovery.volumes,vec![volume]);let _=std::fs::remove_dir_all(root);
    }
}
