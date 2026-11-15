//! Native material and rounded hit regions for the compact launcher.
use crate::settings::{Appearance, PanelMaterial};
use serde::Serialize;
use tauri::WebviewWindow;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MaterialStatus {
    pub supported: bool,
    pub material: String,
    pub dark: bool,
    pub reason: String,
}

pub fn apply(window: &WebviewWindow, appearance: &Appearance, preference: &PanelMaterial,
             previous: Option<&MaterialStatus>) -> MaterialStatus {
    let dark = match appearance {
        Appearance::Light => false,
        Appearance::Dark => true,
        Appearance::System => matches!(window.theme(), Ok(tauri::Theme::Dark)),
    };
    let _ = window.set_background_color(Some(tauri::window::Color(0, 0, 0, 0)));
    let mut status = MaterialStatus { supported: cfg!(windows), material: "solid".into(), dark, reason: String::new() };
    #[cfg(windows)]
    {
        status.reason = if *preference == PanelMaterial::Solid { "Solid panel selected.".into() }
            else { windows::material_restriction().unwrap_or_else(||
                "Windows native transparency cannot follow this panel's rounded shape. Using Solid.".into()) };
        if previous.map(|value| value.material.as_str()) != Some("solid") {
            let _ = window_vibrancy::clear_acrylic(window);
            let _ = window_vibrancy::clear_blur(window);
        }
        if !windows::shape(window, true) {
            status.reason = "Windows rounded clipping is unavailable; using a solid panel.".into();
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (preference, previous);
        status.reason = "Native panel transparency is unavailable on this desktop.".into();
    }
    status
}

/// A queued focus-loss notification must not dismiss a panel that already regained foreground ownership.
pub fn owns_foreground(window: &WebviewWindow) -> bool {
    #[cfg(windows)] {
        use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow,GetAncestor,GA_ROOTOWNER};
        let Ok(hwnd)=window.hwnd() else{return false};
        let foreground=unsafe{GetForegroundWindow()};
        return foreground==hwnd.0 || (!foreground.is_null() && unsafe{GetAncestor(foreground,GA_ROOTOWNER)}==hwnd.0);
    }
    #[cfg(not(windows))] window.is_focused().unwrap_or(false)
}

pub fn shape(window: &WebviewWindow) {
    #[cfg(windows)]
    { windows::shape(window, false); }
    #[cfg(not(windows))]
    let _ = window;
}

#[cfg(windows)]
mod windows {
    use super::*;
    use std::ffi::c_void;
    use std::sync::{Mutex, OnceLock};
    type ShapeKey = (isize, u32, u32, u64, i32, i32);
    #[derive(Default)]
    struct ShapeState { applying: bool, applied: Option<ShapeKey> }
    static SHAPE: OnceLock<Mutex<ShapeState>> = OnceLock::new();
    use windows_sys::Win32::{
        Graphics::Gdi::{CreateRoundRectRgn, DeleteObject, SetWindowRgn},
        Graphics::Dwm::DwmIsCompositionEnabled,
        System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD},
        UI::{
            Accessibility::{HIGHCONTRASTW, HCF_HIGHCONTRASTON},
            WindowsAndMessaging::{GetSystemMetrics, SystemParametersInfoW, SM_REMOTESESSION, SPI_GETHIGHCONTRAST},
        },
    };

    pub fn material_restriction() -> Option<String> {
        unsafe {
            let mut contrast: HIGHCONTRASTW = std::mem::zeroed();
            contrast.cbSize = std::mem::size_of::<HIGHCONTRASTW>() as u32;
            if SystemParametersInfoW(SPI_GETHIGHCONTRAST, contrast.cbSize,
                &mut contrast as *mut _ as *mut c_void, 0) == 0 {
                return Some("Windows contrast settings could not be read.".into());
            }
            if contrast.dwFlags & HCF_HIGHCONTRASTON != 0 {
                return Some("Windows contrast mode uses a solid panel.".into());
            }
            if GetSystemMetrics(SM_REMOTESESSION) != 0 {
                return Some("Remote Desktop uses a solid panel.".into());
            }
            let mut composition = 0;
            if DwmIsCompositionEnabled(&mut composition) < 0 || composition == 0 {
                return Some("Windows desktop composition is unavailable.".into());
            }
            let key: Vec<u16> = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize\0".encode_utf16().collect();
            let name: Vec<u16> = "EnableTransparency\0".encode_utf16().collect();
            let mut enabled = 0u32;
            let mut size = std::mem::size_of::<u32>() as u32;
            let read = RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), RRF_RT_REG_DWORD,
                std::ptr::null_mut(), &mut enabled as *mut _ as *mut c_void, &mut size);
            if read != 0 || enabled == 0 {
                return Some("Windows transparency effects are off or unavailable.".into());
            }
        }
        None
    }

    pub fn shape(window: &WebviewWindow, force: bool) -> bool {
        let (Ok(hwnd), Ok(size), Ok(scale)) = (window.hwnd(), window.inner_size(), window.scale_factor()) else { return false };
        let (left, top) = match (window.inner_position(), window.outer_position()) {
            (Ok(inner), Ok(outer)) => (inner.x - outer.x, inner.y - outer.y),
            _ => return false,
        };
        let key = (hwnd.0 as isize, size.width, size.height, scale.to_bits(), left, top);
        let cached = SHAPE.get_or_init(|| Mutex::new(ShapeState::default()));
        {
            let mut state = cached.lock().unwrap();
            if state.applying { return state.applied == Some(key); }
            if !force && state.applied == Some(key) { return true; }
            state.applying = true;
        }
        let radius=12.0;
        let diameter = (radius * 2.0 * scale).round() as i32;
        let applied = unsafe {
            let region = CreateRoundRectRgn(left, top, left + size.width as i32 + 1, top + size.height as i32 + 1, diameter, diameter);
            if region.is_null() { false }
            else if SetWindowRgn(hwnd.0, region, 1) == 0 {
                // Windows owns accepted regions.
                DeleteObject(region);
                false
            } else { true }
        };
        let mut state = cached.lock().unwrap();
        state.applying = false;
        state.applied = if applied { Some(key) } else { None };
        applied
    }
}
