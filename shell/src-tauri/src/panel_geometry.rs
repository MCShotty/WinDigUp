//! Shared logical panel dimensions and monitor-work-area placement.
use serde::Serialize;

pub const WIDTH: f64 = 640.0;
pub const FIELD_HEIGHT: f64 = 64.0;
pub const MAX_HEIGHT: f64 = 640.0;
const MARGIN: f64 = 16.0;

#[derive(Clone, Copy, Debug)]
pub struct WorkArea { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Frame {
    pub width: f64,
    pub height: f64,
    pub max_height: f64,
    pub x: i32,
    pub y: i32,
}

pub fn frame(work: WorkArea, scale: f64, requested: f64) -> Frame {
    let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };
    let available_width = (work.width / scale).max(1.0);
    let available_height = (work.height / scale).max(1.0);
    let margin_x = MARGIN.min((available_width - 1.0).max(0.0) / 2.0);
    let margin_y = MARGIN.min((available_height - 1.0).max(0.0) / 2.0);
    let width = WIDTH.min(available_width - 2.0 * margin_x);
    // Leave room for at least the field below the fixed top anchor, even on a small work area.
    let top = (available_height * 0.2).min((available_height - FIELD_HEIGHT - margin_y).max(margin_y));
    let max_height = MAX_HEIGHT.min((available_height - top - margin_y).max(1.0));
    let requested = if requested.is_finite() { requested } else { FIELD_HEIGHT };
    let height = requested.max(FIELD_HEIGHT.min(max_height)).min(max_height);
    Frame {
        width, height, max_height,
        x: (work.x + (work.width - width * scale) / 2.0).round() as i32,
        y: (work.y + top * scale).round() as i32,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn growing_results_keep_the_input_anchored_and_clear_of_the_taskbar() {
        for scale in [1.0, 1.25, 1.5, 2.0] {
            let work = WorkArea { x: -1920.0, y: 48.0, width: 1920.0, height: 1032.0 };
            let empty = frame(work, scale, FIELD_HEIGHT);
            let results = frame(work, scale, MAX_HEIGHT);
            assert_eq!((empty.x, empty.y), (results.x, results.y));
            assert!(results.x as f64 >= work.x);
            assert!(results.y as f64 >= work.y);
            assert!(results.x as f64 + results.width * scale <= work.x + work.width + 1.0);
            assert!(results.y as f64 + results.height * scale <= work.y + work.height - 15.0 * scale + 1.0);
        }
    }
    #[test]
    fn small_work_areas_and_invalid_requests_are_bounded() {
        for (width, height) in [(800.0, 600.0), (320.0, 240.0), (80.0, 80.0)] {
            let work = WorkArea { x: 0.0, y: -100.0, width, height };
            for requested in [0.0, f64::NAN, f64::INFINITY, 2000.0] {
                let result = frame(work, 2.0, requested);
                assert!(result.width > 0.0 && result.height > 0.0);
                assert!(result.width * 2.0 <= width);
                assert!(result.y as f64 + result.height * 2.0 <= work.y + height + 1.0);
            }
        }
    }
    #[test]
    fn dimensions_are_logical_at_every_scale() {
        let work = WorkArea { x: 0.0, y: 0.0, width: 3840.0, height: 2160.0 };
        let result = frame(work, 2.0, FIELD_HEIGHT);
        assert_eq!((result.width, result.height), (640.0, 64.0));
    }
}
