@preconcurrency import AppKit
import FredCore

/// Every catalog title pre-rendered once as an alpha mask, shelf-packed into one A8
/// bitmap. A result row shows its title as a layer whose background color is the text
/// color and whose mask is a `contentsRect` into this image — so a keystroke rasterizes
/// no text for rows, selection color flips are free (just a color), and nothing new is
/// uploaded to the window server.
///
/// Built off-main with the catalog (parallel across cores), rebuilt wholesale when the
/// catalog changes. One 4096-px-wide A8 image, at most 16384 px tall (the texture limit):
/// 46-px shelves at 2×, so ~350 shelves — about 5,700 short app titles or ~1,100
/// full-width ones. This Mac's ~1,000 titles take ~3,400 px (~14 MB). Titles that don't
/// fit are left out (`has` is false) and their rows rasterize, as before the atlas.
final class TitleAtlas: @unchecked Sendable {
    let image: CGImage
    let scale: CGFloat
    /// Per catalog item: pixel rect in `image` (y down), and size in points.
    private let rects: [CGRect]
    let lineHeight: CGFloat     // points
    let width: Int, height: Int

    static let pageWidth = 4096
    static let maxHeight = 16384
    /// Titles that didn't fit (0 on any realistic catalog; shown by `fredctl stats`).
    let missing: Int

    init?(titles: [String], font: NSFont, maxWidth: CGFloat, scale: CGFloat) {
        self.scale = scale
        let lh = (font.ascender - font.descender).rounded(.up) + 2
        lineHeight = lh
        let rowPx = Int((lh * scale).rounded(.up))
        let n = titles.count
        // Pass 1 (parallel): typeset + measure (and truncate).
        let lines = UnsafeMutablePointer<CTLine?>.allocate(capacity: max(n, 1))
        lines.initialize(repeating: nil, count: max(n, 1))
        let widths = UnsafeMutablePointer<Int>.allocate(capacity: max(n, 1))
        defer { lines.deinitialize(count: max(n, 1)); lines.deallocate(); widths.deallocate() }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black.cgColor]
        let ell = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
        // Iteration i writes lines[i] and widths[i] only; attrs is read-only.
        let shared = Disjoint((lines: lines, widths: widths, attrs: attrs))
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let s = shared.value
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: titles[i], attributes: s.attrs))
            if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth),
               let t = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ell) { line = t }
            s.lines[i] = line
            s.widths[i] = Int(((CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 2) * scale).rounded(.up))
        }
        // Shelf packing in item order (deterministic); past the texture limit, titles are
        // left out (null rect) rather than failing the whole atlas.
        var r = [CGRect](repeating: .null, count: n)
        var x = 0, y = 0
        for i in 0..<n {
            let w = min(widths[i], Self.pageWidth)
            if x + w > Self.pageWidth { x = 0; y += rowPx }
            if y + rowPx > Self.maxHeight { y -= rowPx; break }   // that new shelf doesn't fit
            r[i] = CGRect(x: x, y: y, width: w, height: rowPx)
            x += w
        }
        let W = Self.pageWidth
        let H = max(rowPx, y + rowPx)
        missing = r.reduce(0) { $0 + ($1.isNull ? 1 : 0) }
        let bytes = W * H
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 128)
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        // Pass 2 (parallel by shelf): draw glyph coverage into the alpha buffer.
        let shelves = H / rowPx
        let descent = -font.descender
        // Shelf s draws into its own rows of buf; lines and rects are read-only here.
        let packed = r, draw = Disjoint((buf: buf, lines: lines))
        DispatchQueue.concurrentPerform(iterations: shelves) { s in
            let buf = draw.value.buf, lines = draw.value.lines, r = packed
            let base = buf + s * rowPx * W
            guard let ctx = CGContext(data: base, width: W, height: rowPx, bitsPerComponent: 8, bytesPerRow: W,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            ctx.setShouldSmoothFonts(false)
            for i in 0..<n where !r[i].isNull && Int(r[i].minY) / rowPx == s {
                ctx.textPosition = CGPoint(x: r[i].minX / scale + 1, y: descent + 1)
                if let l = lines[i] { CTLineDraw(l, ctx) }
            }
        }
        // A CGImage can't be created directly in alpha-only format; an alpha-only bitmap
        // context can, and makeImage() gives us the right image type (one copy, once).
        defer { buf.deallocate() }
        guard let full = CGContext(data: buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let img = full.makeImage() else { return nil }
        image = img
        rects = r
        width = W
        height = H
    }

    /// Whether item `i`'s title is in the atlas.
    func has(_ i: Int) -> Bool { i >= 0 && i < rects.count && !rects[i].isNull }

    /// Size in points of item `i`'s title.
    func size(_ i: Int) -> CGSize {
        guard has(i) else { return .zero }
        return CGSize(width: rects[i].width / scale, height: lineHeight)
    }

    /// Unit rect for CALayer.contentsRect (y down within the image).
    func contentsRect(_ i: Int) -> CGRect {
        let p = rects[i]
        return CGRect(x: p.minX / CGFloat(width), y: p.minY / CGFloat(height),
                      width: p.width / CGFloat(width), height: p.height / CGFloat(height))
    }

    var count: Int { rects.count }
}
