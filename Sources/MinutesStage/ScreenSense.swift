import AppKit
import CoreGraphics
import MinutesCore

/// Reads the window server: which windows are on screen, where, and whose.
/// Needs no permission (window titles stay empty without Screen Recording).
@MainActor
public final class ScreenSense {
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let ignoredOwners: Set<String> = ["Window Server", "Dock", "Control Center", "Notification Center", "Spotlight"]

    public init() {}

    public func snapshot() -> SceneSnapshot {
        let screens = NSScreen.screens.map { ScreenInfo(frame: $0.frame, visible: $0.visibleFrame) }
        let front = NSWorkspace.shared.frontmostApplication
        var windows: [WindowInfo] = []
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let owner = entry[kCGWindowOwnerName as String] as? String, !Self.ignoredOwners.contains(owner),
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40,
                  let id = entry[kCGWindowNumber as String] as? Int else { continue }
            windows.append(WindowInfo(id: id, app: owner, pid: pid, frame: Self.toAppKit(bounds),
                                      title: entry[kCGWindowName as String] as? String))
        }
        return SceneSnapshot(screens: screens, windows: windows, frontApp: front?.localizedName,
                             frontPID: front?.processIdentifier, cursor: NSEvent.mouseLocation)
    }

    /// Cheap single-window query used to ride along with a moving window.
    public func frame(ofWindow id: Int) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let entry = list.first,
              entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        return Self.toAppKit(bounds)
    }

    /// Window-server rects are top-left based on the primary display; AppKit's are bottom-left.
    static func toAppKit(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Captures the main display for `look_at_screen`, downscaled to keep tokens sane.
@MainActor
public final class ScreenCapturer: ScreenshotPort {
    private var askedForPermission = false

    public init() {}

    public func capture(maxWidth: Int, completion: @escaping (String?) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            if !askedForPermission {
                askedForPermission = true
                CGRequestScreenCaptureAccess()
            }
            completion(nil)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miss-minutes-\(UUID().uuidString).jpg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-m", "-t", "jpg", url.path]
        process.terminationHandler = { _ in
            let encoded = Self.downscaledJPEGBase64(url, maxWidth: maxWidth)
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { completion(encoded) }
        }
        do { try process.run() } catch { completion(nil) }
    }

    nonisolated static func downscaledJPEGBase64(_ url: URL, maxWidth: Int) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxWidth,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
