// Reads what a process has on screen and acts like a person, for install checks on hosted runners.
//   window_probe windows <pid>            the process's windows (layer, bounds, alpha) and the displays, as JSON
//   window_probe onscreen                 every on-screen window with its owner's name, as JSON
//   window_probe statusitems <pid>        the process's menu-bar items, read through Accessibility, as JSON
//   window_probe press <pid|all> <title>...  presses the first button with one of these titles in the process's
//                                         windows, or in those of any process with a window on screen
//   window_probe click <x> <y>            a left click at global display coordinates (top-left origin)
//   window_probe fill <count>             keeps <count> wide menu-bar items open until killed, to crowd the menu bar
//   window_probe access                   which TCC permissions this process has, as JSON
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "windows":
    guard arguments.count == 2, let pid = Int32(arguments[1]) else { exit(2) }
    let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let windows = all.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }.map { window in
        ["number": window[kCGWindowNumber as String] ?? 0, "layer": window[kCGWindowLayer as String] ?? 0,
         "alpha": window[kCGWindowAlpha as String] ?? 0, "onscreen": window[kCGWindowIsOnscreen as String] ?? false,
         "bounds": window[kCGWindowBounds as String] ?? [:]]
    }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let displays = ids.map { id -> [String: Any] in
        let bounds = CGDisplayBounds(id)
        return ["id": id, "main": CGDisplayIsMain(id) != 0,
                "x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height]
    }
    emit(["windows": windows, "displays": displays])
case "onscreen":
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    emit(["windows": all.map { window in
        ["owner": window[kCGWindowOwnerName as String] ?? "", "pid": window[kCGWindowOwnerPID as String] ?? 0,
         "layer": window[kCGWindowLayer as String] ?? 0, "bounds": window[kCGWindowBounds as String] ?? [:]]
    }])
case "statusitems":
    // macOS 26 hosts menu-bar icons outside the app's own windows; Accessibility sees them on every version.
    guard arguments.count == 2, let pid = Int32(arguments[1]) else { exit(2) }
    var items: [[String: Any]] = []
    if let bar = attribute(AXUIElementCreateApplication(pid), "AXExtrasMenuBar") {
        for child in children(bar as! AXUIElement) {
            var position = CGPoint.zero, size = CGSize.zero
            if let value = attribute(child, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &position) }
            if let value = attribute(child, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
            items.append(["x": position.x, "y": position.y, "width": size.width, "height": size.height,
                          "title": attribute(child, kAXTitleAttribute) as? String ?? "",
                          "description": attribute(child, kAXDescriptionAttribute) as? String ?? ""])
        }
    }
    emit(["trusted": AXIsProcessTrusted(), "items": items])
case "press":
    guard arguments.count >= 3 else { exit(2) }
    var pids: [Int32]
    if arguments[1] == "all" {
        // Gatekeeper's first-open prompt belongs to a system agent whose name differs between releases.
        let onscreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        pids = Array(Set(onscreen.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }))
    } else {
        guard let pid = Int32(arguments[1]) else { exit(2) }
        pids = [pid]
    }
    let titles = Set(arguments.dropFirst(2))
    var texts: [String] = [], buttons: [String] = [], pressed: String?, owner: Int32?
    func visit(_ element: AXUIElement, of pid: Int32, depth: Int) {
        guard depth < 10, pressed == nil else { return }
        let role = attribute(element, kAXRoleAttribute) as? String
        if role == kAXStaticTextRole, let text = attribute(element, kAXValueAttribute) as? String { texts.append(text) }
        if role == kAXButtonRole, let title = attribute(element, kAXTitleAttribute) as? String {
            buttons.append(title)
            if titles.contains(title), AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                pressed = title
                owner = pid
                return
            }
        }
        children(element).forEach { visit($0, of: pid, depth: depth + 1) }
    }
    for pid in pids where pressed == nil {
        // Children rather than windows: some agents' dialogs are listed only there.
        visit(AXUIElementCreateApplication(pid), of: pid, depth: 0)
    }
    emit(["pressed": pressed ?? "", "owner": owner.map { Int($0) } ?? 0, "buttons": buttons, "texts": texts])
case "click":
    guard arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else { exit(2) }
    let point = CGPoint(x: x, y: y)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(120_000)
    }
case "fill":
    guard arguments.count == 2, let count = Int(arguments[1]) else { exit(2) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let items = (0..<count).map { index -> NSStatusItem in
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Filler \(index)"
        return item
    }
    withExtendedLifetime(items) { app.run() }
case "access":
    emit(["postEvents": CGPreflightPostEventAccess(), "screenCapture": CGPreflightScreenCaptureAccess(),
          "accessibility": AXIsProcessTrusted()])
default:
    exit(2)
}
