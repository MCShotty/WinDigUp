use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangeBatch {
    pub paths: Vec<PathBuf>,
    pub dirty_roots: Vec<PathBuf>,
}

pub fn contains_path(path: &Path, root: &Path) -> bool {
    if path.starts_with(root) { return true; }
    #[cfg(windows)] {
        let normalize=|value: &Path| value.to_string_lossy().replace('\\',"/").trim_end_matches('/').to_lowercase();
        let path=normalize(path);let root=normalize(root);
        return path==root || path.starts_with(&(root+"/"));
    }
    #[cfg(not(windows))] { false }
}

pub struct ChangeAccumulator {
    roots: Vec<PathBuf>,
    paths: BTreeSet<PathBuf>,
    dirty: BTreeSet<PathBuf>,
    bytes: usize,
}
impl ChangeAccumulator {
    pub fn new(roots: &[PathBuf]) -> Self {
        Self { roots: roots.to_vec(), paths: BTreeSet::new(), dirty: BTreeSet::new(), bytes: 0 }
    }
    pub fn is_empty(&self) -> bool {self.paths.is_empty() && self.dirty.is_empty()}
    pub fn dirty_all(&mut self) {
        self.dirty.extend(self.roots.iter().cloned());
        self.paths.clear();
        self.bytes = 0;
    }
    pub fn add(&mut self, path: PathBuf) {
        let owners: Vec<_> = self.roots.iter().filter(|root| contains_path(&path,root)).cloned().collect();
        if owners.is_empty() || owners.iter().any(|root| self.dirty.contains(root)) { return; }
        if owners.iter().any(|root| !path.starts_with(root)) {
            self.dirty.extend(owners);
            self.paths.retain(|path| !self.dirty.iter().any(|root| contains_path(path,root)));
            return;
        }
        #[cfg(windows)]
        let path=PathBuf::from(path.to_string_lossy().replace('\\',"/"));
        let bytes = path.as_os_str().to_string_lossy().len();
        if self.paths.len() >= 1024 || self.bytes.saturating_add(bytes) > 256 * 1024 {
            self.dirty.extend(owners);
            self.paths.retain(|path| !self.dirty.iter().any(|root| contains_path(path,root)));
            self.bytes = self.paths.iter().map(|path| path.as_os_str().to_string_lossy().len()).sum();
            return;
        }
        if self.paths.insert(path) { self.bytes += bytes; }
    }
    pub fn take(&mut self) -> ChangeBatch {
        self.bytes = 0;
        ChangeBatch {
            paths: std::mem::take(&mut self.paths).into_iter().collect(),
            dirty_roots: std::mem::take(&mut self.dirty).into_iter().collect(),
        }
    }
}

pub fn rules_changed(path: &Path) -> bool {
    let name = path.file_name().and_then(|part| part.to_str()).unwrap_or("");
    matches!(name, ".git" | ".gitignore" | ".gitmodules" | "package.json" | "Package.swift" |
        "pyproject.toml" | "setup.py" | "requirements.txt" | "Cargo.toml" | "go.mod" | "pom.xml" |
        "build.gradle" | "build.gradle.kts" | "Gemfile" | "composer.json" | "CMakeLists.txt")
        || path.components().any(|part| part.as_os_str() == ".git")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn deduplicates_and_keeps_both_rename_paths() {
        let mut changes = ChangeAccumulator::new(&[PathBuf::from("/files")]);
        changes.add("/files/old.txt".into()); changes.add("/files/new.txt".into());
        changes.add("/files/new.txt".into()); changes.add("/elsewhere/file".into());
        assert_eq!(changes.take().paths.len(), 2);
        assert!(changes.take().paths.is_empty());
    }
    #[test]
    fn overflow_marks_the_root_for_reconciliation() {
        let mut changes = ChangeAccumulator::new(&[PathBuf::from("/files")]);
        for index in 0..1100 { changes.add(format!("/files/{index}.txt").into()); }
        let batch = changes.take();
        assert_eq!(batch.dirty_roots, vec![PathBuf::from("/files")]);
        assert!(batch.paths.is_empty());
    }
    #[test]
    fn errors_invalidate_roots_and_rule_files_are_not_hidden_noise() {
        let mut changes = ChangeAccumulator::new(&[PathBuf::from("/a"), PathBuf::from("/b")]);
        changes.add("/a/file".into()); changes.dirty_all();
        let batch = changes.take();
        assert_eq!(batch.dirty_roots.len(), 2); assert!(batch.paths.is_empty());
        assert!(rules_changed(Path::new("/a/.gitignore")));
        assert!(rules_changed(Path::new("/a/.git/info/exclude")));
        assert!(rules_changed(Path::new("/a/package.json")));
        assert!(!rules_changed(Path::new("/a/.cache/item")));
    }
    #[cfg(windows)]
    #[test]
    fn windows_case_ambiguity_reconciles_and_separators_are_normalized() {
        let root=PathBuf::from(r"C:\Users\Person\Files");
        let mut changes=ChangeAccumulator::new(&[root.clone()]);
        changes.add(PathBuf::from(r"C:\Users\Person\Files\old.txt"));
        changes.add(PathBuf::from(r"C:\Users\Person\Files\new.txt"));
        let batch=changes.take();
        assert_eq!(batch.paths.len(),2);
        assert!(batch.paths.iter().all(|path|!path.to_string_lossy().contains('\\')));
        changes.add(PathBuf::from(r"c:\USERS\Person\Files\note.txt"));
        let batch=changes.take();
        assert_eq!(batch.dirty_roots,vec![root]);
        assert!(batch.paths.is_empty());
    }

}
