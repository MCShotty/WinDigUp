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
            else { windows::material_restriction().unwrap_or_default() };
        if status.reason.is_empty() { status.material = "acrylic".into(); }
        if previous != Some(&status) && status.material == "acrylic" {
            let tint = if dark { (28, 31, 29, 128) } else { (246, 248, 245, 128) };
            if let Err(error) = windows::apply_acrylic(window, tint) {
                status.material = "solid".into();
                status.reason = format!("Windows transparency is unavailable: {error}");
                windows::clear_acrylic(window);
            }
        } else if previous != Some(&status) {
            windows::clear_acrylic(window);
        }
        if !windows::shape(window, true) && status.material == "acrylic" {
            windows::clear_acrylic(window);
            status.material = "solid".into();
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
        System::{
            LibraryLoader::{GetModuleHandleW, GetProcAddress},
            Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD},
        },
        UI::{
            Accessibility::{HIGHCONTRASTW, HCF_HIGHCONTRASTON},
            WindowsAndMessaging::{GetSystemMetrics, SystemParametersInfoW, SM_REMOTESESSION, SPI_GETHIGHCONTRAST},
        },
    };

    // Accent-policy ABI follows window-vibrancy 0.8.1 (Tauri Programme, MIT/Apache-2.0).
    #[repr(C)]
    struct AccentPolicy { state: u32, flags: u32, color: u32, animation: u32 }
    #[repr(C)]
    struct CompositionAttribute { attribute: u32, data: *mut c_void, bytes: usize }

    fn accent(window: &WebviewWindow, state: u32, color: (u8, u8, u8, u8)) -> Result<(), String> {
        let hwnd = window.hwnd().map_err(|error| error.to_string())?;
        let library: Vec<u16> = "user32.dll\0".encode_utf16().collect();
        unsafe {
            let module = GetModuleHandleW(library.as_ptr());
            if module.is_null() { return Err("Windows window effects are unavailable.".into()) }
            let procedure = GetProcAddress(module, b"SetWindowCompositionAttribute\0".as_ptr())
                .ok_or_else(|| "Windows window effects are unavailable.".to_string())?;
            type SetAccent = unsafe extern "system" fn(*mut c_void, *mut CompositionAttribute) -> i32;
            let set: SetAccent = std::mem::transmute(procedure);
            let mut policy = AccentPolicy {
                state, flags: 0,
                color: u32::from(color.0) | u32::from(color.1) << 8
                    | u32::from(color.2) << 16 | u32::from(color.3) << 24,
                animation: 0,
            };
            let mut data = CompositionAttribute {
                attribute: 0x13, data: &mut policy as *mut _ as *mut c_void,
                bytes: std::mem::size_of::<AccentPolicy>(),
            };
            if set(hwnd.0, &mut data) == 0 {
                return Err("Windows could not apply the requested panel effect.".into());
            }
        }
        Ok(())
    }

    pub fn apply_acrylic(window: &WebviewWindow, color: (u8, u8, u8, u8)) -> Result<(), String> {
        // Windows 11's system backdrop paints outside a custom capsule region.
        let _ = window_vibrancy::clear_acrylic(window);
        accent(window, 4, color)
    }

    pub fn clear_acrylic(window: &WebviewWindow) {
        let _ = window_vibrancy::clear_acrylic(window);
        let _ = accent(window, 0, (0, 0, 0, 0));
    }

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
        let radius = if size.height as f64 / scale <= crate::panel_geometry::FIELD_HEIGHT + 1.0 { 32.0 } else { 22.0 };
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
