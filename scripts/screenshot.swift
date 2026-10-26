// Regenerates docs/screenshot.png: opens the panel in demo mode over a plain gradient and
// captures that part of the screen. Build the app first with scripts/build-app.sh.
//
//   swift scripts/screenshot.swift
//
// The panel is translucent, so it's captured as composited on screen rather than as a lone
// window. It opens on the display with the active menu bar; a Retina display gives a 2x image.
// The terminal running this needs Screen Recording permission.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let appURL = root.appending(path: "build/MCP Doctor.app")
let output = root.appending(path: "docs/screenshot.png")
let margin: CGFloat = 36

func run(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try! process.run()
    process.waitUntilExit()
}

/// The app's largest on-screen window, in screen coordinates with a top-left origin.
func largestWindow(of app: NSRunningApplication) -> CGRect? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows
        .filter { $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier }
        .compactMap { $0[kCGWindowBounds as String] as? NSDictionary }
        .compactMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        .max { $0.width * $0.height < $1.width * $1.height }
}

guard FileManager.default.fileExists(atPath: appURL.path) else {
    fatalError("Build the app first: scripts/build-app.sh")
}
run("/usr/bin/pkill", ["-x", "MCPDoctor"])
run("/usr/bin/open", [appURL.path, "--args", "--demo", "--show-panel"])
Thread.sleep(forTimeInterval: 4)
// Opening it again brings it to the front, so the panel's controls draw as active.
run("/usr/bin/open", [appURL.path])
Thread.sleep(forTimeInterval: 1)

guard let demo = NSRunningApplication.runningApplications(withBundleIdentifier: "com.edwinzubowicz.mcpdoctor").first,
      let panel = largestWindow(of: demo)
else { fatalError("The demo panel didn't open") }

// The panel plus room for its shadow on the left, right and bottom. The top starts just below
// the menu bar, whose colour the glass picks up along its top edge.
let menuBarGap: CGFloat = 6
let area = CGRect(
    x: panel.minX - margin,
    y: panel.minY + menuBarGap,
    width: panel.width + 2 * margin,
    height: panel.height + margin - menuBarGap
)

// A borderless gradient window under the panel hides whatever else is on screen.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let primaryScreenHeight = NSScreen.screens[0].frame.height
let backdrop = NSWindow(
    contentRect: NSRect(x: area.minX, y: primaryScreenHeight - area.maxY, width: area.width, height: area.height),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
backdrop.level = .floating
backdrop.hasShadow = false
backdrop.ignoresMouseEvents = true
let gradient = CAGradientLayer()
gradient.frame = NSRect(origin: .zero, size: area.size)
gradient.colors = [
    NSColor(srgbRed: 0.80, green: 0.93, blue: 0.95, alpha: 1).cgColor,
    NSColor(srgbRed: 0.80, green: 0.85, blue: 0.98, alpha: 1).cgColor,
]
gradient.startPoint = CGPoint(x: 0, y: 1)
gradient.endPoint = CGPoint(x: 1, y: 0)
backdrop.contentView?.wantsLayer = true
backdrop.contentView?.layer?.addSublayer(gradient)
backdrop.orderFrontRegardless()

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    let region = "\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width)),\(Int(area.height))"
    run("/usr/sbin/screencapture", ["-x", "-R", region, output.path])
    demo.terminate()
    print("Wrote \(output.path)")
    exit(0)
}
app.run()
