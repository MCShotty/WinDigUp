// Real Windows Shell integration without the desktop UI dependency. Installed WebView2 is tested separately.
#[cfg(windows)]
fn main() {
    use digup_application_fixtures::applications::{Catalog, Options};
    use serde_json::json;
    use std::{
        path::PathBuf,
        time::{Duration, Instant},
    };
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    assert_eq!(
        arguments.len(),
        2,
        "provide an isolated index folder and exact fixture name"
    );
    let catalog = Catalog::new(
        PathBuf::from(&arguments[0]).join("applications"),
        Options {
            semantic_enabled: false,
            ..Options::default()
        },
        |_| {},
    );
    catalog.start();
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(30) {
        if let Some(hit) = catalog
            .search(&arguments[1], false)
            .into_iter()
            .find(|h| h.name == arguments[1])
        {
            match catalog.launch(&hit.id) {
                Ok(()) => println!(
                    "{}",
                    json!({"nativeOnly":true,"launchAccepted":true,"applicationId":hit.id,"name":hit.name})
                ),
                Err(error) => {
                    println!(
                        "{}",
                        json!({"nativeOnly":true,"launchAccepted":false,"error":error})
                    );
                    std::process::exit(2);
                }
            }
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    println!(
        "{}",
        json!({"nativeOnly":true,"launchAccepted":false,"catalog":catalog.info()})
    );
    std::process::exit(2);
}
#[cfg(not(windows))]
fn main() {
    eprintln!("This Shell integration harness requires Windows.");
}
