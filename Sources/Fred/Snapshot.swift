import AppKit

/// Renders a view hierarchy to a PNG via `cacheDisplay` (development aid; see
/// ControlServer `snapshot`). The glass backdrop is replaced by an opaque fill.
@MainActor
enum Snapshot {
    static func write(view: NSView, to path: String) -> String {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no rep" }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Composite over an opaque background so the PNG is readable.
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let out = NSImage(size: size)
        out.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
        }
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return "encode failed" }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return "write failed: \(error)" }
        return "wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)"
    }
}
