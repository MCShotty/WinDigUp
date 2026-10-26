use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    sync::{mpsc::{self, SyncSender}, Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[cfg(any(windows, test))]
use std::{io::Read, process::{Command, Stdio}};

const INTERVAL: Duration = Duration::from_secs(1);
const DEMAND_LIFETIME: Duration = Duration::from_secs(4);
#[cfg(any(windows, test))]
const OUTPUT_LIMIT: u64 = 4096;
const HISTORY_LIMIT: usize = 120;
type Sampler = dyn Fn(&str) -> Result<Metrics, String> + Send + Sync;

#[derive(Clone, Debug)]
struct Metrics {
    utilization: Option<f64>,
    used: Option<u64>,
    total: Option<u64>,
}

struct Cache {
    target: Option<String>,
    generation: u64,
    requested: Instant,
    last_attempt: Option<Instant>,
    last_success: Option<Instant>,
    value: Value,
    history: VecDeque<Value>,
}

pub struct Monitor {
    cache: Arc<Mutex<Cache>>,
    wake: SyncSender<()>,
    started: bool,
}

impl Default for Monitor {
    fn default() -> Self { Self::with_sampler(Arc::new(sample_nvidia)) }
}

impl Monitor {
    fn with_sampler(sample: Arc<Sampler>) -> Self {
        let cache = Arc::new(Mutex::new(Cache {
            target: None, generation: 0, requested: Instant::now(), last_attempt: None,
            last_success: None, value: empty("waiting", "Waiting for a verified inference device."),
            history: VecDeque::new(),
        }));
        let (wake, receiver) = mpsc::sync_channel(1);
        let worker_cache = cache.clone();
        let started = std::thread::Builder::new().name("DigUp GPU metrics".into()).spawn(move || {
            loop {
                match receiver.recv_timeout(INTERVAL) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
                let request = {
                    let mut state = worker_cache.lock().unwrap();
                    if state.requested.elapsed() > DEMAND_LIFETIME { continue; }
                    let retry = if state.value["state"] == "unavailable" { Duration::from_secs(10) } else { INTERVAL };
                    if state.last_attempt.is_some_and(|last| last.elapsed() < retry) { continue; }
                    let Some(target) = state.target.clone() else { continue; };
                    state.last_attempt = Some(Instant::now());
                    (target, state.generation)
                };
                let result = sample(&request.0);
                let mut state = worker_cache.lock().unwrap();
                if state.generation != request.1 || state.target.as_deref() != Some(request.0.as_str()) { continue; }
                match result {
                    Ok(metrics) => {
                        let at = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64();
                        let row = json!({"sampledAt":at,"utilizationPercent":metrics.utilization,
                            "memoryUsedBytes":metrics.used,"memoryTotalBytes":metrics.total});
                        state.last_success = Some(Instant::now());
                        state.value = empty("ready", "Device-wide readings include other applications.");
                        state.value["sampledAt"] = json!(at);
                        state.value["utilizationPercent"] = json!(metrics.utilization);
                        state.value["memoryUsedBytes"] = json!(metrics.used);
                        state.value["memoryTotalBytes"] = json!(metrics.total);
                        state.history.push_back(row);
                        if state.history.len() > HISTORY_LIMIT { state.history.pop_front(); }
                    }
                    Err(message) => {
                        state.value = empty("unavailable", &message);
                        state.last_success = None;
                    }
                }
            }
        }).is_ok();
        Self { cache, wake, started }
    }

    // Requests only update bounded memory; driver commands run on the sampler thread.
    pub fn snapshot(&self, configured: &Value, verified: &Value) -> Value {
        let mut state = self.cache.lock().unwrap();
        let target = match selected_uuid(configured, verified) {
            Ok(target) => target,
            Err((phase, message)) => {
                if state.target.take().is_some() { state.generation = state.generation.wrapping_add(1); }
                state.value = empty(phase, message);
                state.history.clear();
                state.last_attempt = None;
                state.last_success = None;
                return state.value.clone();
            }
        };
        if !self.started { return empty("unavailable", "The optional metrics sampler could not start."); }
        if state.target.as_deref() != Some(target.as_str()) {
            state.generation = state.generation.wrapping_add(1);
            state.target = Some(target.clone());
            state.value = empty("waiting", "Reading the selected NVIDIA device.");
            state.last_attempt = None;
            state.last_success = None;
            state.history.clear();
        }
        state.requested = Instant::now();
        let mut value = state.value.clone();
        value["deviceId"] = json!(target);
        value["source"] = json!("NVIDIA driver nvidia-smi");
        value["ageMs"] = state.last_success.map(|at| json!(at.elapsed().as_secs_f64() * 1000.)).unwrap_or(Value::Null);
        if state.last_success.is_some_and(|at| at.elapsed() > Duration::from_secs(3)) && value["state"] == "ready" {
            value["state"] = json!("stale");
            value["message"] = json!("The last device reading is stale.");
        }
        value["history"] = json!(state.history);
        let _ = self.wake.try_send(());
        value
    }
}

fn empty(state: &str, message: &str) -> Value {
    json!({"schemaVersion":1,"state":state,"source":Value::Null,"deviceId":Value::Null,
        "sampledAt":Value::Null,"ageMs":Value::Null,"intervalMs":1000,"scope":"device",
        "utilizationPercent":Value::Null,"memoryUsedBytes":Value::Null,"memoryTotalBytes":Value::Null,
        "message":message,"history":[]})
}

fn selected_uuid(configured: &Value, verified: &Value) -> Result<String, (&'static str, &'static str)> {
    if configured["backend"] != "nvidia-cuda" {
        return Err(("unavailable", "Live vendor counters are unavailable for this backend. Pipeline timings remain available."));
    }
    if verified["backend"] != "nvidia-cuda" || verified["executionPolicy"] != "accelerator-only" {
        return Err(("waiting", "Waiting for a verified CUDA inference receipt."));
    }
    let Some(id) = verified["device_id"].as_str().filter(|id| valid_uuid(id)) else {
        return Err(("unavailable", "A verified physical NVIDIA UUID is required for device counters."));
    };
    Ok(id.into())
}

fn valid_uuid(id: &str) -> bool {
    id.len() == 40 && id.starts_with("GPU-") && id.bytes().enumerate().skip(4).all(|(index, byte)| {
        if [12,17,22,27].contains(&index) { byte == b'-' } else { byte.is_ascii_hexdigit() }
    })
}

#[cfg(any(windows, test))]
fn parse_metrics(output: &[u8], expected: &str) -> Result<Metrics, String> {
    let invalid = || "The NVIDIA driver returned an invalid device metrics response.".to_string();
    if output.len() as u64 > OUTPUT_LIMIT { return Err(invalid()); }
    let text = std::str::from_utf8(output).map_err(|_| invalid())?;
    let lines: Vec<_> = text.lines().filter(|line| !line.trim().is_empty()).collect();
    if lines.len() != 1 { return Err(invalid()); }
    let fields: Vec<_> = lines[0].split(',').map(str::trim).collect();
    if fields.len() != 4 || !valid_uuid(fields[0]) || !fields[0].eq_ignore_ascii_case(expected) {
        return Err("The metrics response did not identify the selected physical GPU.".into());
    }
    let number = |raw: &str| -> Result<Option<f64>, String> {
        if matches!(raw, "N/A" | "[N/A]" | "Not Supported" | "[Not Supported]") { return Ok(None); }
        let value = raw.parse::<f64>().map_err(|_| invalid())?;
        if !value.is_finite() || value < 0. { return Err(invalid()); }
        Ok(Some(value))
    };
    let utilization = number(fields[1])?;
    if utilization.is_some_and(|value| value > 100.) { return Err(invalid()); }
    let bytes = |raw: &str| -> Result<Option<u64>, String> {
        let value = number(raw)?;
        if value.is_some_and(|value| value > 67_108_864.) { return Err(invalid()); }
        Ok(value.map(|value| (value * 1_048_576.).round() as u64))
    };
    let used = bytes(fields[2])?;
    let total = bytes(fields[3])?;
    if total == Some(0) || used.zip(total).is_some_and(|(used,total)| used > total) { return Err(invalid()); }
    if utilization.is_none() && used.is_none() && total.is_none() {
        return Err("The NVIDIA driver does not expose the requested counters.".into());
    }
    Ok(Metrics { utilization, used, total })
}

#[cfg(windows)]
fn driver_path() -> Result<std::path::PathBuf, String> {
    let mut buffer = vec![0u16; 32768];
    let length = unsafe {
        windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32)
    } as usize;
    if length == 0 || length >= buffer.len() { return Err("The Windows system directory is unavailable.".into()); }
    use std::os::windows::ffi::OsStringExt;
    let path = std::path::PathBuf::from(std::ffi::OsString::from_wide(&buffer[..length])).join("nvidia-smi.exe");
    if !path.is_file() { return Err("The NVIDIA driver metrics tool is unavailable in the Windows system directory.".into()); }
    Ok(path)
}

fn sample_nvidia(id: &str) -> Result<Metrics, String> {
    if !valid_uuid(id) { return Err("A physical NVIDIA UUID is required for device counters.".into()); }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let mut command = Command::new(driver_path()?);
        command.creation_flags(0x08000000);
        command.args(["--id", id, "--query-gpu=uuid,utilization.gpu,memory.used,memory.total", "--format=csv,noheader,nounits"]);
        let output = run_bounded(&mut command, Duration::from_secs(2))?;
        parse_metrics(&output, id)
    }
    #[cfg(not(windows))]
    { Err("Live vendor counters are currently supported only by the Windows NVIDIA provider.".into()) }
}

#[cfg(any(windows, test))]
fn run_bounded(command: &mut Command, timeout: Duration) -> Result<Vec<u8>, String> {
    let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()
        .map_err(|_| "The NVIDIA driver metrics tool could not start.".to_string())?;
    crate::helper::adopt(&child);
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill(); let _ = child.wait();
        return Err("The metrics output stream is unavailable.".into());
    };
    let (sender, receiver) = mpsc::sync_channel(1);
    if std::thread::Builder::new().name("DigUp metrics output".into()).spawn(move || {
        let mut output = Vec::new();
        let result = stdout.take(OUTPUT_LIMIT + 1).read_to_end(&mut output).map(|_| output);
        let _ = sender.send(result);
    }).is_err() {
        let _ = child.kill(); let _ = child.wait();
        return Err("The metrics output reader could not start.".into());
    }
    let began = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if began.elapsed() < timeout => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill(); let _ = child.wait();
                return Err("The NVIDIA metrics request exceeded its deadline or stopped.".into());
            }
        }
    };
    if !status.success() { return Err("The NVIDIA driver could not read the selected device counters.".into()); }
    let output = receiver.recv_timeout(Duration::from_millis(200))
        .map_err(|_| "The metrics output reader exceeded its deadline.".to_string())?
        .map_err(|_| "The metrics output could not be read.".to_string())?;
    if output.len() as u64 > OUTPUT_LIMIT { return Err("The metrics response exceeded its size limit.".into()); }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    const GPU: &str = "GPU-00112233-4455-6677-8899-aabbccddeeff";
    fn configured() -> Value { json!({"backend":"nvidia-cuda"}) }
    fn verified() -> Value { json!({"backend":"nvidia-cuda","executionPolicy":"accelerator-only","device_id":GPU}) }

    #[test]
    fn counters_require_a_verified_physical_identity() {
        assert_eq!(selected_uuid(&configured(), &verified()).unwrap(), GPU);
        for invalid in ["CUDA0", "GPU-fixture", "Vulkan0", "GPU-00112233-4455-6677-8899-aabbccddeefg"] {
            let mut receipt = verified(); receipt["device_id"] = json!(invalid);
            assert!(selected_uuid(&configured(), &receipt).is_err());
        }
        assert!(selected_uuid(&json!({"backend":"amd-vulkan"}), &verified()).is_err());
        assert!(selected_uuid(&configured(), &json!({"backend":"nvidia-cuda","device_id":GPU})).is_err());
    }

    #[test]
    fn parsing_preserves_unknowns_and_rejects_mismatched_or_invalid_counters() {
        let row = format!("{GPU}, 27, 1024, 8192\n");
        let metrics = parse_metrics(row.as_bytes(), GPU).unwrap();
        assert_eq!(metrics.utilization, Some(27.));
        assert_eq!(metrics.used, Some(1_073_741_824));
        assert_eq!(metrics.total, Some(8_589_934_592));
        assert!(parse_metrics(row.as_bytes(), "GPU-11112233-4455-6677-8899-aabbccddeeff").is_err());
        assert!(parse_metrics(format!("{GPU}, N/A, 12, N/A\n").as_bytes(), GPU).unwrap().utilization.is_none());
        for values in ["101, 1, 2", "NaN, 1, 2", "-1, 1, 2", "20, 3, 2", "20, 1, 0", "N/A, N/A, N/A"] {
            assert!(parse_metrics(format!("{GPU}, {values}\n").as_bytes(), GPU).is_err());
        }
        assert!(parse_metrics(format!("{row}{row}").as_bytes(), GPU).is_err());
        assert!(parse_metrics(&vec![b'x'; OUTPUT_LIMIT as usize + 1], GPU).is_err());
    }

    #[test]
    fn sampling_never_blocks_snapshot_or_publishes_an_older_device() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let release = Arc::new(AtomicBool::new(false));
        let entered = Arc::new(AtomicBool::new(false));
        let monitor = Monitor::with_sampler(Arc::new({
            let release = release.clone(); let entered = entered.clone();
            move |_| {
                entered.store(true, Ordering::SeqCst);
                while !release.load(Ordering::SeqCst) { std::thread::sleep(Duration::from_millis(2)); }
                Ok(Metrics { utilization:Some(50.),used:None,total:None })
            }
        }));
        let first = monitor.snapshot(&configured(), &verified());
        assert_eq!(first["state"], "waiting");
        let deadline = Instant::now() + Duration::from_secs(2);
        while !entered.load(Ordering::SeqCst) && Instant::now() < deadline { std::thread::sleep(Duration::from_millis(2)); }
        assert!(entered.load(Ordering::SeqCst));
        let began = Instant::now();
        assert_eq!(monitor.snapshot(&configured(), &verified())["state"], "waiting");
        assert!(began.elapsed() < Duration::from_millis(100));
        let unsupported = monitor.snapshot(&json!({"backend":"amd-vulkan"}), &Value::Null);
        assert!(unsupported["utilizationPercent"].is_null());
        release.store(true, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(monitor.snapshot(&json!({"backend":"amd-vulkan"}), &Value::Null)["state"], "unavailable");
    }

    #[cfg(unix)]
    #[test]
    fn driver_requests_have_time_and_output_limits() {
        let mut slow = Command::new("/bin/sh"); slow.args(["-c", "sleep 1"]);
        assert!(run_bounded(&mut slow, Duration::from_millis(20)).is_err());
        let mut large = Command::new("/bin/sh"); large.args(["-c", "head -c 10000 /dev/zero"]);
        assert!(run_bounded(&mut large, Duration::from_secs(2)).is_err());
    }
}
