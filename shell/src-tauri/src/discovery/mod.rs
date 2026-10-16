//! Executable inventory is separate from the accepted, embeddable application catalog.
pub mod ntfs;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

pub const PROTOCOL_VERSION: u32 = 1;
pub const CLASSIFIER_VERSION: u32 = 1;
pub const MAX_FRAME_BYTES: usize = 1_048_576;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all="camelCase")]
pub struct Options {
    pub enabled: bool,
    /// Stable volume GUIDs; drive letters are presentation only.
    pub volumes: Vec<String>,
    pub paused: bool,
    pub included: BTreeSet<String>,
    pub hidden: BTreeSet<String>,
}
impl Options {
    pub fn validate(&self) -> Result<(), String> {
        if self.volumes.len()>64 || self.included.len()>20_000 || self.hidden.len()>100_000 {
            return Err("Too many discovery selections.".into());
        }
        if self.volumes.iter().any(|v| !valid_volume(v)) {
            return Err("Select a volume reported by Windows.".into());
        }
        if self.included.iter().chain(self.hidden.iter()).any(|id| !valid_candidate_id(id)) {
            return Err("Invalid executable discovery identity.".into());
        }
        Ok(())
    }
}
pub fn valid_volume(volume: &str) -> bool {
    // \\?\Volume{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}\, no device/path interpolation.
    let Some(id)=volume.strip_prefix(r"\\?\Volume{").and_then(|s|s.strip_suffix(r"}\")) else{return false};
    id.len()==36 && id.bytes().enumerate().all(|(i,b)|
        if [8,13,18,23].contains(&i){b==b'-'}else{b.is_ascii_hexdigit()})
}
pub fn valid_candidate_id(id: &str) -> bool {
    id.strip_prefix("exe:").is_some_and(|s|s.len()==64&&s.bytes().all(|b|b.is_ascii_hexdigit()))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all="snake_case")]
pub enum Phase {
    Disabled, Unavailable, Waiting, Enumerating, Resolving, Metadata,
    Reconciling, Watching, Paused, Failed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all="camelCase")]
pub struct Progress {
    pub version: u32,
    pub phase: Phase,
    pub volume: String,
    pub records: u64,
    pub candidates: u64,
    pub accepted: u64,
    pub total: Option<u64>,
    pub message: Option<String>,
    pub revision: u64,
}
impl Default for Progress {
    fn default()->Self {Self{version:1,phase:Phase::Disabled,volume:String::new(),
        records:0,candidates:0,accepted:0,total:None,message:None,revision:0}}
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all="camelCase")]
pub struct Candidate {
    pub id:String,
    pub volume:String,
    pub file_id:String,
    pub path:String,
    pub name:String,
    pub product:String,
    pub publisher:String,
    pub description:String,
    pub gui:bool,
    pub portable:bool,
    pub classification:String,
    pub reason:String,
    pub file_stamp:String,
}
/// Deterministic and deliberately conservative. Uncertain programs remain reviewable.
pub fn classify(candidate:&Candidate)->(&'static str,&'static str) {
    let path=candidate.path.replace('\\',"/").to_lowercase();
    let stem=path.rsplit('/').next().unwrap_or("").trim_end_matches(".exe");
    if !path.ends_with(".exe") || !candidate.portable {return ("excluded","not_portable_executable")}
    let helpers=["unins","uninstall","setup","installer","updat","crash","reporter","helper",
        "elevation","notification","cefprocess","werfault","squirrel"];
    if helpers.iter().any(|word|stem.contains(word))
        || path.split('/').any(|p|matches!(p,"cache"|"temp"|"tmp"|"$recycle.bin"|"winsxs")) {
        return ("review","internal_or_installation_tool")
    }
    if !candidate.gui {return ("review","command_line_program")}
    let normalize=|s:&str|s.chars().filter(|c|c.is_alphanumeric()).flat_map(char::to_lowercase).collect::<String>();
    let product=normalize(&candidate.product);
    let filename=normalize(stem);
    if product.len()>=3 && filename.len()>=3 && !candidate.publisher.trim().is_empty()
        && (product==filename || product.starts_with(&filename) || filename.starts_with(&product)) {
        ("accepted","identified_gui_application")
    } else {("review","application_identity_uncertain")}
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identities_and_options_are_bounded() {
        assert!(valid_volume(r"\\?\Volume{12345678-1234-abcd-9876-1234567890ab}\"));
        for bad in [r"\\.\C:",r"C:\",r"\\?\Volume{..\}\",r"\\?\Volume{12345678-1234-abcd-9876-1234567890ab}\anything"] {
            assert!(!valid_volume(bad));
        }
        assert!(valid_candidate_id(&format!("exe:{}","a".repeat(64))));
        assert!(!valid_candidate_id("exe:../../anything"));
        assert!(Options{volumes:vec!["C:".into()],..Options::default()}.validate().is_err());
        let state=serde_json::to_value(Progress::default()).unwrap();
        assert!(state["total"].is_null());
    }
    #[test]
    fn executable_components_are_not_automatically_apps() {
        let mut c=Candidate{path:r"D:\Portable\PaintBox\PaintBox.exe".into(),product:"PaintBox".into(),
            name:"PaintBox".into(),publisher:"Example".into(),gui:true,portable:true,..Candidate::default()};
        assert_eq!(classify(&c).0,"accepted");
        c.path=r"D:\Portable\PaintBox\CrashReporter.exe".into();
        assert_eq!(classify(&c),("review","internal_or_installation_tool"));
        c.path=r"D:\Portable\PaintBox\PaintBox.exe".into();c.gui=false;
        assert_eq!(classify(&c).0,"review");
        c.gui=true;c.publisher.clear();
        assert_eq!(classify(&c).0,"review","Unsigned/unknown-publisher apps remain available for review.");
    }
}
