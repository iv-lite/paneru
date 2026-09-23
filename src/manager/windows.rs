use accessibility_sys::{
    AXUIElementCopyElementAtPosition, AXUIElementCreateApplication, AXUIElementRef, AXValueCreate,
    AXValueGetValue, kAXErrorSuccess, kAXFloatingWindowSubrole, kAXParentAttribute,
    kAXPositionAttribute, kAXRaiseAction, kAXRoleAttribute, kAXSizeAttribute,
    kAXStandardWindowSubrole, kAXToolbarRole, kAXUnknownSubrole, kAXValueTypeCGPoint,
    kAXValueTypeCGSize, kAXWindowRole,
};
use bevy::ecs::component::Component;
use bevy::math::IRect;
use core::ptr::NonNull;
use derive_more::{DerefMut, with_trait::Deref};
use objc2_core_foundation::{
    CFArray, CFBoolean, CFNumber, CFRetained, CFString, CFType, CGPoint, CGRect, CGSize,
    kCFBooleanFalse, kCFBooleanTrue,
};
use std::collections::{HashMap, HashSet};
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex, OnceLock, RwLock};
use std::thread;
use std::time::Duration;
use stdext::function_name;
use stdext::sync::rw_lock::RwLockExt;
use tracing::{Level, debug, instrument, trace, warn};

use super::skylight::{
    _AXUIElementGetWindow, _SLPSSetFrontProcessWithOptions, AXUIElementCopyAttributeValue,
    AXUIElementPerformAction, AXUIElementSetAttributeValue, SLPSPostEventRecordTo,
    SLSWindowIteratorAdvance,
};
use crate::config::Config;
use crate::errors::{Error, Result};
use crate::manager::{Origin, Size, irect_from};
use crate::platform::{Pid, ProcessSerialNumber, WinID, macos_major_version};
use crate::util::{AXUIAttributes, AXUIWrapper, MacResult};

/// Per-PID ref-count for the `AXEnhancedUserInterface` workaround. Tracks how many
/// concurrent window operations are in-flight for each app so the attribute is only
/// re-enabled after the last one completes (safe under `par_iter_mut`).
static ENHANCED_UI_REFCOUNT: LazyLock<Mutex<HashMap<Pid, usize>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Apps observed not to have `AXEnhancedUserInterface` set, so the workaround
/// above can skip them without asking again.
///
/// An `RwLock` rather than a `Mutex`: entries are written once and read by
/// many concurrent `par_iter_mut` workers afterwards, so readers must not
/// exclude each other. Entries die with the process, so a relaunch (new pid)
/// is asked afresh.
static ENHANCED_UI_ABSENT: LazyLock<RwLock<HashSet<Pid>>> =
    LazyLock::new(|| RwLock::new(HashSet::new()));

/// macOS may partially apply an AX width increase when the requested right edge
/// would be far outside the display. Moving the partial result left by the
/// missing width before retrying gives `WindowServer` enough offscreen room.
///
/// Only retry when the first attempt actually grew the window. Fixed-size apps
/// otherwise look identical to this failure mode and must not be moved offscreen.
fn resize_staging_origin(
    previous_frame: IRect,
    actual_frame: IRect,
    target_width: i32,
) -> Option<Origin> {
    let actual_width = actual_frame.width();
    (actual_width > previous_frame.width() && actual_width < target_width).then(|| {
        actual_frame
            .min
            .with_x(actual_frame.min.x - (target_width - actual_width))
    })
}

#[derive(Debug)]
pub enum WindowPadding {
    Vertical(i32),
    Horizontal(i32),
}

#[cfg_attr(test, mockall::automock)]
pub trait WindowApi: Send + Sync {
    fn id(&self) -> WinID;
    fn frame(&self) -> IRect;
    fn element(&self) -> Option<CFRetained<AXUIWrapper>>;
    fn title(&self) -> Result<String>;
    /// Drops the cached title so the next [`Self::title`] reads it afresh.
    /// Called when the app reports the title changed.
    fn invalidate_title(&self);
    fn identifier(&self) -> Result<String>;
    fn child_role(&self) -> Result<bool>;
    /// Whether `point` (screen coordinates) lands on blank header-toolbar
    /// chrome: inside the window's `AXToolbar` ancestry with no interactive
    /// control between the cursor and the toolbar. Used to arm strip
    /// scroll-drag from unified toolbars (`VSCode`, `Firefox`) while keeping
    /// buttons, text fields, tab groups and content fully native. Main
    /// thread only (synchronous cross-process AX reads); any failure
    /// returns `false` so the press stays native.
    fn toolbar_blank_hit(&self, point: &CGPoint) -> bool;
    /// Whether `point` lands on an interactive control (tab group, radio
    /// button, button, text field, ...) anywhere in its AX ancestry. Used
    /// to keep titlebar-band presses on tabs and toolbar controls native:
    /// unified tab strips live inside the titlebar geometry band, so
    /// geometry alone cannot tell a tab from a header grab. Same
    /// main-thread/fail-native contract as [`Self::toolbar_blank_hit`].
    fn interactive_hit(&self, point: &CGPoint) -> bool;
    fn role(&self) -> Result<String>;
    fn subrole(&self) -> Result<String>;
    fn is_minimized(&self) -> bool;
    fn is_full_screen(&self) -> bool;
    fn reposition(&mut self, origin: Origin);
    fn resize(&mut self, size: Size);
    /// Single-shot size write without the staged offscreen retry: one
    /// `kAXSize` write (plus the enhanced-UI pairing) and no reads. The
    /// commit uses this while a resize tween is still driving (intermediate
    /// frames converge at settle, where the full [`WindowApi::resize`]
    /// confirmatory retry still runs); landed resizes keep the full path.
    /// Default body is the full resize, so implementors without a fast
    /// path (mocks) stay correct.
    fn resize_fast(&mut self, size: Size) {
        self.resize(size);
    }
    fn update_frame(&mut self) -> Result<IRect>;
    /// Re-resolves the window's accessibility element from its app, matching
    /// by window id. Sleep invalidates cached element refs (observer
    /// registration then fails with `-25202`), so the wake path calls this
    /// before re-subscribing. The old element is kept when the window is gone
    /// (caller treats that as a failed refresh, not a loss).
    fn refresh_element(&mut self) -> Result<()>;
    fn focus_without_raise(
        &self,
        psn: ProcessSerialNumber,
        currently_focused: &Window,
        focused_psn: ProcessSerialNumber,
    );
    fn focus_with_raise(&self, psn: ProcessSerialNumber);
    /// Raises the window in the OS z-order without changing focus. Used to
    /// shuffle the floating-vs-tiled tier order. Best-effort: AX raise can't
    /// lift a window above another app's frontmost window.
    fn raise_without_focus(&self);
    fn pid(&self) -> Result<Pid>;
    fn set_padding(&mut self, padding: WindowPadding);
    fn horizontal_padding(&self) -> i32;
    fn vertical_padding(&self) -> i32;
    fn border_radius(&self) -> Option<f64>;
}

#[derive(Component, Deref, DerefMut)]
pub struct Window(Box<dyn WindowApi>);

impl Window {
    pub fn new(window: Box<dyn WindowApi>) -> Self {
        Window(window)
    }
}

/// Detected corner radius of a window via the `SkyLight` iterator, if the OS
/// exposes one. Shared by the main-thread [`WindowApi::border_radius`]
/// (memoized per window) and the snapshot worker (slow-tick cached per
/// handle): SLS reads move slower than window attributes and corners only
/// change on theme/scale switches, never per frame.
#[allow(clippy::cast_precision_loss)]
pub(crate) fn sls_window_corner_radius(id: WinID) -> Option<f64> {
    let iterator = super::window_iterator_for_id(id)?;
    if !unsafe { SLSWindowIteratorAdvance(&raw const *iterator) } {
        return None;
    }

    let radii_ref = unsafe {
        // Load the function dynamicaly, because it exists only on macOS 26.x
        let s = c"SLSWindowIteratorGetCornerRadii";
        let p = libc::dlsym(libc::RTLD_DEFAULT, s.as_ptr());
        if p.is_null() {
            return None;
        }
        let f: unsafe extern "C" fn(*const CFType) -> *mut CFArray<CFNumber> =
            std::mem::transmute(p);
        f(&raw const *iterator)
    };
    let radii: CFRetained<CFArray<CFNumber>> =
        unsafe { CFRetained::from_raw(NonNull::new(radii_ref)?) };
    if radii.is_empty() {
        return None;
    }
    // Get first corner radius (usually all corners are the same)
    radii.get(0)?.as_i64().map(|v| v as f64)
}

/// Raw AX position write for the dedicated writer thread: builds the padded
/// point and sets `kAXPosition` on `element` with no cache write, no
/// enhanced-UI dance, and no optimistic frame update. Fire-and-forget, like
/// the write half of [`WindowApi::reposition`]; failures only trace (the
/// confirm path re-reads truth). Callers must route apps needing the
/// enhanced-UI workaround elsewhere — see [`enhanced_ui_workaround_absent`].
pub(crate) fn ax_set_window_position(
    element: &AXUIWrapper,
    origin: Origin,
    h_pad: i32,
    v_pad: i32,
) {
    let mut point = CGPoint::new(f64::from(origin.x + h_pad), f64::from(origin.y + v_pad));
    let position_ref = unsafe {
        AXValueCreate(
            kAXValueTypeCGPoint,
            NonNull::from(&mut point).as_ptr().cast(),
        )
    };
    let Ok(position) = AXUIWrapper::retain(position_ref) else {
        return;
    };
    unsafe {
        AXUIElementSetAttributeValue(
            element.as_ptr(),
            CFString::from_static_str(kAXPositionAttribute).as_ref(),
            position.as_ref(),
        )
    };
}

/// Whether `pid` is known to NOT need the `AXEnhancedUserInterface`
/// workaround (observed absent on an earlier write). The writer thread
/// serves only such apps async; everyone else stays synchronous on the
/// main thread, where the disable→write→reenable pairing lives. The set
/// only grows, so routing converges without ever misrouting a dance app.
pub(crate) fn enhanced_ui_workaround_absent(pid: Pid) -> bool {
    ENHANCED_UI_ABSENT
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .contains(&pid)
}

/// Retrieves the window ID (`WinID`) from an `AXUIElementRef`.
///
/// # Arguments
///
/// * `element_ref` - The `AXUIElementRef` to extract the window ID from.
///
/// # Returns
///
/// `Ok(WinID)` with the window ID if successful, otherwise `Err(Error)`.
pub fn ax_window_id(element_ref: AXUIElementRef) -> Result<WinID> {
    try_ax_window_id(element_ref).ok_or_else(|| {
        Error::InvalidInput(format!(
            "{}: Unable to get window id from element {element_ref:?}.",
            function_name!()
        ))
    })
}

/// Allocation-free variant of [`ax_window_id`].
///
/// [`crate::manager::bruteforce_windows`] calls this tens of thousands of times in
/// a row and discards nearly every result, so the error path must not format a
/// message it will only drop.
pub fn try_ax_window_id(element_ref: AXUIElementRef) -> Option<WinID> {
    let ptr = NonNull::new(element_ref)?;
    let mut window_id: WinID = 0;
    if unsafe { _AXUIElementGetWindow(ptr.as_ptr(), &mut window_id) } != 0 || window_id == 0 {
        return None;
    }
    Some(window_id)
}

/// Reads the owning pid straight off a raw accessibility element, without a
/// constructed [`WindowOS`]. Shared by [`WindowApi::pid`] and the live
/// window-creation path, which must resolve the owning app (for bundle
/// scoped `manage=true` rules) before role validation can run.
pub fn pid_of_element(element: &CFRetained<AXUIWrapper>) -> Result<Pid> {
    let pid: Pid = unsafe {
        NonNull::new_unchecked(element.as_ptr::<Pid>())
            .byte_add(0x10)
            .read()
    };
    (pid != 0).then_some(pid).ok_or(Error::InvalidInput(format!(
        "can not get pid from {element:?}.",
    )))
}

// const CPS_ALL_WINDOWS: u32 = 0x100;
const CPS_USER_GENERATED: u32 = 0x200;
// const CPS_NO_WINDOWS: u32 = 0x400;

#[derive(Debug)]
pub struct WindowOS {
    id: WinID,
    ax_element: CFRetained<AXUIWrapper>,
    frame: IRect,
    vertical_padding: i32,
    horizontal_padding: i32,
    border_radius: OnceLock<Option<f64>>,
    pid: OnceLock<Result<Pid>>,
    app_reference: OnceLock<Option<CFRetained<AXUIWrapper>>>,
    /// Set once this window's app is known not to use
    /// `AXEnhancedUserInterface` (the common case), so the steady-state check
    /// in [`Self::disable_enhanced_ui`] is a relaxed atomic load instead of
    /// contending for the global mutex from every `par_iter_mut` worker.
    enhanced_ui_absent: AtomicBool,

    /// The last title read off the element, cached because reading one is a
    /// synchronous cross-process call and many callers want it for every
    /// window at once.
    ///
    /// An `RwLock` rather than a `OnceLock` like its neighbours: a title can
    /// change, and [`Self::invalidate_title`] clears it when the app reports
    /// `kAXTitleChangedNotification`. Missing that notification is the one
    /// way this can go stale.
    title: RwLock<Option<String>>,
}

impl WindowOS {
    /// Shared AX ancestry walk backing [`WindowApi::toolbar_blank_hit`]
    /// and [`WindowApi::interactive_hit`]: deepest element at `point`, up
    /// to 8 `AXParent` levels. Any failure reads as [`AncestryHit::Other`]
    /// (press stays native). Inherent rather than a trait method so the
    /// [`mockall`] mock need not stub it — the two trait methods delegate
    /// to it, and tests stub those directly.
    #[allow(clippy::cast_possible_truncation)]
    fn ancestry_hit(&self, point: &CGPoint) -> AncestryHit {
        const MAX_DEPTH: usize = 8;
        // Roles that own the press: dragging from them must stay native
        // (text selection, tab drags, button presses, URL edits, ...),
        // even when they sit inside the toolbar rect.
        const INTERACTIVE_ROLES: &[&str] = &[
            "AXButton",
            "AXRadioButton",
            "AXCheckBox",
            "AXPopUpButton",
            "AXMenuButton",
            "AXTabGroup",
            "AXTextField",
            "AXTextArea",
            "AXComboBox",
            "AXSlider",
            "AXIncrementor",
            "AXScrollArea",
            "AXScrollBar",
            "AXSplitter",
            "AXTable",
            "AXOutline",
            "AXBrowser",
            "AXList",
            "AXGrid",
            "AXMenu",
            "AXMenuItem",
            "AXMenuBarItem",
            "AXLink",
            "AXWebArea",
        ];
        const WINDOW_ROLES: &[&str] = &["AXWindow", "AXSheet", "AXDrawer"];

        let Some(app_element) = self.app_reference() else {
            return AncestryHit::Other;
        };
        let mut hit: AXUIElementRef = std::ptr::null_mut();
        let status = unsafe {
            AXUIElementCopyElementAtPosition(
                app_element.as_ptr(),
                point.x as f32,
                point.y as f32,
                &raw mut hit,
            )
        };
        if status != kAXErrorSuccess {
            return AncestryHit::Other;
        }
        let Ok(mut current) = AXUIWrapper::from_retained(hit.cast::<std::ffi::c_void>()) else {
            return AncestryHit::Other;
        };
        let role_name = CFString::from_static_str(kAXRoleAttribute);
        let parent_name = CFString::from_static_str(kAXParentAttribute);
        for _ in 0..MAX_DEPTH {
            let Ok(role) = current
                .get_attribute::<CFString>(&role_name)
                .map(|value| value.to_string())
            else {
                return AncestryHit::Other;
            };
            if INTERACTIVE_ROLES.iter().any(|item| item.eq(&role)) {
                return AncestryHit::Interactive;
            }
            if role.eq(kAXToolbarRole) {
                return AncestryHit::ToolbarBlank;
            }
            if WINDOW_ROLES.iter().any(|item| item.eq(&role)) {
                return AncestryHit::Other;
            }
            let Ok(parent) = current.get_attribute::<AXUIWrapper>(&parent_name) else {
                return AncestryHit::Other;
            };
            current = parent;
        }
        AncestryHit::Other
    }

    /// Creates a new `Window` instance.
    ///
    /// # Arguments
    ///
    /// * `element` - A `CFRetained<AXUIWrapper>` reference to the Accessibility UI element.
    /// * `config` - The current Paneru configuration, used to evaluate window rules.
    /// * `bundle_id` - The bundle identifier of the owning application, if known.
    ///
    /// # Returns
    ///
    /// `Ok(Window)` if the window is created successfully, otherwise `Err(Error)`.
    #[instrument(level = Level::TRACE, ret)]
    pub fn new_with_config(
        element: &CFRetained<AXUIWrapper>,
        config: &Config,
        bundle_id: Option<&str>,
    ) -> Result<Self> {
        let id = ax_window_id(element.as_ptr())?;
        let window = Self {
            id,
            ax_element: element.clone(),
            frame: IRect::default(),
            vertical_padding: 0,
            horizontal_padding: 0,
            border_radius: OnceLock::new(),
            pid: OnceLock::new(),
            app_reference: OnceLock::new(),
            enhanced_ui_absent: AtomicBool::new(false),
            title: RwLock::new(None),
        };

        let forced = window.is_forced_manage(config, bundle_id);

        if window.is_unknown() && !forced {
            return Err(Error::invalid_window(&format!(
                "Ignoring AXUnknown window, id: {}, role {}, subrole {}",
                window.id(),
                window.role().unwrap_or_default(),
                window.subrole().unwrap_or_default(),
            )));
        }

        if !window.is_real() && !forced {
            return Err(Error::invalid_window(&format!(
                "Ignoring non-real window, id: {}, role {}, subrole {}",
                window.id(),
                window.role().unwrap_or_default(),
                window.subrole().unwrap_or_default(),
            )));
        }

        trace!(
            "created {} title: {} role: {} subrole: {}",
            window.id(),
            window.title().unwrap_or_default(),
            window.role().unwrap_or_default(),
            window.subrole().unwrap_or_default(),
        );
        Ok(window)
    }

    /// Checks whether a configured window rule forces this window to be managed
    /// despite having a non-standard role/subrole.
    fn is_forced_manage(&self, config: &Config, bundle_id: Option<&str>) -> bool {
        let Ok(title) = self.title() else {
            return false;
        };
        config
            .find_window_properties(&title, bundle_id.unwrap_or_default())
            .iter()
            .any(|params| params.manage.is_some_and(|manage| manage))
    }

    /// Checks if the window's subrole is "`AXUnknownSubrole`".
    ///
    /// # Returns
    ///
    /// `true` if the subrole is unknown, `false` otherwise.
    fn is_unknown(&self) -> bool {
        self.subrole()
            .is_ok_and(|subrole| subrole.eq(kAXUnknownSubrole))
    }

    /// Checks if the window is a "real" window based on its role and subrole.
    /// It considers standard and floating window subroles as real.
    ///
    /// # Returns
    ///
    /// `true` if the window is real, `false` otherwise.
    fn is_real(&self) -> bool {
        let role = self.role().ok();
        let subrole = self.subrole().ok();

        subrole.as_deref() == Some(kAXStandardWindowSubrole)
            || (role.as_deref() == Some(kAXWindowRole)
                && subrole.as_deref() == Some(kAXFloatingWindowSubrole))
    }

    fn app_reference(&self) -> Option<CFRetained<AXUIWrapper>> {
        self.app_reference
            .get_or_init(|| {
                self.pid()
                    .map(|pid| unsafe { AXUIElementCreateApplication(pid) })
                    .and_then(AXUIWrapper::from_retained)
                    .inspect_err(|err| warn!("error getting app reference: {err}"))
                    .ok()
            })
            .clone()
    }

    /// Disables `AXEnhancedUserInterface` on this window's app if it is currently enabled.
    ///
    /// Uses a per-PID ref-count so that concurrent operations on windows of the same app
    /// (via `par_iter_mut`) keep the attribute disabled until the last caller re-enables it.
    ///
    /// This avoids animated move/resize that breaks window management for apps like Chrome,
    /// Firefox, and Zen Browser when accessibility clients (e.g. Kindavim) enable enhanced UI.
    fn disable_enhanced_ui(&self) {
        // Nothing to disable, and nothing to lock or ask: this window's app has
        // already been found not to use the attribute.
        if self.enhanced_ui_absent.load(Ordering::Relaxed) {
            return;
        }
        let Ok(pid) = self.pid() else { return };
        // Another window of the same app may have answered the question already.
        // Taken before the ref-count mutex, since the answer is usually "absent"
        // and that path should not touch the ref-count at all.
        if ENHANCED_UI_ABSENT
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(&pid)
        {
            self.enhanced_ui_absent.store(true, Ordering::Relaxed);
            return;
        }
        // Scoped so the lock isn't held across the accessibility calls below:
        // each is a synchronous round-trip into another process, and holding a
        // global mutex across them would serialize every `par_iter_mut` worker
        // behind the slowest app.
        {
            let mut counts = ENHANCED_UI_REFCOUNT
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(count) = counts.get_mut(&pid) {
                *count += 1;
                return;
            }
        }
        let Some(app_element) = self.app_reference() else {
            return;
        };
        let attr = CFString::from_static_str("AXEnhancedUserInterface");
        let enabled = app_element
            .get_attribute::<CFBoolean>(&attr)
            .is_ok_and(|v| CFBoolean::value(&v));
        if enabled {
            unsafe {
                AXUIElementSetAttributeValue(
                    app_element.as_ptr(),
                    attr.as_ref(),
                    kCFBooleanFalse.unwrap(),
                );
            }
            // Incremented rather than set: two windows of the same app can race
            // here and both owe a matching `reenable_enhanced_ui`; setting 1
            // would let the second one decrement past zero.
            *ENHANCED_UI_REFCOUNT
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .entry(pid)
                .or_insert(0) += 1;
        } else {
            ENHANCED_UI_ABSENT
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(pid);
            self.enhanced_ui_absent.store(true, Ordering::Relaxed);
        }
    }

    /// Re-enables `AXEnhancedUserInterface` on this window's app once the last concurrent
    /// caller has finished. Pairs with [`disable_enhanced_ui`].
    fn reenable_enhanced_ui(&self) {
        // Nothing was disabled, so there is no ref-count entry to find and no
        // reason to take the lock looking for one.
        if self.enhanced_ui_absent.load(Ordering::Relaxed) {
            return;
        }
        let Ok(pid) = self.pid() else { return };
        let mut counts = ENHANCED_UI_REFCOUNT
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(count) = counts.get_mut(&pid) else {
            return;
        };
        *count = count.saturating_sub(1);
        if *count > 0 {
            return;
        }
        counts.remove(&pid);
        drop(counts);
        if let Some(app_element) = self.app_reference() {
            let attr = CFString::from_static_str("AXEnhancedUserInterface");
            unsafe {
                AXUIElementSetAttributeValue(
                    app_element.as_ptr(),
                    attr.as_ref(),
                    kCFBooleanTrue.unwrap(),
                );
            }
        }
    }

    fn set_ax_position(&mut self, origin: Origin) {
        let mut point = CGPoint::new(
            f64::from(origin.x + self.horizontal_padding),
            f64::from(origin.y + self.vertical_padding),
        );
        let position_ref = unsafe {
            AXValueCreate(
                kAXValueTypeCGPoint,
                NonNull::from(&mut point).as_ptr().cast(),
            )
        };
        if let Ok(position) = AXUIWrapper::retain(position_ref) {
            unsafe {
                AXUIElementSetAttributeValue(
                    self.ax_element.as_ptr(),
                    CFString::from_static_str(kAXPositionAttribute).as_ref(),
                    position.as_ref(),
                )
            };
            let size = self.frame.size();
            self.frame.min = origin;
            self.frame.max = origin + size;
        }
    }

    fn set_ax_size(&mut self, size: Size) {
        let width_padding = 2 * self.horizontal_padding;
        let height_padding = 2 * self.vertical_padding;
        let mut cgsize = CGSize::new(
            f64::from(size.x - width_padding),
            f64::from(size.y - height_padding),
        );
        let size_ref = unsafe {
            AXValueCreate(
                kAXValueTypeCGSize,
                NonNull::from(&mut cgsize).as_ptr().cast(),
            )
        };
        if let Ok(size_value) = AXUIWrapper::retain(size_ref) {
            unsafe {
                AXUIElementSetAttributeValue(
                    self.ax_element.as_ptr(),
                    CFString::from_static_str(kAXSizeAttribute).as_ref(),
                    size_value.as_ref(),
                )
            };
            self.frame.max = self.frame.min + size;
        }
    }

    /// Makes the window the key window for its application by sending synthesized events.
    ///
    /// # Arguments
    ///
    /// * `psn` - The process serial number of the application.
    fn make_key_window(&self, psn: &ProcessSerialNumber) {
        // Reason: On macOS 14 (Sonoma), CGSEncodeEventRecord serializes the raw event
        // buffer via NSKeyedArchiver, misinterpreting 0xFF fill as an ObjC class pointer,
        // causing SIGABRT. See https://github.com/karinushka/paneru/issues/123
        if macos_major_version() == 14 {
            debug!("make_key_window: skipped on macOS 14 (Sonoma) to prevent crash");
            return;
        }
        let window_id = self.id();
        let mut event_bytes = [0u8; 0xf8];
        event_bytes[0x04] = 0xf8;
        event_bytes[0x3a] = 0x10;
        event_bytes[0x3c..0x40].copy_from_slice(&window_id.to_ne_bytes());
        event_bytes[0x20..0x30].fill(0xff);

        event_bytes[0x08] = 0x01;
        unsafe { SLPSPostEventRecordTo(psn, event_bytes.as_ptr().cast()) };

        event_bytes[0x08] = 0x02;
        unsafe { SLPSPostEventRecordTo(psn, event_bytes.as_ptr().cast()) };
    }
}

/// Reads an AX element's position+size into a raw (unpadded) frame.
/// Same decode as [`WindowApi::update_frame`], but free of `&mut` and of any
/// cache write, so the snapshot thread can call it on its own cloned
/// handles. Consumers apply padding themselves from the live `Window`.
pub(crate) fn snapshot_frame(element: &AXUIWrapper) -> Result<IRect> {
    let window_ref = element.as_ptr();

    let position = unsafe {
        let mut position_ref: *mut CFType = null_mut();
        AXUIElementCopyAttributeValue(
            window_ref,
            CFString::from_static_str(kAXPositionAttribute).as_ref(),
            &mut position_ref,
        )
        .to_result(function_name!())?;
        AXUIWrapper::retain(position_ref)?
    };
    let size = unsafe {
        let mut size_ref: *mut CFType = null_mut();
        AXUIElementCopyAttributeValue(
            window_ref,
            CFString::from_static_str(kAXSizeAttribute).as_ref(),
            &mut size_ref,
        )
        .to_result(function_name!())?;
        AXUIWrapper::retain(size_ref)?
    };

    let mut frame = CGRect::default();
    unsafe {
        AXValueGetValue(
            position.as_ptr(),
            kAXValueTypeCGPoint,
            NonNull::from(&mut frame.origin).as_ptr().cast(),
        );
        AXValueGetValue(
            size.as_ptr(),
            kAXValueTypeCGSize,
            NonNull::from(&mut frame.size).as_ptr().cast(),
        );
    }
    Ok(irect_from(frame))
}

/// Outcome of one AX ancestry walk: what owns the press.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AncestryHit {
    /// An interactive control (tab, button, field) in the chain: native.
    Interactive,
    /// Blank toolbar chrome, nothing interactive: draggable header.
    ToolbarBlank,
    /// Anything else (content, failure, depth cap): native.
    Other,
}

impl WindowApi for WindowOS {
    /// Returns the ID of the window.
    ///
    /// # Returns
    ///
    /// The window ID as `WinID`.
    fn id(&self) -> WinID {
        self.id
    }

    /// Returns the current frame (`CGRect`) of the window.
    ///
    /// # Returns
    ///
    /// The window's frame as `CGRect`.
    fn frame(&self) -> IRect {
        self.frame
    }

    /// Returns the accessibility element of the window.
    ///
    /// # Returns
    ///
    /// A `CFRetained<AXUIWrapper>` representing the accessibility element.
    fn element(&self) -> Option<CFRetained<AXUIWrapper>> {
        Some(self.ax_element.clone())
    }

    fn refresh_element(&mut self) -> Result<()> {
        let Some(app_element) = self.app_reference() else {
            return Err(Error::InvalidWindow);
        };
        let id = self.id;
        let fresh = app_element
            .windows()
            .map_err(|err| Error::InvalidInput(format!("{err}")))?
            .into_iter()
            .find(|element| try_ax_window_id(element.as_ptr()) == Some(id))
            .ok_or(Error::InvalidWindow)?;
        self.ax_element = fresh;
        Ok(())
    }

    /// Retrieves the title of the window.
    ///
    /// # Returns
    ///
    /// `Ok(String)` with the window title if successful, otherwise `Err(Error)`.
    fn title(&self) -> Result<String> {
        if let Some(cached) = self.title.force_read().clone() {
            return Ok(cached);
        }
        let title = self.ax_element.title()?;
        *self.title.force_write() = Some(title.clone());
        Ok(title)
    }

    fn invalidate_title(&self) {
        self.title.force_write().take();
    }

    fn identifier(&self) -> Result<String> {
        self.ax_element.identifier()
    }

    /// Returns true if the window has a child role.
    fn child_role(&self) -> Result<bool> {
        let role = self.role()?;
        Ok(["AXSheet", "AXDrawer"]
            .iter()
            .any(|axrole| axrole.eq(&role)))
    }

    /// Hit-tests `point` against the window's toolbar ancestry.
    ///
    /// Resolves the deepest AX element at the cursor and walks
    /// `AXParent` up to the window (bounded: 8 levels). An interactive
    /// role anywhere in the chain (button, text field, tab group, web
    /// area, ...) means user intent belongs to the app → `false`. A
    /// toolbar ancestor with nothing interactive below it means blank
    /// draggable chrome → `true`. Reaching the window with no toolbar
    /// ancestor (plain content, Electron custom chrome without an
    /// `AXToolbar`) → `false`: classification must never arm scroll
    /// from inside content.
    #[allow(clippy::cast_possible_truncation)]
    fn toolbar_blank_hit(&self, point: &CGPoint) -> bool {
        self.ancestry_hit(point) == AncestryHit::ToolbarBlank
    }

    /// See [`Self::interactive_hit`]: same walk, answering the interactive
    /// question instead of the blank-chrome one.
    fn interactive_hit(&self, point: &CGPoint) -> bool {
        self.ancestry_hit(point) == AncestryHit::Interactive
    }

    /// Retrieves the role of the window (e.g., "`AXWindow`").
    ///
    /// # Returns
    ///
    /// `Ok(String)` with the window role if successful, otherwise `Err(Error)`.
    fn role(&self) -> Result<String> {
        self.ax_element.role()
    }

    /// Retrieves the subrole of the window (e.g., "`AXStandardWindow`").
    ///
    /// # Returns
    ///
    /// `Ok(String)` with the window subrole if successful, otherwise `Err(Error)`.
    fn subrole(&self) -> Result<String> {
        self.ax_element.subrole()
    }

    #[instrument(level = Level::DEBUG, ret)]
    fn is_minimized(&self) -> bool {
        self.ax_element.minimized().is_ok_and(|minimized| minimized)
    }

    fn is_full_screen(&self) -> bool {
        self.ax_element.full_screen().unwrap_or(false)
    }

    #[instrument(level = Level::TRACE)]
    fn reposition(&mut self, origin: Origin) {
        // 1px tolerance, matching the verifier/audit/drop-home rules: the
        // animator rounds to integers and can dither across a boundary near
        // landing, which exact equality would commit as AX traffic every
        // frame for zero visible motion.
        let drift = (self.frame.min - origin).abs();
        if drift.x <= 1 && drift.y <= 1 {
            trace!("already in position.");
            return;
        }
        self.disable_enhanced_ui();
        self.set_ax_position(origin);
        self.reenable_enhanced_ui();
    }

    #[instrument(level = Level::TRACE)]
    fn resize_fast(&mut self, size: Size) {
        // Fast path for driven (still-tweening) resizes: a single size
        // write, no confirmatory reads, no offscreen staging. Partially
        // constrained apps may show a clamped intermediate frame, but the
        // tween lands exactly and the settled commit runs the full staged
        // retry — convergence is owned there, not here.
        let drift = (self.frame.size() - size).abs();
        if drift.x <= 1 && drift.y <= 1 {
            trace!("already correct size.");
            return;
        }
        self.disable_enhanced_ui();
        self.set_ax_size(size);
        self.reenable_enhanced_ui();
    }

    #[instrument(level = Level::TRACE)]
    fn resize(&mut self, size: Size) {
        // 1px tolerance like `reposition` and the verifier: OS rounding must
        // converge, not dither AX traffic across an integer boundary.
        let drift = (self.frame.size() - size).abs();
        if drift.x <= 1 && drift.y <= 1 {
            trace!("already correct size.");
            return;
        }
        let previous_frame = self.frame;
        let target_origin = previous_frame.min;
        self.disable_enhanced_ui();
        self.set_ax_size(size);

        let mut previous_observed_frame = previous_frame;
        let mut staged = false;
        for attempt in 1..=3 {
            let Ok(actual_frame) = self.update_frame() else {
                break;
            };
            let Some(staging_origin) =
                resize_staging_origin(previous_observed_frame, actual_frame, size.x)
            else {
                break;
            };
            debug!(
                attempt,
                requested_width = size.x,
                actual_width = actual_frame.width(),
                staging_x = staging_origin.x,
                "retrying partially constrained AX resize from an offscreen origin"
            );
            staged = true;
            previous_observed_frame = actual_frame;
            self.set_ax_position(staging_origin);
            self.set_ax_size(size);
        }

        if staged {
            if let Ok(final_frame) = self.update_frame() {
                debug!(
                    requested_width = size.x,
                    actual_width = final_frame.width(),
                    "completed staged AX resize"
                );
            }
            self.set_ax_position(target_origin);
        }
        self.reenable_enhanced_ui();
    }

    /// Updates the internal `frame` of the window by querying its current position and size from the Accessibility API.
    /// It also updates the `width_ratio`.
    ///
    /// # Arguments
    ///
    /// * `display_bounds` - An optional `CGRect` representing the bounds of the display the window is on.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the frame is updated successfully, otherwise `Err(Error)`.
    fn update_frame(&mut self) -> Result<IRect> {
        let window_ref = self.ax_element.as_ptr();

        let position = unsafe {
            let mut position_ref: *mut CFType = null_mut();
            AXUIElementCopyAttributeValue(
                window_ref,
                CFString::from_static_str(kAXPositionAttribute).as_ref(),
                &mut position_ref,
            )
            .to_result(function_name!())?;
            AXUIWrapper::retain(position_ref)?
        };
        let size = unsafe {
            let mut size_ref: *mut CFType = null_mut();
            AXUIElementCopyAttributeValue(
                window_ref,
                CFString::from_static_str(kAXSizeAttribute).as_ref(),
                &mut size_ref,
            )
            .to_result(function_name!())?;
            AXUIWrapper::retain(size_ref)?
        };

        let mut frame = CGRect::default();
        unsafe {
            AXValueGetValue(
                position.as_ptr(),
                kAXValueTypeCGPoint,
                NonNull::from(&mut frame.origin).as_ptr().cast(),
            );
            AXValueGetValue(
                size.as_ptr(),
                kAXValueTypeCGSize,
                NonNull::from(&mut frame.size).as_ptr().cast(),
            );
        }
        // if (CGRectEqualToRect(new_frame, window->frame)) {
        //     debug("%s:DEBOUNCED %s %d\n", __FUNCTION__, window->application->name, window->id);
        // }
        self.frame = irect_from(frame);

        self.frame.min.x -= self.horizontal_padding;
        self.frame.min.y -= self.vertical_padding;
        self.frame.max.x += self.horizontal_padding;
        self.frame.max.y += self.vertical_padding;

        Ok(self.frame)
    }

    /// Focuses the window without raising it. This involves sending specific events to the process.
    ///
    /// # Arguments
    ///
    /// * `currently_focused` - A reference to the currently focused window.
    #[instrument(level = Level::DEBUG, skip(currently_focused))]
    fn focus_without_raise(
        &self,
        psn: ProcessSerialNumber,
        currently_focused: &Window,
        focused_psn: ProcessSerialNumber,
    ) {
        let window_id = self.id();
        debug!("{window_id}");
        if focused_psn == psn {
            let mut event_bytes = [0u8; 0xf8];
            event_bytes[0x04] = 0xf8;
            event_bytes[0x08] = 0x0d;

            event_bytes[0x8a] = 0x02;
            event_bytes[0x3c..0x40].copy_from_slice(&currently_focused.id().to_ne_bytes());
            unsafe {
                SLPSPostEventRecordTo(&focused_psn, event_bytes.as_ptr().cast());
            }

            // Artificially delay the activation. This is necessary because some
            // applications appear to be confused if both of the events appear instantaneously.
            thread::sleep(Duration::from_millis(20));

            event_bytes[0x8a] = 0x01;
            event_bytes[0x3c..0x40].copy_from_slice(&window_id.to_ne_bytes());
            unsafe {
                SLPSPostEventRecordTo(&psn, event_bytes.as_ptr().cast());
            }
        }

        unsafe {
            _SLPSSetFrontProcessWithOptions(&psn, window_id, CPS_USER_GENERATED);
        }
        self.make_key_window(&psn);
    }

    /// Focuses the window and raises it to the front.
    #[instrument(level = Level::DEBUG)]
    fn focus_with_raise(&self, psn: ProcessSerialNumber) {
        let window_id = self.id();
        unsafe {
            _SLPSSetFrontProcessWithOptions(&psn, window_id, CPS_USER_GENERATED);
        }
        self.make_key_window(&psn);
        let element_ref = self.ax_element.as_ptr();
        let action = CFString::from_static_str(kAXRaiseAction);
        unsafe { AXUIElementPerformAction(element_ref, &action) };
    }

    #[instrument(level = Level::DEBUG)]
    fn raise_without_focus(&self) {
        let element_ref = self.ax_element.as_ptr();
        let action = CFString::from_static_str(kAXRaiseAction);
        unsafe { AXUIElementPerformAction(element_ref, &action) };
    }

    fn pid(&self) -> Result<Pid> {
        self.pid
            .get_or_init(|| pid_of_element(&self.ax_element))
            .clone()
    }

    fn set_padding(&mut self, padding: WindowPadding) {
        match padding {
            WindowPadding::Vertical(padding) => self.vertical_padding = padding,
            WindowPadding::Horizontal(padding) => self.horizontal_padding = padding,
        }
    }

    fn horizontal_padding(&self) -> i32 {
        self.horizontal_padding
    }

    fn vertical_padding(&self) -> i32 {
        self.vertical_padding
    }

    // Based on:
    // - https://github.com/y3owk1n/rift/blob/cca067145f0282b532e848bb63d26a38c61f3c14/src/sys/window_server.rs#L175
    // - https://github.com/FelixKratz/JankyBorders/blob/a56a76a8a6ed77325f03655b23fcf525144d120b/src/windows.c#L67
    fn border_radius(&self) -> Option<f64> {
        *self
            .border_radius
            .get_or_init(|| sls_window_corner_radius(self.id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_partially_applied_width_growth() {
        let previous = IRect::new(-400, 40, 400, 640);
        let actual = IRect::new(-400, 40, 2416, 640);

        assert_eq!(
            resize_staging_origin(previous, actual, 4112),
            Some(Origin::new(-1696, 40))
        );

        let nearly_complete = IRect::new(-2056, 40, 2016, 640);
        assert_eq!(
            resize_staging_origin(actual, nearly_complete, 4112),
            Some(Origin::new(-2096, 40))
        );
    }

    #[test]
    fn does_not_stage_fixed_size_or_completed_resizes() {
        let fixed = IRect::new(0, 40, 230, 448);
        assert_eq!(resize_staging_origin(fixed, fixed, 4112), None);

        let previous = IRect::new(0, 40, 800, 640);
        let completed = IRect::new(0, 40, 4112, 640);
        assert_eq!(resize_staging_origin(previous, completed, 4112), None);
    }
}
