use serde::{Deserialize, Serialize};
use std::{collections::{BTreeMap, VecDeque}, time::{Duration, Instant}};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stage {
    pub operations: u64,
    pub units: u64,
    pub milliseconds: f64,
    pub last_ms: f64,
    pub max_ms: f64,
    #[serde(skip)]
    samples: VecDeque<f64>,
}
impl Stage {
    pub fn record(&mut self, elapsed: Duration, units: u64) {
        let ms = elapsed.as_secs_f64() * 1000.0;
        self.operations += 1;
        self.units += units;
        self.milliseconds += ms;
        self.last_ms = ms;
        self.max_ms = self.max_ms.max(ms);
        if self.samples.len() == 128 { self.samples.pop_front(); }
        self.samples.push_back(ms);
    }
    pub fn p95(&self) -> Option<f64> {
        let mut samples: Vec<_> = self.samples.iter().copied().collect();
        samples.sort_by(f64::total_cmp);
        (!samples.is_empty()).then(|| samples[((samples.len() * 95).div_ceil(100) - 1).min(samples.len()-1)])
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Timings {
    pub version: u32,
    pub stages: BTreeMap<String, Stage>,
}
impl Timings {
    pub fn record(&mut self, stage: &str, start: Instant, units: u64) {
        self.version = 1;
        self.stages.entry(stage.into()).or_default().record(start.elapsed(), units);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn timings_bound_samples_and_keep_parallel_stages_separate() {
        let mut timing = Timings::default();
        for _ in 0..200 { timing.record("metadata", Instant::now(), 1); }
        timing.record("enumeration", Instant::now(), 20);
        assert_eq!(timing.stages["metadata"].samples.len(), 128);
        assert_eq!(timing.stages["metadata"].units, 200);
        assert!(timing.stages["metadata"].p95().is_some());
        let value = serde_json::to_value(timing).unwrap();
        assert!(value.get("elapsed").is_none());
        assert!(value["stages"]["metadata"].get("samples").is_none());
    }
}
