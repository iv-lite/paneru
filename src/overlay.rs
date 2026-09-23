use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{
    NSBackingStoreType, NSBezierPath, NSColor, NSCompositingOperation, NSFloatingWindowLevel,
    NSFont, NSGraphicsContext, NSParagraphStyle, NSScreen, NSView, NSWindow,
    NSWindowCollectionBehavior, NSWindowStyleMask,
};
use objc2_core_foundation::CGFloat;
use objc2_foundation::{
    NSAttributedString, NSDictionary, NSMutableCopying, NSPoint, NSRect, NSSize, NSString,
};
use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::platform::WinID;

#[derive(Clone, PartialEq)]
pub struct BorderParams {
    pub color: (f64, f64, f64),
    pub opacity: f64,
    pub width: f64,
    pub radius: f64,
}

/// Parameters for the fullscreen dim overlay. The border lives in its own
/// layer-backed window (`update_focused_border`), never in this surface.
#[derive(Clone, PartialEq)]
pub struct DimParams {
    pub opacity: f32,
    pub color: (f64, f64, f64),
    /// The focused window rect to cut out (in Cocoa screen coordinates).
    /// `None` means dim everything (no focused window).
    pub cutout: Option<NSRect>,
    /// Corner radius of the cutout hole (the window's own radius).
    pub cutout_radius: f64,
}

// ── DimView: fullscreen dark overlay with a transparent cutout + border ──

#[derive(Debug, Clone)]
struct DimViewIvars {
    opacity: f32,
    dim_r: f64,
    dim_g: f64,
    dim_b: f64,
    // Cutout rect in the view's local coordinates.
    cutout_x: f64,
    cutout_y: f64,
    cutout_w: f64,
    cutout_h: f64,
    has_cutout: bool,
    // Corner radius of the cutout hole (the window's own radius).
    cutout_radius: f64,
}

define_class!(
    #[unsafe(super(NSView))]
    #[thread_kind = MainThreadOnly]
    #[name = "PaneruDimView"]
    #[ivars = DimViewIvars]
    #[derive(Debug)]
    struct DimView;

    impl DimView {
        #[unsafe(method(drawRect:))]
        fn draw_rect(&self, _dirty_rect: NSRect) {
            let ivars = self.ivars();
            let bounds = self.bounds();

            // Fill the entire view with the dim color.
            let dim_color = NSColor::colorWithSRGBRed_green_blue_alpha(
                ivars.dim_r as CGFloat,
                ivars.dim_g as CGFloat,
                ivars.dim_b as CGFloat,
                CGFloat::from(ivars.opacity),
            );
            dim_color.setFill();
            NSBezierPath::fillRect(bounds);

            if ivars.has_cutout {
                // Punch a transparent hole using Clear compositing. Kept
                // rounded to the window's corner radius so no dim bleeds in
                // at the corners.
                if let Some(ctx) = NSGraphicsContext::currentContext() {
                    ctx.setCompositingOperation(NSCompositingOperation::Clear);
                    let hole = NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(
                        NSRect::new(
                            NSPoint::new(ivars.cutout_x, ivars.cutout_y),
                            NSSize::new(ivars.cutout_w, ivars.cutout_h),
                        ),
                        ivars.cutout_radius as CGFloat,
                        ivars.cutout_radius as CGFloat,
                    );
                    hole.fill();
                    ctx.setCompositingOperation(NSCompositingOperation::SourceOver);
                }
            }
        }

        #[unsafe(method(isFlipped))]
        fn is_flipped(&self) -> bool {
            true
        }
    }
);

impl DimView {
    fn new(mtm: MainThreadMarker, frame: NSRect, params: &DimParams) -> Retained<Self> {
        let (has_cutout, cx, cy, cw, ch) = params.cutout.map_or((false, 0.0, 0.0, 0.0, 0.0), |r| {
            (true, r.origin.x, r.origin.y, r.size.width, r.size.height)
        });
        let this = Self::alloc(mtm).set_ivars(DimViewIvars {
            opacity: params.opacity,
            dim_r: params.color.0,
            dim_g: params.color.1,
            dim_b: params.color.2,
            cutout_x: cx,
            cutout_y: cy,
            cutout_w: cw,
            cutout_h: ch,
            has_cutout,
            cutout_radius: params.cutout_radius,
        });
        unsafe { msg_send![super(this), initWithFrame: frame] }
    }
}

// ── Coordinate helpers ──────────────────────────────────────────────────

/// Convert an absolute CG screen frame (origin top-left, y-down) to Cocoa
/// screen coordinates (origin bottom-left of primary screen, y-up).
fn cg_abs_to_cocoa(frame: NSRect, primary_screen_height: f64) -> NSRect {
    let cocoa_y = primary_screen_height - frame.origin.y - frame.size.height;
    NSRect::new(NSPoint::new(frame.origin.x, cocoa_y), frame.size)
}

/// Height of the display at the global origin (the main display, whose Cocoa
/// frame origin is `(0, 0)`). The CG↔Cocoa Y-flip is anchored to this display,
/// so it must be *that* screen — `NSScreen::screens()[0]` is NOT reliably the
/// main display, and using the wrong one offsets the overlay (and, when
/// displays are stacked, lands it on the wrong monitor).
fn primary_screen_height(mtm: MainThreadMarker) -> f64 {
    let screens = NSScreen::screens(mtm);
    let mut fallback = 0.0;
    let mut first = true;
    for screen in &screens {
        let frame = screen.frame();
        if first {
            fallback = frame.size.height;
            first = false;
        }
        if frame.origin.x == 0.0 && frame.origin.y == 0.0 {
            return frame.size.height;
        }
    }
    fallback
}

/// Do two Cocoa rects overlap? Used to decide which displays a focused window
/// touches (a window straddling a seam touches both).
fn rects_intersect(a: NSRect, b: NSRect) -> bool {
    a.origin.x < b.origin.x + b.size.width
        && b.origin.x < a.origin.x + a.size.width
        && a.origin.y < b.origin.y + b.size.height
        && b.origin.y < a.origin.y + a.size.height
}

/// Geometry of a border-only window: the app window rect inflated outward by
/// half the border width. A `CALayer` border draws centered on the layer
/// edge with its outer half unclipped, so inflating by half the width lands
/// the visible stroke exactly at `[edge, edge+width]` — flush with the glass
/// on all sides (inflating by the full width leaves a `width/2` hairline
/// gap), without covering app pixels the way the old centered `drawRect`
/// stroke did. Pure math: unit-tested, no `AppKit` involved.
pub(crate) fn border_window_rect(window: NSRect, width: f64) -> NSRect {
    let half = width / 2.0;
    NSRect::new(
        NSPoint::new(window.origin.x - half, window.origin.y - half),
        NSSize::new(window.size.width + width, window.size.height + width),
    )
}

/// Applies border styling to a (layer-backed) window's content view. Layer
/// properties are GPU-composited: changing them never repaints, and moving
/// the window never touches them — unlike the old fullscreen `drawRect`.
fn apply_border_layer(window: &NSWindow, params: &BorderParams) {
    let Some(view) = window.contentView() else {
        return;
    };
    view.setWantsLayer(true);
    let Some(layer) = view.layer() else {
        return;
    };
    let color = NSColor::colorWithSRGBRed_green_blue_alpha(
        params.color.0 as CGFloat,
        params.color.1 as CGFloat,
        params.color.2 as CGFloat,
        params.opacity as CGFloat,
    );
    layer.setBackgroundColor(Some(NSColor::clearColor().CGColor().as_ref()));
    layer.setBorderWidth(params.width as CGFloat);
    layer.setBorderColor(Some(color.CGColor().as_ref()));
    // Outer corner stays concentric with the window's rounded corner at half
    // the stroke out from the glass.
    layer.setCornerRadius((params.radius + params.width / 2.0) as CGFloat);
}

/// Fill alpha of the drop-preview ghost. The border stroke uses full
/// `BorderParams` opacity; the fill stays translucent so whatever is behind
/// the future slot shows through.
const DROP_PREVIEW_FILL_ALPHA: f64 = 0.25;

/// Applies drop-preview styling to a (layer-backed) window's content view:
/// translucent fill plus border stroke, all GPU-composited. Like
/// `apply_border_layer` but with a fill so the landing slot reads as a
/// ghost instead of an outline.
fn apply_drop_preview_layer(window: &NSWindow, params: &BorderParams) {
    let Some(view) = window.contentView() else {
        return;
    };
    view.setWantsLayer(true);
    let Some(layer) = view.layer() else {
        return;
    };
    let fill = NSColor::colorWithSRGBRed_green_blue_alpha(
        params.color.0 as CGFloat,
        params.color.1 as CGFloat,
        params.color.2 as CGFloat,
        DROP_PREVIEW_FILL_ALPHA as CGFloat,
    );
    layer.setBackgroundColor(Some(fill.CGColor().as_ref()));
    let stroke = NSColor::colorWithSRGBRed_green_blue_alpha(
        params.color.0 as CGFloat,
        params.color.1 as CGFloat,
        params.color.2 as CGFloat,
        params.opacity as CGFloat,
    );
    layer.setBorderWidth(params.width as CGFloat);
    layer.setBorderColor(Some(stroke.CGColor().as_ref()));
    layer.setCornerRadius(params.radius as CGFloat);
}

/// Builds a fresh drop-preview window: small overlay window + layer-backed
/// content view with the ghost styling applied once at creation.
fn make_drop_preview_window(
    mtm: MainThreadMarker,
    cocoa: NSRect,
    params: &BorderParams,
) -> Retained<NSWindow> {
    let window = make_overlay_window(mtm, cocoa);
    let view: Retained<NSView> = unsafe {
        msg_send![NSView::alloc(mtm), initWithFrame: NSRect::new(NSPoint::new(0.0, 0.0), cocoa.size)]
    };
    view.setWantsLayer(true);
    window.setContentView(Some(&view));
    apply_drop_preview_layer(&window, params);
    window.orderFront(None::<&AnyObject>);
    window
}

/// A border-only overlay window: small (window-sized, not fullscreen),
/// layer-backed, never repainted. Reused across moves; layer properties are
/// only rewritten when the params actually change.
struct BorderOverlay {
    window: Retained<NSWindow>,
    /// Cocoa frame as currently set.
    rect: NSRect,
    params: BorderParams,
}

/// Builds a fresh border window: small overlay window + layer-backed content
/// view with the border styling applied once at creation.
fn make_border_window(
    mtm: MainThreadMarker,
    cocoa: NSRect,
    params: &BorderParams,
) -> Retained<NSWindow> {
    let window = make_overlay_window(mtm, cocoa);
    let view: Retained<NSView> = unsafe {
        msg_send![NSView::alloc(mtm), initWithFrame: NSRect::new(NSPoint::new(0.0, 0.0), cocoa.size)]
    };
    view.setWantsLayer(true);
    window.setContentView(Some(&view));
    apply_border_layer(&window, params);
    window.orderFront(None::<&AnyObject>);
    window
}

// ── Overlay window factory ──────────────────────────────────────────────

fn make_overlay_window(mtm: MainThreadMarker, cocoa_frame: NSRect) -> Retained<NSWindow> {
    let window = unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(
            NSWindow::alloc(mtm),
            cocoa_frame,
            NSWindowStyleMask::Borderless,
            NSBackingStoreType::Buffered,
            false,
        )
    };
    window.setOpaque(false);
    window.setBackgroundColor(Some(&NSColor::clearColor()));
    window.setIgnoresMouseEvents(true);
    window.setHasShadow(false);
    window.setLevel(NSFloatingWindowLevel);
    window.setCollectionBehavior(
        NSWindowCollectionBehavior::Transient
            | NSWindowCollectionBehavior::IgnoresCycle
            | NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::Stationary
            | NSWindowCollectionBehavior::FullScreenNone,
    );

    window
}
// ── OverlayManager ──────────────────────────────────────────────────────

/// How long a cached primary-screen height stays valid. Displays barely
/// change, and `NSScreen::screens` per overlay tick costs more than the
/// staleness it prevents; display add/remove also rebuilds the surfaces,
/// which re-probes unconditionally (see `screen_height`).
const SCREEN_HEIGHT_CACHE: Duration = Duration::from_secs(60);

pub struct OverlayManager {
    mtm: MainThreadMarker,
    /// One overlay window per display. macOS will not reliably let a single
    /// window span multiple displays (with "Displays have separate Spaces" it
    /// renders on only one), so each screen gets its own overlay drawn in that
    /// screen's local coordinates. Indexed in lockstep with `NSScreen::screens`.
    overlays: Vec<(Retained<NSWindow>, DimParams, NSRect)>,
    hidden: bool,
    /// The drop-preview ghost shown during armed display drags, if any.
    drop_preview: Option<(Retained<NSWindow>, NSRect, BorderParams)>,
    /// Per-window borders by window id: the focused window plus, when
    /// inactive borders are enabled, every visible tiled window. Small
    /// layer-backed windows (see `BorderOverlay`); entries not in the latest
    /// sync are ordered out and dropped.
    borders: HashMap<WinID, BorderOverlay>,
    /// Whether the border set is currently ordered out. `hide_borders`
    /// runs every frame of a tracked hold; without this each tick pays an
    /// `orderOut` round trip per border for windows that are already
    /// hidden. Cleared whenever `sync_borders` (re)shows anything.
    borders_hidden: bool,
    /// Cached [`primary_screen_height`]: up to three overlay entry points
    /// need it per tick (`update`, `sync_borders`, `show_drop_preview`),
    /// and each probe walks `NSScreen::screens` on the main thread.
    screen_h: Option<(Instant, f64)>,
}

impl OverlayManager {
    pub fn new(mtm: MainThreadMarker) -> Self {
        Self {
            mtm,
            overlays: Vec::new(),
            hidden: false,
            drop_preview: None,
            borders: HashMap::new(),
            borders_hidden: false,
            screen_h: None,
        }
    }

    /// Primary-screen height, cached for [`SCREEN_HEIGHT_CACHE`]. Callers
    /// that already know the display set changed (surface rebuild) pass
    /// `refresh = true` to re-probe immediately.
    fn screen_height(&mut self, refresh: bool) -> f64 {
        if refresh
            || self
                .screen_h
                .is_none_or(|(at, _)| at.elapsed() >= SCREEN_HEIGHT_CACHE)
        {
            self.refresh_screen_height();
        }
        self.screen_h.map_or(0.0, |(_, h)| h)
    }

    /// Re-probes the primary-screen height immediately, bypassing the cache.
    /// Called when the display generation advances (reconcile, rescan,
    /// reconfiguration): same-count changes keep the surface count while
    /// moving the origin the CG↔Cocoa flip is anchored to.
    pub fn refresh_screen_height(&mut self) {
        self.screen_h = Some((Instant::now(), primary_screen_height(self.mtm)));
    }

    /// Update the per-display dim surfaces.
    /// `focused_abs_cg` is the focused window rect in absolute CG coords,
    /// or `None` if no window is focused. The border is drawn by its own
    /// layer-backed window (`update_focused_border`), never here.
    pub fn update(
        &mut self,
        dim_opacity: f32,
        dim_color: (f64, f64, f64),
        focused_abs_cg: Option<NSRect>,
        cutout_radius: f64,
    ) {
        let screens = NSScreen::screens(self.mtm);
        // Display add/remove rebuilds from scratch below; re-probe the
        // cached height on that tick so a new primary applies at once.
        let screen_h = self.screen_height(self.overlays.len() != screens.len());

        // The focused window in Cocoa global coords (shared across all screens).
        let focused_cocoa = focused_abs_cg.map(|cg| cg_abs_to_cocoa(cg, screen_h));

        // A display was added/removed — tear down and rebuild from scratch.
        if self.overlays.len() != screens.len() {
            for (window, ..) in self.overlays.drain(..) {
                window.orderOut(None::<&AnyObject>);
            }
        }

        for (i, screen) in (&screens).into_iter().enumerate() {
            let frame = screen.frame();

            // Cut out the focused window on every display it touches, each in
            // that display's local (flipped, top-left origin) coordinates. A
            // window straddling a seam draws on both, clipped to each.
            let cutout_local = focused_cocoa
                .filter(|wc| rects_intersect(*wc, frame))
                .map(|wc| {
                    NSRect::new(
                        NSPoint::new(
                            wc.origin.x - frame.origin.x,
                            (frame.origin.y + frame.size.height) - (wc.origin.y + wc.size.height),
                        ),
                        wc.size,
                    )
                });

            let params = DimParams {
                opacity: dim_opacity,
                color: dim_color,
                cutout: cutout_local,
                cutout_radius,
            };

            if let Some((window, stored, placed)) = self.overlays.get_mut(i) {
                if *stored == params {
                    // A `setFrame` is a WindowServer round trip even with
                    // `display: false`: skip it when neither geometry nor
                    // params moved since the last tick.
                    if !nsrect_eq(*placed, frame) {
                        window.setFrame_display(frame, false);
                        *placed = frame;
                    }
                } else {
                    // Cutout-only motion (the focused window gliding under a
                    // static dim): same paint, new hole. Rebuild the view
                    // but composite asynchronously — the synchronous redraw
                    // is what skewed the dim a frame behind layer-moved
                    // borders every glide tick.
                    #[allow(
                        clippy::float_cmp,
                        reason = "exact match with the derived PartialEq compared one branch up; config values are bit-stable per tick"
                    )]
                    let same_paint = stored.opacity == params.opacity
                        && stored.color == params.color
                        && stored.cutout_radius == params.cutout_radius;
                    let view = DimView::new(self.mtm, frame, &params);
                    window.setContentView(Some(&view));
                    window.setFrame_display(frame, !same_paint);
                    *stored = params;
                    *placed = frame;
                }
                if self.hidden {
                    window.orderFront(None::<&AnyObject>);
                }
            } else {
                let window = make_overlay_window(self.mtm, frame);
                let view = DimView::new(self.mtm, frame, &params);
                window.setContentView(Some(&view));
                window.orderFront(None::<&AnyObject>);
                self.overlays.push((window, params, frame));
            }
        }
        self.hidden = false;
    }

    pub fn remove_all(&mut self) {
        for (window, ..) in self.overlays.drain(..) {
            window.orderOut(None::<&AnyObject>);
        }
        self.hide_borders();
        self.hidden = false;
        // Map is empty either way; reset so the next hide pays honestly.
        self.borders_hidden = false;
    }

    /// Remove the fullscreen dim surfaces without touching the per-window
    /// borders (used when dimming is configured off but borders are on: no
    /// transparent fullscreen windows linger consuming backing stores).
    pub fn remove_dim_overlays(&mut self) {
        for (window, ..) in self.overlays.drain(..) {
            window.orderOut(None::<&AnyObject>);
        }
    }

    pub fn hide_all(&mut self) {
        if self.hidden {
            return;
        }
        for (window, ..) in &self.overlays {
            window.orderOut(None::<&AnyObject>);
        }
        self.hide_borders();
        self.hidden = true;
    }

    /// Order out every border window but keep them cached, so the next sync
    /// re-shows without rebuilding. Used for the drag blackout: borders
    /// hide for the gesture while dim and the drop ghost keep painting.
    pub(crate) fn hide_borders(&mut self) {
        if self.borders_hidden {
            return;
        }
        for border in self.borders.values() {
            border.window.orderOut(None::<&AnyObject>);
        }
        self.borders_hidden = true;
    }

    /// Sync per-window borders to `desired` (window id, absolute CG rect,
    /// params): drops vanished windows, moves/reskins changed ones, orders
    /// everything in. Moves never repaint and never rebuild views; only
    /// genuine param changes rewrite layer properties. Cost is O(changed),
    /// never O(all windows). `wanted` is caller-owned scratch (clear +
    /// refill inside) so no set is allocated per tick.
    pub fn sync_borders(
        &mut self,
        desired: &[(WinID, NSRect, BorderParams)],
        wanted: &mut std::collections::HashSet<WinID>,
    ) {
        let screen_h = self.screen_height(false);
        // Set lookup: the retain scan below runs per border per tick, and
        // with inactive borders on both sides grow with the window count.
        wanted.clear();
        wanted.extend(desired.iter().map(|(id, _, _)| *id));
        self.borders.retain(|id, border| {
            let keep = wanted.contains(id);
            if !keep {
                border.window.orderOut(None::<&AnyObject>);
            }
            keep
        });
        // An emptied map resets the hidden flag outright: with nothing
        // ordered in, "hidden" is meaningless, and a stale `true` would make
        // the next `hide_borders` a no-op while a visibility race below
        // could leave a window showing.
        if self.borders.is_empty() {
            self.borders_hidden = false;
        }
        for (id, abs_cg, params) in desired {
            let cocoa = cg_abs_to_cocoa(border_window_rect(*abs_cg, params.width), screen_h);
            if let Some(border) = self.borders.get_mut(id) {
                if !nsrect_eq(border.rect, cocoa) {
                    border.window.setFrame_display(cocoa, false);
                    border.rect = cocoa;
                }
                if border.params != *params {
                    apply_border_layer(&border.window, params);
                    border.params = params.clone();
                }
                // Reasserting front-order every tick costs a WindowServer
                // round-trip at display rate; skip it while already visible.
                // Moves and reskins above don't change frontness, and new
                // windows order front on creation below.
                if !border.window.isVisible() {
                    border.window.orderFront(None::<&AnyObject>);
                    self.borders_hidden = false;
                }
            } else {
                let window = make_border_window(self.mtm, cocoa, params);
                self.borders.insert(
                    *id,
                    BorderOverlay {
                        window,
                        rect: cocoa,
                        params: params.clone(),
                    },
                );
                self.borders_hidden = false;
            }
        }
    }

    /// Show the drop-preview ghost: a filled, border-stroked outline of the
    /// landing slot, `abs_cg` in absolute CG coords. Layer-backed like the
    /// borders (GPU-composited fill + stroke): moves never repaint and never
    /// rebuild views; only genuine rect/param changes rewrite layer
    /// properties. Reuses its window across ticks.
    pub fn show_drop_preview(&mut self, abs_cg: NSRect, border: &BorderParams) {
        let cocoa = cg_abs_to_cocoa(abs_cg, self.screen_height(false));
        if let Some((window, rect, params)) = &mut self.drop_preview {
            if nsrect_eq(*rect, cocoa) && *params == *border {
                window.orderFront(None::<&AnyObject>);
                return;
            }
            if let Some(view) = window.contentView() {
                view.setFrame(NSRect::new(NSPoint::new(0.0, 0.0), cocoa.size));
            }
            apply_drop_preview_layer(window, border);
            window.setFrame_display(cocoa, false);
            window.orderFront(None::<&AnyObject>);
            *rect = cocoa;
            *params = border.clone();
            return;
        }
        let window = make_drop_preview_window(self.mtm, cocoa, border);
        self.drop_preview = Some((window, cocoa, border.clone()));
    }

    /// Remove the drop-preview ghost, if shown.
    pub fn hide_drop_preview(&mut self) {
        if let Some((window, _, _)) = self.drop_preview.take() {
            window.orderOut(None::<&AnyObject>);
        }
    }
}

// ── DropPreview: filled ghost of the landing slot during armed drags ──
// Layer-backed (see `apply_drop_preview_layer`); no custom `drawRect`.

/// Sub-pixel jitter must not cost a `WindowServer` round trip per tick: the
/// tween rounds to whole pixels, but snapshot/drag truth can still dither
/// below a pixel. Treat <=0.5px deltas as equal so borders rest instead of
/// shimmering.
fn nsrect_eq(a: NSRect, b: NSRect) -> bool {
    (a.origin.x - b.origin.x).abs() <= 0.5
        && (a.origin.y - b.origin.y).abs() <= 0.5
        && (a.size.width - b.size.width).abs() <= 0.5
        && (a.size.height - b.size.height).abs() <= 0.5
}

// ── FlashMessage ────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct FlashMessageViewIvars {
    opacity: f32,
    message: Retained<NSString>,
    is_badge: bool,
}

define_class!(
    #[unsafe(super(NSView))]
    #[thread_kind = MainThreadOnly]
    #[name = "PaneruFlashMessageView"]
    #[ivars = FlashMessageViewIvars]
    #[derive(Debug)]
    struct FlashMessageView;

    impl FlashMessageView {
        #[unsafe(method(drawRect:))]
        fn draw_rect(&self, _dirty_rect: NSRect) {
            let ivars = self.ivars();
            let bounds = self.bounds();
            let is_badge = ivars.is_badge;

            // 1. Draw semi-transparent bezel
            let bezel_color = NSColor::colorWithSRGBRed_green_blue_alpha(
                0.12, 0.12, 0.12,
                CGFloat::from(ivars.opacity * 0.88),
            );
            bezel_color.setFill();
            let radius = if is_badge {
                24.0
            } else {
                bounds.size.height / 2.0
            };
            let path = NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(
                bounds, radius, radius,
            );
            path.fill();

            // Draw subtle border for contrast
            let border_color = NSColor::colorWithSRGBRed_green_blue_alpha(
                1.0, 1.0, 1.0,
                CGFloat::from(ivars.opacity * 0.15),
            );
            border_color.setStroke();
            path.setLineWidth(1.0);
            path.stroke();

            // 2. Draw text
            let font = if is_badge {
                NSFont::boldSystemFontOfSize(bounds.size.height * 0.62)
            } else {
                NSFont::systemFontOfSize(30.0)
            };
            let color = NSColor::colorWithSRGBRed_green_blue_alpha(
                1.0, 1.0, 1.0,
                CGFloat::from(ivars.opacity * 0.95),
            );

            let paragraph_style = unsafe {
                let style = NSParagraphStyle::defaultParagraphStyle().mutableCopy();
                let _: () = msg_send![&style, setAlignment: 1isize]; // Center (NSTextAlignmentCenter = 1)
                let _: () = msg_send![&style, setLineBreakMode: 4isize]; // NSLineBreakByTruncatingTail = 4
                style
            };

            let attr_str: Retained<NSAttributedString> = unsafe {
                let font_key = NSString::from_str("NSFont");
                let color_key = NSString::from_str("NSColor");
                let para_key = NSString::from_str("NSParagraphStyle");

                let keys = [&*font_key, &*color_key, &*para_key];
                let objects = [
                    &*font as &AnyObject,
                    &*color as &AnyObject,
                    &*paragraph_style as &AnyObject,
                ];

                let attributes = NSDictionary::from_slices(&keys, &objects);
                let alloc = NSAttributedString::alloc();
                msg_send![alloc, initWithString: &*ivars.message, attributes: &*attributes]
            };

            let text_size: NSSize = unsafe { msg_send![&attr_str, size] };

            let text_rect = if is_badge {
                NSRect::new(
                    NSPoint::new(
                        bounds.origin.x + (bounds.size.width - text_size.width) / 2.0,
                        bounds.origin.y + (bounds.size.height - text_size.height) / 2.0,
                    ),
                    text_size,
                )
            } else {
                let h_pad = 24.0;
                let available_width = (bounds.size.width - (2.0 * h_pad)).max(1.0);
                NSRect::new(
                    NSPoint::new(
                        bounds.origin.x + h_pad,
                        bounds.origin.y + (bounds.size.height - text_size.height) / 2.0,
                    ),
                    NSSize::new(available_width, text_size.height),
                )
            };

            unsafe {
                let _: () = msg_send![&attr_str, drawInRect: text_rect];
            };
        }
    }
);

impl FlashMessageView {
    fn new(
        mtm: MainThreadMarker,
        frame: NSRect,
        message: &str,
        opacity: f32,
        is_badge: bool,
    ) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(FlashMessageViewIvars {
            opacity,
            message: NSString::from_str(message),
            is_badge,
        });
        unsafe { msg_send![super(this), initWithFrame: frame] }
    }
}

pub struct FlashMessageManager {
    mtm: MainThreadMarker,
    window: Option<Retained<NSWindow>>,
    screen_h: Option<(Instant, f64)>,
    /// Last painted OSD state: opacity is quantized to 0.1 steps so the
    /// per-tick fade (~60fps) rebuilds the view ~6 times instead of every
    /// tick. Same message + bucket + frame = no work beyond `orderFront`.
    shown: Option<(String, u8, NSRect)>,
}

impl FlashMessageManager {
    pub fn new(mtm: MainThreadMarker) -> Self {
        Self {
            mtm,
            window: None,
            screen_h: None,
            shown: None,
        }
    }

    #[allow(clippy::cast_precision_loss)]
    pub fn show(&mut self, message: &str, opacity: f32, top_right_abs_cg: NSPoint) {
        let is_badge = message.chars().count() <= 2;
        if self
            .screen_h
            .is_none_or(|(at, _)| at.elapsed() >= SCREEN_HEIGHT_CACHE)
        {
            self.screen_h = Some((Instant::now(), primary_screen_height(self.mtm)));
        }
        let screen_h = self.screen_h.map_or(0.0, |(_, h)| h);

        let size = if is_badge {
            NSSize::new(150.0, 150.0)
        } else {
            let font = NSFont::systemFontOfSize(30.0);
            let font_key = NSString::from_str("NSFont");
            let keys = [&*font_key];
            let objects = [&*font as &AnyObject];
            let attributes = NSDictionary::from_slices(&keys, &objects);
            let msg_ns = NSString::from_str(message);
            let attr_str: Retained<NSAttributedString> = unsafe {
                let alloc = NSAttributedString::alloc();
                msg_send![alloc, initWithString: &*msg_ns, attributes: &*attributes]
            };
            let text_size: NSSize = unsafe { msg_send![&attr_str, size] };
            let horizontal_padding = 48.0;
            let max_width = 780.0;
            let min_width = 140.0;
            let width = (text_size.width + horizontal_padding).clamp(min_width, max_width);
            NSSize::new(width, 64.0)
        };

        let padding = 20.0;

        let cocoa_origin_x = top_right_abs_cg.x - size.width - padding;
        let cocoa_origin_y = screen_h - (top_right_abs_cg.y + size.height + padding);

        let frame = NSRect::new(NSPoint::new(cocoa_origin_x, cocoa_origin_y), size);

        // Quantized fade: the view bakes opacity into its pixels, so only
        // rebuild when the bucket moves, not on every fractional tick.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let bucket = (opacity.clamp(0.0, 1.0) * 10.0).round() as u8;
        if let Some((shown_msg, shown_bucket, shown_frame)) = &self.shown
            && shown_msg == message
            && *shown_bucket == bucket
            && nsrect_eq(*shown_frame, frame)
            && let Some(window) = &self.window
        {
            window.orderFront(None::<&AnyObject>);
            return;
        }
        self.shown = Some((message.to_string(), bucket, frame));

        if let Some(window) = &self.window {
            let view = FlashMessageView::new(
                self.mtm,
                NSRect::new(NSPoint::new(0.0, 0.0), size),
                message,
                opacity,
                is_badge,
            );
            window.setContentView(Some(&view));
            window.setFrame_display(frame, true);
            window.orderFront(None::<&AnyObject>);
        } else {
            let window = make_overlay_window(self.mtm, frame);
            window.setLevel(NSFloatingWindowLevel + 1);
            let view = FlashMessageView::new(
                self.mtm,
                NSRect::new(NSPoint::new(0.0, 0.0), size),
                message,
                opacity,
                is_badge,
            );
            window.setContentView(Some(&view));
            window.orderFront(None::<&AnyObject>);
            self.window = Some(window);
        }
    }

    pub fn remove(&mut self) {
        if let Some(window) = self.window.take() {
            window.orderOut(None::<&AnyObject>);
        }
        self.shown = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn border_window_inflates_by_half_width() {
        // A 2px border on a 400x300 window at (10, 20): the layer stroke is
        // centered on the layer edge with its outer half visible, so the
        // window grows by half the width per side and the visible stroke
        // sits exactly at [edge, edge+width] — flush, no hairline gap.
        let rect = border_window_rect(
            NSRect::new(NSPoint::new(10.0, 20.0), NSSize::new(400.0, 300.0)),
            2.0,
        );
        assert!(nsrect_eq(
            rect,
            NSRect::new(NSPoint::new(9.0, 19.0), NSSize::new(402.0, 302.0))
        ));
    }

    #[test]
    fn zero_width_border_is_identity() {
        let rect = NSRect::new(NSPoint::new(10.0, 20.0), NSSize::new(400.0, 300.0));
        assert!(nsrect_eq(rect, border_window_rect(rect, 0.0)));
    }
}
