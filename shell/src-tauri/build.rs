fn main() {
    // The pages are embedded at compile time; without this a change to them alone wouldn't rebuild the app.
    println!("cargo:rerun-if-changed=../ui");
    println!("cargo:rerun-if-env-changed=GITHUB_SHA");
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    let revision = std::process::Command::new("git").args(["rev-parse", "HEAD"]).output().ok()
        .filter(|out| out.status.success()).map(|out| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .unwrap_or_else(|| std::env::var("GITHUB_SHA").unwrap_or_else(|_| "unknown".into()));
    println!("cargo:rustc-env=DIGUP_BUILD={revision}");
    tauri_build::build()
}
