import CoreGraphics
import Foundation

// Finds the preview app's window so a screenshot can be scoped to it alone.
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
    as? [[String: Any]] ?? []

for window in windows {
    guard window[kCGWindowOwnerPID as String] as? Int == pid,
        let number = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let height = bounds["Height"] as? Double, height > 100
    else { continue }
    print(number)
    exit(0)
}
exit(1)
