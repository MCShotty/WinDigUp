// The real catalog/ranker, without desktop UI libraries. Linux CI exercises its portable fixture boundary.
#[path = "../../../shell/src-tauri/src/applications/mod.rs"]
pub mod applications;

// The real helper transport uses only this runtime entry point; no desktop UI dependency is needed for its tests.
extern crate self as tauri;
pub mod async_runtime {
    pub use tokio::task::spawn_blocking;
}
#[path = "../../../shell/src-tauri/src/helper.rs"]
pub mod helper;

#[cfg(test)]
mod tests {
    use super::helper::{Launch, SearchService};
    use serde_json::json;
    use std::{
        path::PathBuf,
        time::{Duration, Instant},
    };
    fn python(script: &str) -> SearchService {
        SearchService::new(
            Launch {
                program: PathBuf::from(if cfg!(windows) { "python" } else { "python3" }),
                args: vec!["-u".into(), "-c".into(), script.into()],
                env: vec![],
                log: None,
                background: false,
            },
            |_| {},
        )
    }
    #[tokio::test(flavor = "current_thread")]
    async fn stalled_helper_pipe_does_not_block_executor_or_shutdown() {
        let service = python("import time; time.sleep(3)");
        let copy = service.clone();
        let started = Instant::now();
        let request = tokio::spawn(async move {
            copy.ask(json!({"op":"catalog","payload":"x".repeat(2_000_000)}))
                .await
        });
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
        let service=python("import sys,json\nfor line in sys.stdin:\n r=json.loads(line); print(json.dumps({'id':r['id'],'ok':True,'echo':r['op']}),flush=True)");
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
}
