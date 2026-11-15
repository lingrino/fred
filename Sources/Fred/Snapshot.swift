import AppKit

/// Renders a view's layer tree to a PNG (development aid; see ControlServer
/// `snapshot`). Works because Fred's UI is CGImage-backed layers; the glass backdrop
/// (rendered by the window server) is replaced by an opaque fill.
@MainActor
enum Snapshot {
    static func write(view: NSView, to path: String, scale: CGFloat = 2) -> String {
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        guard let layer = view.layer else { return "no layer" }
        let size = view.bounds.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no ctx" }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        if view.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
        layer.render(in: ctx)
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return "encode failed" }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? "wrote \(path) \(w)x\(h)" : "write failed"
    }
}
