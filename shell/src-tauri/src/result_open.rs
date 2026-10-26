use std::path::Path;

pub fn verify_file(path: &Path) -> Result<(), String> {
    match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_file() => Ok(()),
        Ok(_) => Err("This result is no longer a file. Refresh its folder and search again.".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound =>
            Err("This file is no longer available. Reconnect its drive or refresh its folder and search again.".into()),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied =>
            Err("Windows could not access this file. Check its permissions and try again.".into()),
        Err(_) => Err("This file could not be checked. Reconnect its drive and try again.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_and_directory_results_fail_before_dispatch() {
        let root = std::env::temp_dir().join(format!("digup-open-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("日本語 file.txt");
        std::fs::write(&file, "fixture").unwrap();
        assert!(verify_file(&file).is_ok());
        assert!(verify_file(&root).is_err());
        std::fs::remove_file(&file).unwrap();
        assert!(verify_file(&file).unwrap_err().contains("no longer available"));
        let _ = std::fs::remove_dir(&root);
    }
}
