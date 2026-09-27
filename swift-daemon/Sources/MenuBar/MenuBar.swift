// Menu bar (`src/menubar.rs`): workspace indicator plus command menu.
// The string builders below are pure and pinned by checks; the live
// `NSStatusItem` shell at the bottom is main-thread AppKit proven on a
// permissioned host. One hard rule from the Rust original: the button
// shows a baked bitmap (`button.image`), never live subviews — a live
// view in the button snapshot-loops AppKit and starves the tap run loop.
import AppKit
import Foundation

// MARK: - Pure indicator model

/// Single-cell label format.
public enum IndicatorFormat: Equatable, Sendable {
    case `default`, roman, unicode, marked
}

/// Indicator layout across the configured rows.
public enum IndicatorStyle: Equatable, Sendable {
    case mono, multi, paged
}

/// Descriptor (prefix) placement relative to the indicator.
public enum MenuBarOrientation: Equatable, Sendable {
    case `default`, flipped
}

public let defaultActiveCharacter = "☉"
public let defaultInactiveCharacter = "○"

/// 1-based decimal label for a 0-based row.
public func virtualWorkspaceLabel(_ index: UInt32) -> String {
    String(index + 1)
}

/// Greedy-subtract roman numerals. Correct below 90 by design.
public func romanNumeral(_ value: UInt32) -> String {
    var remaining = Int(value)
    var out = ""
    for (arabic, roman) in [
        (50, "L"), (40, "XL"), (10, "X"), (9, "IX"),
        (5, "V"), (4, "IV"), (1, "I"),
    ] {
        while remaining >= arabic {
            out += roman
            remaining -= arabic
        }
    }
    return out
}

/// Last row shown in paged mode; never underflows (empty still shows 1).
public func pagedLastIndex(count: Int) -> UInt32 {
    UInt32(max(count, 1) - 1)
}

/// One cell's label. Unicode ignores the index; marked numbers the active
/// row and glyphs the rest.
public func indicatorLabel(
    format: IndicatorFormat, index: UInt32, isActive: Bool,
    activeCharacter: String = defaultActiveCharacter,
    inactiveCharacter: String = defaultInactiveCharacter
) -> String {
    switch format {
    case .default:
        return virtualWorkspaceLabel(index)
    case .roman:
        return romanNumeral(index + 1)
    case .unicode:
        return isActive ? activeCharacter : inactiveCharacter
    case .marked:
        return isActive ? virtualWorkspaceLabel(index) : inactiveCharacter
    }
}

/// The indicator cells: mono renders one unbolded cell; multi one per row
/// with the active marked; paged renders `<current> / <last>`. Unicode
/// and marked say nothing alone under mono/paged, so those force default.
/// Nil when there is no current row (no indicator at all).
public func buildIndicatorCells(
    style: IndicatorStyle, format: IndicatorFormat,
    current: UInt32?, all: [UInt32],
    activeCharacter: String = defaultActiveCharacter,
    inactiveCharacter: String = defaultInactiveCharacter
) -> [String]? {
    guard let current else { return nil }
    var effective = format
    if (style == .mono || style == .paged)
        && (format == .unicode || format == .marked)
    {
        effective = .default
    }
    func cell(_ index: UInt32, active: Bool) -> String {
        indicatorLabel(
            format: effective, index: index, isActive: active,
            activeCharacter: activeCharacter, inactiveCharacter: inactiveCharacter
        )
    }
    switch style {
    case .mono:
        return [cell(current, active: false)]
    case .multi:
        return all.map { cell($0, active: $0 == current) }
    case .paged:
        return [cell(current, active: true), "/", cell(pagedLastIndex(count: all.count), active: false)]
    }
}

/// Whether a cell renders bold: active rows except in unicode.
public func indicatorCellBold(format: IndicatorFormat, isActive: Bool) -> Bool {
    isActive && format != .unicode
}

// MARK: - Pure menu model

/// Width presets as menu percentages: finite positives only, rounded,
/// sorted, deduped.
public func normalizedWidthPercentages(_ ratios: [Double]) -> [Int] {
    Array(Set(ratios.filter { $0.isFinite && $0 > 0 }.map {
        Int(($0 * 100).rounded())
    }.filter { $0 > 0 }).sorted())
}

/// Which menu actions enable: width items plus Center need a managed
/// focused window with a known ratio; Managed and Copy Rule need focus.
public func menuEnablement(
    focusedWidthRatio: Double?, hasFocusedWindow: Bool
) -> (managedActions: Bool, toggleManaged: Bool) {
    (focusedWidthRatio != nil, hasFocusedWindow)
}

/// Checkmark rule: the preset within one point of the focused ratio.
public func widthCheckmarked(percentage: Int, focusedRatio: Double?) -> Bool {
    guard let focusedRatio else { return false }
    return abs(focusedRatio * 100 - Double(percentage)) < 1.0
}

public enum MenuBarStrings {
    public static let running = "Paneru — Running"
    public static let windowWidth = "Window width"
    public static let centerWindow = "Center Window"
    public static let toggleManaged = "Toggle Managed"
    public static let copyWindowRule = "Copy Window Rule"
    public static let quit = "Quit Paneru"
    public static let accessibilityRequired = "Paneru — Accessibility Required"
    public static let grantAccess = "Grant access; Paneru will start automatically"
    public static let showInstructions = "Show Setup Instructions…"
    public static let openSettings = "Open Accessibility Settings…"
    public static let tooltip = "Paneru window manager"
    public static let bootText = "!"

    public static func widthTitle(_ percentage: Int) -> String {
        "\(percentage)%"
    }
}

// MARK: - Live shell (main thread, permissioned host)

///
public enum MenuBarCommand: Equatable, Sendable {
    case setWidth(ratio: Double)
    case center
    case toggleManaged
    case copyRule
    case openAccessibilitySettings
    case showAccessibilityInstructions
    case quit
}

/// What the indicator currently shows, for change-diffing.
public struct MenuBarContent: Equatable, Sendable {
    public var cells: [String]
    public var widths: [Int]

    public init(cells: [String] = [], widths: [Int] = []) {
        self.cells = cells
        self.widths = widths
    }
}

private final class MenuActionTarget: NSObject {
    var sink: ((MenuBarCommand) -> Void)?

    @objc func setWidth(_ sender: NSMenuItem) {
        sink?(.setWidth(ratio: Double(sender.tag) / 100.0))
    }
    @objc func centerWindow(_ sender: NSMenuItem) {
        sink?(.center)
    }
    @objc func toggleManaged(_ sender: NSMenuItem) {
        sink?(.toggleManaged)
    }
    @objc func copyWindowRule(_ sender: NSMenuItem) {
        sink?(.copyRule)
    }
    @objc func openAccessibilitySettings(_ sender: NSMenuItem) {
        sink?(.openAccessibilitySettings)
    }
    @objc func showAccessibilityInstructions(_ sender: NSMenuItem) {
        sink?(.showAccessibilityInstructions)
    }
    @objc func quitPaneru(_ sender: NSMenuItem) {
        sink?(.quit)
    }
}

/// The live status item. Owns one variable-length item, one menu with
/// manual enablement, and one action target; redraws by replacing
/// `button.image` with a baked bitmap. Main thread only.
public final class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let target = MenuActionTarget()
    private var widthItems: [(percentage: Int, item: NSMenuItem)] = []
    private var managedItems: [NSMenuItem] = []
    private var manageItem: NSMenuItem?
    private var copyRuleItem: NSMenuItem?
    private var current = MenuBarContent()

    public init(commands: @escaping (MenuBarCommand) -> Void) {
        target.sink = commands
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.isVisible = true
        rebuildMenu(widths: [])
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Show a plain text badge (accessibility boot path shows `"!"`).
    public func showText(_ text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = text
        button.imagePosition = .noImage
    }

    /// Rebuild the command menu; width items carry their percentage tag.
    public func rebuildMenu(widths: [Int]) {
        dispatchPrecondition(condition: .onQueue(.main))
        menu.removeAllItems()
        widthItems = []
        managedItems = []
        func add(
            _ title: String, action: Selector?, enabled: Bool = true
        ) -> NSMenuItem {
            let item = menu.addItem(
                withTitle: title, action: action, keyEquivalent: ""
            )
            if action != nil { item.target = target }
            item.isEnabled = enabled
            return item
        }
        func separator() { menu.addItem(.separator()) }
        _ = add(MenuBarStrings.running, action: nil, enabled: false)
        separator()
        _ = add(MenuBarStrings.windowWidth, action: nil, enabled: false)
        for percentage in widths {
            let item = add(
                MenuBarStrings.widthTitle(percentage),
                action: #selector(MenuActionTarget.setWidth(_:))
            )
            item.tag = percentage
            widthItems.append((percentage, item))
            managedItems.append(item)
        }
        separator()
        managedItems.append(add(
            MenuBarStrings.centerWindow,
            action: #selector(MenuActionTarget.centerWindow(_:))
        ))
        let manage = add(
            MenuBarStrings.toggleManaged,
            action: #selector(MenuActionTarget.toggleManaged(_:))
        )
        manageItem = manage
        separator()
        copyRuleItem = add(
            MenuBarStrings.copyWindowRule,
            action: #selector(MenuActionTarget.copyWindowRule(_:))
        )
        separator()
        _ = add(MenuBarStrings.quit, action: #selector(MenuActionTarget.quitPaneru(_:)))
    }

    /// Refresh enablement, checkmarks, and the indicator image. Skips the
    /// bitmap when content is unchanged.
    public func update(
        cells: [String], widths: [Int],
        focusedWidthRatio: Double?, hasFocusedWindow: Bool,
        fontSize: Double = 13
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        if widths != current.widths {
            rebuildMenu(widths: widths)
        }
        let (managedActions, toggleManaged) = menuEnablement(
            focusedWidthRatio: focusedWidthRatio,
            hasFocusedWindow: hasFocusedWindow
        )
        for item in managedItems { item.isEnabled = managedActions }
        manageItem?.isEnabled = toggleManaged
        copyRuleItem?.isEnabled = toggleManaged
        for (percentage, item) in widthItems {
            item.state = widthCheckmarked(
                percentage: percentage, focusedRatio: focusedWidthRatio
            ) ? .on : .off
        }
        let content = MenuBarContent(cells: cells, widths: widths)
        guard content != current else { return }
        current = content
        guard let button = statusItem.button else { return }
        button.image = indicatorImage(cells: cells, fontSize: fontSize)
        button.imagePosition = .imageOnly
        button.toolTip = MenuBarStrings.tooltip
        statusItem.length = NSStatusItem.variableLength
    }

    /// Baked bitmap for space-joined cells at the button's scale.
    private func indicatorImage(cells: [String], fontSize: Double) -> NSImage? {
        let text = cells.joined(separator: " ")
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize))
        let attrs = [NSAttributedString.Key.font: font]
        let size = (text as NSString).size(withAttributes: attrs)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = statusItem.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 1
        let pixels = NSSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (text as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}
