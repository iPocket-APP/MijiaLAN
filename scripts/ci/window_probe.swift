// Reads what a process has on screen and clicks like a person, for install checks on hosted runners.
//   window_probe windows <pid>   the process's windows (layer, bounds, alpha) and the displays, as JSON
//   window_probe click <x> <y>   a left click at global display coordinates (top-left origin)
//   window_probe access          which TCC permissions this process has, as JSON
import ApplicationServices
import CoreGraphics
import Foundation

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
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
case "statusitems":
    // macOS 26 hosts menu-bar icons outside the app's own windows; Accessibility sees them on every version.
    guard arguments.count == 2, let pid = Int32(arguments[1]) else { exit(2) }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    let app = AXUIElementCreateApplication(pid)
    var items: [[String: Any]] = []
    if let bar = attribute(app, "AXExtrasMenuBar"), let children = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            var position = CGPoint.zero, size = CGSize.zero
            if let value = attribute(child, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &position) }
            if let value = attribute(child, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
            items.append(["x": position.x, "y": position.y, "width": size.width, "height": size.height,
                          "title": attribute(child, kAXTitleAttribute) as? String ?? "",
                          "description": attribute(child, kAXDescriptionAttribute) as? String ?? ""])
        }
    }
    emit(["trusted": AXIsProcessTrusted(), "items": items])
case "click":
    guard arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else { exit(2) }
    let point = CGPoint(x: x, y: y)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(120_000)
    }
case "access":
    emit(["postEvents": CGPreflightPostEventAccess(), "screenCapture": CGPreflightScreenCaptureAccess(),
          "accessibility": AXIsProcessTrusted()])
default:
    exit(2)
}
