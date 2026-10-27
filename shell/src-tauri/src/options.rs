//! What the shell is told at launch. The folders and the hotkey come from the command line until onboarding and the
//! settings window exist.

use std::path::PathBuf;

/// The panel's hotkey unless told otherwise: ⇧⌘Space on a Mac (the Mac app's), Ctrl+Shift+Space elsewhere.
pub const DEFAULT_HOTKEY: &str = "CommandOrControl+Shift+Space";

pub struct Options {
    /// DigUp's helper, `digup` (default: beside this program, where the installers put it).
    pub helper: PathBuf,
    /// The index folder. None: the helper's own default (%LOCALAPPDATA%\DigUp\index on Windows,
    /// ~/.local/share/digup/index on Linux).
    pub index: Option<PathBuf>,
    /// Where the model files are (DIGUP_MODELS for the helpers); None: the helper looks where it always does.
    pub models: Option<PathBuf>,
    /// The folders to search and keep indexed, instead of the settings' (dev runs; setup is then skipped).
    pub roots: Vec<PathBuf>,
    /// Code search's folders, instead of the settings' (dev runs).
    pub code_roots: Vec<PathBuf>,
    /// The hotkey, instead of the settings'.
    pub hotkey: Option<String>,
    /// The settings file, instead of the one in the app's config folder (a fresh first launch in tests).
    pub settings: Option<PathBuf>,
    /// The folders setup offers, instead of the usual ones (Documents, Pictures…): dev runs never offer real folders.
    pub offered: Option<Vec<PathBuf>>,
    /// The folders with code that Settings offers, instead of the ones found in the home folder (dev runs offer none
    /// without it).
    pub offered_code: Option<Vec<PathBuf>>,
    /// Debug runs: setup clicks through by itself (all offered folders, the default hotkey).
    pub debug_setup: bool,
    /// Debug runs: the panel types this query in when it loads and reports what it showed (`debug_report`), hidden
    /// unless `debug_show`: a panel on screen takes the keyboard.
    pub debug_query: Option<String>,
    /// Debug runs: quit once the report is in.
    pub debug_quit: bool,
    /// Debug runs: show the panel at launch and keep it up when it loses focus.
    pub debug_show: bool,
    /// Debug runs: the window opens (hidden unless `debug_show`) with this query typed in ("" for its home) and reports
    /// what it showed.
    pub debug_window: Option<String>,
    /// Debug runs with `debug_window`: the window then opens Settings as its button does, and Settings reports instead.
    pub debug_settings: bool,
    /// Debug runs with `debug_window`: after its report the window copies its selected result, as Ctrl+C does.
    pub debug_copy: bool,
    /// Installed-app check: launch the selected catalog application, then report the accepted request.
    pub debug_launch: bool,
    /// Installed UI checks select a stable result ID without relying on ambiguous names.
    pub debug_selected: Option<String>,
    /// A desktop shortcut's command (hotkey.rs): show or hide the panel of the DigUp already running, or start DigUp
    /// with the panel up.
    pub toggle: bool,
    pub show_panel: bool,
    /// Started at login (the autostart entry says so): DigUp waits in the tray. Opened by hand, it shows its window.
    pub at_login: bool,
    /// Debug runs: check for updates at once (in a dev run too), once.
    pub debug_update_check: bool,
    /// Debug runs with `debug_update_check`: install the update found without asking.
    pub debug_update_install: bool,
}

impl Options {
    pub fn from_args() -> Result<Options, String> {
        let mut options = Options {
            helper: default_helper(),
            index: None,
            models: None,
            roots: Vec::new(),
            code_roots: Vec::new(),
            hotkey: None,
            settings: None,
            offered: None,
            offered_code: None,
            debug_setup: false,
            debug_query: None,
            debug_quit: false,
            debug_show: false,
            debug_window: None,
            debug_settings: false,
            debug_copy: false,
            debug_launch: false,
            debug_selected: None,
            toggle: false,
            show_panel: false,
            at_login: false,
            debug_update_check: false,
            debug_update_install: false,
        };
        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
            match arg.as_str() {
                "--helper" => options.helper = value()?.into(),
                "--index" => options.index = Some(value()?.into()),
                "--models" => options.models = Some(value()?.into()),
                // Separated as PATH is: ":" here, ";" on Windows.
                "--roots" => options.roots = std::env::split_paths(&value()?).collect(),
                "--code-roots" => options.code_roots = std::env::split_paths(&value()?).collect(),
                "--hotkey" => options.hotkey = Some(value()?),
                "--settings" => options.settings = Some(value()?.into()),
                "--offer" => options.offered = Some(std::env::split_paths(&value()?).collect()),
                "--offer-code" => options.offered_code = Some(std::env::split_paths(&value()?).collect()),
                "--debug-setup" => options.debug_setup = true,
                "--debug-query" => options.debug_query = Some(value()?),
                "--debug-quit" => options.debug_quit = true,
                "--debug-show" => options.debug_show = true,
                "--debug-window" => options.debug_window = Some(value()?),
                "--debug-settings" => options.debug_settings = true,
                "--debug-copy" => options.debug_copy = true,
                "--debug-launch" => options.debug_launch = true,
                "--debug-selected" => options.debug_selected = Some(value()?),
                "--toggle" => options.toggle = true,
                "--show-panel" => options.show_panel = true,
                "--at-login" => options.at_login = true,
                "--debug-update-check" => options.debug_update_check = true,
                "--debug-update-install" => options.debug_update_install = true,
                _ => return Err(format!("unknown argument {arg}")),
            }
        }
        // A custom settings file is a development scope. Do not write its catalogs or vectors into an installed index.
        if options.index.is_none(){
            if let Some(settings)=&options.settings{options.index=Some(settings_index(settings));}
        }
        // On a Mac the shell is only tried out: the helper's default index there is the Mac app's.
        if cfg!(target_os = "macos") && options.index.is_none() {
            return Err("pass --index: on a Mac the default index belongs to the DigUp app".into());
        }
        Ok(options)
    }
}

impl Options {
    /// The index folder the helpers use: the one given, else the helper's default (which the watcher must pass over).
    pub fn index_folder(&self) -> Option<PathBuf> {
        if self.index.is_some() {
            return self.index.clone();
        }
        if cfg!(windows) {
            return std::env::var_os("LOCALAPPDATA").map(|local| PathBuf::from(local).join("DigUp").join("index"));
        }
        let data = std::env::var_os("XDG_DATA_HOME").filter(|value| !value.is_empty()).map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")));
        data.map(|data| data.join("digup").join("index"))
    }
}

/// The helper in the `helper` folder beside this program (Windows: "DigUp.exe" and "digup.exe" can't share a folder),
/// or where the Linux packages put it (lib/DigUp/helper beside their bin folder), else beside this program.
fn default_helper() -> PathBuf {
    let name = if cfg!(windows) { "digup.exe" } else { "digup" };
    std::env::current_exe().ok().map(|program| helper_beside(&program))
        .unwrap_or_else(|| PathBuf::from(name))
}

fn helper_beside(program: &std::path::Path) -> PathBuf {
    let name = if cfg!(windows) { "digup.exe" } else { "digup" };
    let folder = program.parent().unwrap_or_else(|| std::path::Path::new("."));
    [folder.join("helper").join(name), folder.join("../lib/DigUp/helper").join(name)]
        .into_iter()
        .find(|helper| helper.is_file())
        .unwrap_or_else(|| {
            // Windows treats DigUp.exe and digup.exe as the same path. A missing installed helper must not launch the shell as its own worker.
            let same_name = program.file_name().is_some_and(|file| file.to_string_lossy().eq_ignore_ascii_case(name));
            if cfg!(windows) && same_name { folder.join("helper").join(name) } else { folder.join(name) }
        })
}

fn settings_index(settings:&std::path::Path)->PathBuf{
    let absolute=if settings.is_absolute(){settings.to_path_buf()}else{std::env::current_dir().unwrap_or_else(|_|PathBuf::from(".")).join(settings)};
    let absolute=absolute.canonicalize().unwrap_or(absolute);
    let identity=crate::applications::digest(&absolute.to_string_lossy());
    absolute.parent().unwrap_or_else(||std::path::Path::new(".")).join(format!(".digup-index-{identity}"))
}
#[cfg(test)]mod isolation_tests{
    use super::*;
    #[cfg(windows)]
    #[test]fn missing_installed_helper_never_resolves_to_the_shell(){
        let root=std::env::temp_dir().join(format!("digup-helper-resolution-{}",std::process::id()));
        let _=std::fs::remove_dir_all(&root);std::fs::create_dir_all(&root).unwrap();
        assert_eq!(helper_beside(&root.join("DigUp.exe")),root.join("helper/digup.exe"));
        assert_eq!(helper_beside(&root.join("digup-shell.exe")),root.join("digup.exe"));
        std::fs::create_dir(root.join("helper")).unwrap();std::fs::write(root.join("helper/digup.exe"),[]).unwrap();
        assert_eq!(helper_beside(&root.join("DigUp.exe")),root.join("helper/digup.exe"));
        let _=std::fs::remove_dir_all(root);
    }
    #[test]fn custom_settings_have_stable_distinct_adjacent_indexes(){
        let root=std::env::temp_dir();let a=root.join("digup-settings-a.json");let b=root.join("digup-settings-b.json");
        assert_ne!(settings_index(&a),settings_index(&b));assert_eq!(settings_index(&a),settings_index(&a));
        assert_eq!(settings_index(&a).parent(),Some(root.as_path()));
    }
}
