//! Runtime capability probe for private SkyLight/AX symbols (Phase 1C).
//!
//! `#[link(name = "SkyLight")]` in [`super::skylight`] resolves eagerly: if a
//! future macOS removes a symbol the whole process fails at load, with no
//! chance to degrade. Probing the same names with `dlsym` first lets the
//! daemon log exactly what's missing and steer around it — the probe is the
//! seam a public-API fallback ladder hangs off (see the full plan in
//! `ARCHITECTURE.md`).
//!
//! Grouped by feature area so degradation is per capability, not global:
//! spaces enumeration can fall back to `CGWindowList` while window iteration
//! stays private, and so on. Today every group is expected present; the probe
//! turns a would-be launch fault into a loud log line.

use std::ffi::CString;

use tracing::info;

bitflags::bitflags! {
    /// Presence bits for the private symbols the daemon calls, grouped so
    /// degradation is per capability, not global: spaces enumeration can
    /// fall back to `CGWindowList` while window iteration stays private.
    /// Group order matches the declaration order in [`super::skylight`].
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub struct SkylightCaps: u8 {
        /// Connection bootstrap: `SLSMainConnectionID`, `_AXUIElementGetWindow`.
        const CORE = 1 << 0;
        /// Spaces: managed-space enumeration, current space, types, menu-bar id.
        const SPACES = 1 << 1;
        /// Window queries: options/tags listing, ordered-in, find-owner, cursor.
        const WINDOWS = 1 << 2;
        /// The `SLSWindowIterator*` family used by the snapshot slow tick.
        const ITERATOR = 1 << 3;
        /// Process control: front process, PSN connection, event posting.
        const PROCESS = 1 << 4;
        /// Raw AX attribute access and remote-token element creation.
        const AX = 1 << 5;
        /// Display UUID mapping, menu-bar height, brightness.
        const DISPLAY = 1 << 6;
    }
}

impl SkylightCaps {
    /// Whether every group probed present. The daemon's steady state; anything
    /// less is degraded and logged loudly by [`Self::log`].
    #[must_use]
    pub fn is_complete(self) -> bool {
        self.contains(Self::all())
    }

    /// Probe the loaded image for every private symbol the daemon calls.
    /// Safe anywhere (pure `dlsym` reads); call once at startup.
    #[must_use]
    pub fn probe() -> Self {
        let mut caps = Self::empty();
        caps.set(
            Self::CORE,
            all_present(&["SLSMainConnectionID", "_AXUIElementGetWindow"]),
        );
        caps.set(
            Self::SPACES,
            all_present(&[
                "SLSCopyManagedDisplaySpaces",
                "SLSManagedDisplayGetCurrentSpace",
                "SLSSpaceGetType",
                "SLSGetSpaceManagementMode",
                "SLSCopyActiveMenuBarDisplayIdentifier",
            ]),
        );
        caps.set(
            Self::WINDOWS,
            all_present(&[
                "SLSCopyWindowsWithOptionsAndTags",
                "SLSWindowIsOrderedIn",
                "SLSFindWindowAndOwner",
                "SLSGetCurrentCursorLocation",
                "SLSCopyAssociatedWindows",
            ]),
        );
        caps.set(
            Self::ITERATOR,
            all_present(&[
                "SLSWindowQueryWindows",
                "SLSWindowQueryResultCopyWindows",
                "SLSWindowIteratorAdvance",
                "SLSWindowIteratorGetParentID",
                "SLSWindowIteratorGetWindowID",
                "SLSWindowIteratorGetTags",
                "SLSWindowIteratorGetAttributes",
            ]),
        );
        caps.set(
            Self::PROCESS,
            all_present(&[
                "_SLPSGetFrontProcess",
                "SLSGetConnectionIDForPSN",
                "_SLPSSetFrontProcessWithOptions",
                "SLPSPostEventRecordTo",
            ]),
        );
        caps.set(
            Self::AX,
            all_present(&[
                "AXUIElementCopyAttributeValue",
                "AXUIElementSetAttributeValue",
                "AXUIElementPerformAction",
                "_AXUIElementCreateWithRemoteToken",
            ]),
        );
        caps.set(
            Self::DISPLAY,
            all_present(&[
                "CGDisplayCreateUUIDFromDisplayID",
                "CGDisplayGetDisplayIDFromUUID",
                "SLSGetDisplayMenubarHeight",
                "SLSSetWindowListBrightness",
            ]),
        );
        caps
    }

    /// Log the probe result. A missing group is `warn`: the daemon keeps
    /// running on public-API fallbacks, but operators must know it degraded.
    pub fn log(self) {
        if self.is_complete() {
            info!("skylight capabilities: all private symbols present");
        } else {
            tracing::warn!(
                ?self,
                "skylight capabilities: private symbols missing, running degraded"
            );
        }
    }
}

/// Whether every symbol in `names` resolves in the already-loaded image.
fn all_present(names: &[&str]) -> bool {
    names.iter().all(|name| {
        let name = CString::new(*name).expect("probe names are static C strings");
        // SAFETY: read-only `dlsym` probe against the loaded image; the name
        // is NUL-terminated and `RTLD_DEFAULT` is always valid.
        unsafe { !libc::dlsym(libc::RTLD_DEFAULT, name.as_ptr()).is_null() }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_is_stable_across_calls() {
        assert_eq!(
            SkylightCaps::probe(),
            SkylightCaps::probe(),
            "dlsym results must not flicker"
        );
    }

    #[test]
    fn core_bootstrap_symbols_are_present() {
        // The daemon cannot function without the connection id; if this ever
        // fails, the fallback ladder (not the probe) needs extending first.
        let caps = SkylightCaps::probe();
        assert!(
            caps.contains(SkylightCaps::CORE),
            "SLSMainConnectionID must resolve: {caps:?}"
        );
    }

    #[test]
    fn complete_means_every_group() {
        let caps = SkylightCaps::all() - SkylightCaps::DISPLAY;
        assert!(!caps.is_complete(), "one missing group degrades the whole");
    }
}
