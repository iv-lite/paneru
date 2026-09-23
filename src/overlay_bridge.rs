//! Runtime loader for the Swift overlay dylib (`swift-overlay` feature).
//!
//! The `overlay-swift/` `SwiftPM` package builds `libPaneruOverlay.dylib`
//! exposing a versioned C ABI (`@_cdecl` entry points). This loader finds
//! the dylib (next to the running executable, or `$PANERU_OVERLAY_DYLIB`),
//! checks `paneru_overlay_version()`, and resolves each slice's symbols
//! independently: any missing slice — or a missing/broken dylib, or
//! `PANERU_SWIFT_OVERLAY=0` — falls back to the Rust implementation for
//! that slice, mid-tick, never crashing. All calls happen on the main
//! thread, like every `AppKit` call in this codebase.

use std::env;
use std::ffi::{CString, c_char, c_void};
use std::os::raw::{c_double, c_float};
use std::path::PathBuf;

/// C ABI version the Rust side speaks. Bump when entry points change; the
/// loader refuses mismatched dylibs instead of calling garbage.
pub const OVERLAY_ABI_VERSION: u32 = 1;

/// POD mirror of the Swift `PaneruBorderItem` (explicit pad: 4 + 4, then
/// ten doubles — no delayed padding surprises across the boundary).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SwiftBorderItem {
    pub id: i32,
    pub _pad: u32,
    pub x: c_double,
    pub y: c_double,
    pub w: c_double,
    pub h: c_double,
    pub r: c_double,
    pub g: c_double,
    pub b: c_double,
    pub opacity: c_double,
    pub width: c_double,
    pub radius: c_double,
}

type FlashShowFn = unsafe extern "C" fn(
    msg: *const c_char,
    len: usize,
    opacity: c_float,
    x: c_double,
    y: c_double,
);
type VoidFn = unsafe extern "C" fn();
type DropShowFn = unsafe extern "C" fn(
    x: c_double,
    y: c_double,
    w: c_double,
    h: c_double,
    r: c_double,
    g: c_double,
    b: c_double,
    opacity: c_double,
    width: c_double,
    radius: c_double,
);
type BordersSyncFn = unsafe extern "C" fn(items: *const SwiftBorderItem, len: usize);
type DimUpdateFn = unsafe extern "C" fn(
    opacity: c_float,
    r: c_double,
    g: c_double,
    b: c_double,
    has_cutout: i32,
    cx: c_double,
    cy: c_double,
    cw: c_double,
    ch: c_double,
    radius: c_double,
);
type VersionFn = unsafe extern "C" fn() -> u32;

/// One loaded dylib. Each manager (`OverlayManager`, `FlashMessageManager`)
/// holds its own (dyld refcounts the image; startup-only cost). Never
/// `Send`: constructed and called on the main thread only.
pub struct SwiftOverlay {
    handle: *mut c_void,
    pub flash_show: Option<FlashShowFn>,
    pub flash_remove: Option<VoidFn>,
    pub drop_show: Option<DropShowFn>,
    pub drop_hide: Option<VoidFn>,
    pub borders_sync: Option<BordersSyncFn>,
    pub borders_hide: Option<VoidFn>,
    pub dim_update: Option<DimUpdateFn>,
    pub dim_hide: Option<VoidFn>,
    pub dim_remove: Option<VoidFn>,
}

impl Drop for SwiftOverlay {
    fn drop(&mut self) {
        // SAFETY: handle came from a successful dlopen in try_load.
        unsafe {
            libc::dlclose(self.handle);
        }
    }
}

fn dylib_path() -> Option<PathBuf> {
    if let Ok(path) = env::var("PANERU_OVERLAY_DYLIB")
        && !path.is_empty()
    {
        return Some(PathBuf::from(path));
    }
    let exe = crate::util::exe_path()?;
    exe.parent().map(|dir| dir.join("libPaneruOverlay.dylib"))
}

/// Resolves one dylib symbol by exact name; `None` on miss. Signatures must
/// match overlay-swift/Sources ABI (enforced by review + the version gate,
///
/// not the type system — see module docs).
///
/// SAFETY: transmuting a data pointer to a fn pointer of the documented C
/// ABI signature; callers check presence before calling.
unsafe fn sym<T>(handle: *mut c_void, name: &str) -> Option<T> {
    let cname = CString::new(name).ok()?;
    // SAFETY: valid NUL-terminated symbol name; null on miss.
    let ptr = unsafe { libc::dlsym(handle, cname.as_ptr()) };
    if ptr.is_null() {
        None
    } else {
        // SAFETY: see above.
        Some(unsafe { std::mem::transmute_copy::<*mut c_void, T>(&ptr) })
    }
}

impl SwiftOverlay {
    /// Loads the dylib and resolves symbols. `None` means "use Rust":
    /// disabled via env, missing file, version mismatch, or no symbols.
    /// Never logs above debug here — callers decide how loudly to announce.
    pub fn try_load() -> Option<Self> {
        if env::var("PANERU_SWIFT_OVERLAY").is_ok_and(|v| v == "0") {
            return None;
        }
        let path = dylib_path()?;
        if !path.is_file() {
            return None;
        }
        // SAFETY: null-terminated path, RTLD flags are valid constants.
        let handle = unsafe {
            let cpath = CString::new(path.as_os_str().as_encoded_bytes()).ok()?;
            libc::dlopen(cpath.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL)
        };
        if handle.is_null() {
            return None;
        }
        // SAFETY: version fn has a fixed trivial signature; mismatch drops
        // the handle instead of calling anything else.
        let version: Option<VersionFn> = unsafe { sym(handle, "paneru_overlay_version") };
        let ok = version.is_some_and(|f| unsafe { f() } == OVERLAY_ABI_VERSION);
        if !ok {
            unsafe {
                libc::dlclose(handle);
            }
            return None;
        }
        unsafe {
            Some(Self {
                handle,
                flash_show: sym(handle, "paneru_flash_show"),
                flash_remove: sym(handle, "paneru_flash_remove"),
                drop_show: sym(handle, "paneru_drop_show"),
                drop_hide: sym(handle, "paneru_drop_hide"),
                borders_sync: sym(handle, "paneru_borders_sync"),
                borders_hide: sym(handle, "paneru_borders_hide"),
                dim_update: sym(handle, "paneru_dim_update"),
                dim_hide: sym(handle, "paneru_dim_hide"),
                dim_remove: sym(handle, "paneru_dim_remove"),
            })
        }
    }

    /// Whether at least one slice resolved (else this handle is dead weight
    /// and the caller should drop it for a pure-Rust manager).
    pub fn usable(&self) -> bool {
        self.flash_show.is_some()
            || self.drop_show.is_some()
            || self.borders_sync.is_some()
            || self.dim_update.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_env_or_missing_file_falls_back() {
        unsafe { env::set_var("PANERU_SWIFT_OVERLAY", "0") };
        assert!(SwiftOverlay::try_load().is_none());
        unsafe { env::remove_var("PANERU_SWIFT_OVERLAY") };
        unsafe {
            env::set_var(
                "PANERU_OVERLAY_DYLIB",
                "/nonexistent/libPaneruOverlay.dylib",
            );
        }
        assert!(SwiftOverlay::try_load().is_none());
        unsafe { env::remove_var("PANERU_OVERLAY_DYLIB") };
    }

    #[test]
    fn border_item_is_packed_as_documented() {
        assert_eq!(std::mem::size_of::<SwiftBorderItem>(), 4 + 4 + 10 * 8);
        assert_eq!(
            std::mem::offset_of!(SwiftBorderItem, x),
            8,
            "x starts after id+pad"
        );
    }
}
