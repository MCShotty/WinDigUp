// The real catalog/ranker, without desktop UI libraries. Linux CI exercises its portable fixture boundary.
#[path = "../../../shell/src-tauri/src/applications/mod.rs"]
pub mod applications;

// The real helper transport uses only this runtime entry point; no desktop UI dependency is needed for its tests.
extern crate self as tauri;
pub mod async_runtime {
    pub use tokio::task::spawn_blocking;
}
#[path = "../../../shell/src-tauri/src/activity.rs"]
pub mod activity;
#[path = "../../../shell/src-tauri/src/diagnostics.rs"]
pub mod diagnostics;
#[path = "../../../shell/src-tauri/src/helper.rs"]
pub mod helper;
#[path = "../../../shell/src-tauri/src/status.rs"]
pub mod status;

#[cfg(test)]
mod tests {
    use super::helper::{IndexService, Launch, SearchService};
    use serde_json::json;
    use std::{
        path::PathBuf,
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        },
        time::{Duration, Instant},
    };
    fn python(
        script: &str,
        on_event: impl Fn(serde_json::Value) + Send + Sync + 'static,
    ) -> SearchService {
        SearchService::new(
            Launch {
                program: PathBuf::from(if cfg!(windows) { "python" } else { "python3" }),
                args: vec!["-u".into(), "-c".into(), script.into()],
                env: vec![],
                log: None,
                background: false,
            },
            on_event,
        )
    }
    #[tokio::test(flavor = "current_thread")]
    async fn stalled_helper_pipe_does_not_block_executor_or_shutdown() {
        let ready = Arc::new(AtomicBool::new(false));
        let signal = ready.clone();
        let service = python(
            "import time; print('{\"event\":\"fixture_ready\"}',flush=True); time.sleep(30)",
            move |event| {
                if event["event"] == "fixture_ready" {
                    signal.store(true, Ordering::SeqCst);
                }
            },
        );
        let copy = service.clone();
        let request = tokio::spawn(async move {
            copy.ask(json!({"op":"catalog","payload":"x".repeat(2_000_000)}))
                .await
        });
        // Windows process creation/antivirus can exceed 100 ms. Time the pipe after the child is actually ready.
        let startup = Instant::now();
        while !ready.load(Ordering::SeqCst) && startup.elapsed() < Duration::from_secs(15) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        if !ready.load(Ordering::SeqCst) {
            service.stop();
            panic!("fixture subprocess did not start");
        }
        assert!(
            !request.is_finished(),
            "fixture did not keep the helper pipe blocked"
        );
        let started = Instant::now();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(
            started.elapsed() < Duration::from_millis(700),
            "helper write blocked the single-thread executor"
        );
        let generation = service.generation();
        assert!(generation > 0);
        let stopped = Instant::now();
        service.stop();
        assert!(
            stopped.elapsed() < Duration::from_millis(700),
            "shutdown waited for the helper's blocked writer"
        );
        assert!(request.await.unwrap().is_err());
    }
    #[tokio::test(flavor = "current_thread")]
    async fn concurrent_reply_ids_and_restart_generation_remain_correct() {
        let service=python("import sys,json\nfor line in sys.stdin:\n r=json.loads(line); print(json.dumps({'id':r['id'],'ok':True,'echo':r['op']}),flush=True)", |_| {});
        let (a, b) = tokio::join!(
            service.ask(json!({"op":"one"})),
            service.ask(json!({"op":"two"}))
        );
        assert_eq!(a.unwrap()["echo"], "one");
        assert_eq!(b.unwrap()["echo"], "two");
        let previous = service.generation();
        service.stop();
        assert_eq!(
            service.ask(json!({"op":"after-restart"})).await.unwrap()["echo"],
            "after-restart"
        );
        assert_ne!(previous, service.generation());
        service.stop();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn retired_search_process_cannot_publish_over_its_replacement() {
        use std::sync::Mutex;
        let held = Arc::new(AtomicBool::new(false));
        let release = Arc::new(AtomicBool::new(false));
        let events = Arc::new(Mutex::new(Vec::new()));
        let (signal, gate, record) = (held.clone(), release.clone(), events.clone());
        let service=python("import sys,json\nfor line in sys.stdin:\n r=json.loads(line)\n if r['op']=='hold':\n  print('{\"event\":\"hold\"}',flush=True)\n  print('{\"event\":\"encoder\",\"state\":\"unavailable\"}',flush=True)\n print(json.dumps({'id':r['id'],'ok':True}),flush=True)", move |event| {
            if event["event"]=="hold" {
                signal.store(true,Ordering::SeqCst);
                let deadline=Instant::now();
                while !gate.load(Ordering::SeqCst) && deadline.elapsed()<Duration::from_secs(30) { std::thread::sleep(Duration::from_millis(5)); }
            } else { record.lock().unwrap().push(event); }
        });
        let copy = service.clone();
        let old = tokio::spawn(async move { copy.ask(json!({"op":"hold"})).await });
        let startup = Instant::now();
        // Process startup is not part of the behavior under test. Match the allowance
        // used by the blocked-pipe fixture for Windows process creation/antivirus.
        while !held.load(Ordering::SeqCst) && startup.elapsed() < Duration::from_secs(15) {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        if !held.load(Ordering::SeqCst) {
            release.store(true, Ordering::SeqCst);
            service.stop();
            panic!("fixture subprocess did not reach the held event");
        }
        service.stop();
        assert!(old.await.unwrap().is_err());
        service.ask(json!({"op":"replacement"})).await.unwrap();
        release.store(true, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(150)).await;
        let stale = events.lock().unwrap().clone();
        service.stop();
        assert!(stale.is_empty(), "retired worker published {stale:?}");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn restart_uses_current_folders_instead_of_startup_arguments() {
        let script = "import sys,json\nfolders=sys.argv[1:]\nfor line in sys.stdin:\n r=json.loads(line)\n if r['op']=='folders': folders=r['folders']\n print(json.dumps({'id':r['id'],'ok':True,'folders':folders}),flush=True)";
        let service = python(script, |_| {});
        service
            .ask(json!({"op":"folders","folders":["new folder"]}))
            .await
            .unwrap();
        service.set_arguments(vec![
            "-u".into(),
            "-c".into(),
            script.into(),
            "new folder".into(),
        ]);
        service.stop();
        assert_eq!(
            service.ask(json!({"op":"query"})).await.unwrap()["folders"],
            json!(["new folder"])
        );
        service.stop();
    }

    #[test]
    fn retired_indexer_cannot_reset_the_new_scan() {
        use std::sync::Mutex;
        let held = Arc::new(AtomicBool::new(false));
        let release = Arc::new(AtomicBool::new(false));
        let replaced = Arc::new(AtomicBool::new(false));
        let events = Arc::new(Mutex::new(Vec::new()));
        let (signal, gate, ready, record) = (
            held.clone(),
            release.clone(),
            replaced.clone(),
            events.clone(),
        );
        let service = IndexService::new(move |event| {
            if event["event"] == "hold" {
                signal.store(true, Ordering::SeqCst);
                let start = Instant::now();
                while !gate.load(Ordering::SeqCst) && start.elapsed() < Duration::from_secs(30) {
                    std::thread::sleep(Duration::from_millis(5));
                }
            } else {
                if event["event"] == "replacement" {
                    ready.store(true, Ordering::SeqCst);
                }
                record.lock().unwrap().push(event);
            }
        });
        let mut launch = Launch {
            program: PathBuf::from(if cfg!(windows) { "python" } else { "python3" }),
            args: vec!["-u".into(), "-c".into(),
                "import sys; print('{\"event\":\"hold\"}',flush=True); print('{\"event\":\"error\",\"message\":\"retired index failed\"}',flush=True); sys.stdin.readline()".into()],
            env: vec![], log: None, background: false,
        };
        service.run(&launch).unwrap();
        let start = Instant::now();
        while !held.load(Ordering::SeqCst) && start.elapsed() < Duration::from_secs(15) {
            std::thread::sleep(Duration::from_millis(5));
        }
        if !held.load(Ordering::SeqCst) {
            release.store(true, Ordering::SeqCst);
            service.stop();
            panic!("fixture subprocess did not reach the held event");
        }
        launch.args[2] =
            "import sys; print('{\"event\":\"replacement\"}',flush=True); sys.stdin.readline()"
                .into();
        service.run(&launch).unwrap();
        let start = Instant::now();
        while !replaced.load(Ordering::SeqCst) && start.elapsed() < Duration::from_secs(15) {
            std::thread::sleep(Duration::from_millis(5));
        }
        release.store(true, Ordering::SeqCst);
        assert!(replaced.load(Ordering::SeqCst));
        std::thread::sleep(Duration::from_millis(150));
        service.stop();
        assert!(!events
            .lock()
            .unwrap()
            .iter()
            .any(|e| e["message"] == "retired index failed"));
    }
}
