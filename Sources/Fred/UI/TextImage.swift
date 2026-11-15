import AppKit

/// Renders one line of text into a CGImage sized to the text (not the row), for use as
/// a CALayer's contents. Rows and the query field are pure layer trees: per keystroke
/// the CPU only rasterizes the glyphs that changed, into small bitmaps; pills, icons
/// and the caret are composited by the GPU.
@MainActor
enum TextImage {
    struct Rendered {
        let image: CGImage?
        let size: CGSize          // points
        let baselineFromTop: CGFloat
    }

    /// `maxWidth` truncates with an ellipsis. Colors resolve in `appearance`.
    static func render(_ s: String, font: NSFont, color: NSColor, maxWidth: CGFloat = .greatestFiniteMagnitude,
                       scale: CGFloat, appearance: NSAppearance) -> Rendered {
        var cg: CGColor = NSColor.black.cgColor
        appearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: cg]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > maxWidth {
            let ell = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            if let t = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ell) {
                line = t
                width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }
        let ascent = font.ascender, descent = -font.descender
        let h = (ascent + descent).rounded(.up) + 2
        let w = width.rounded(.up) + 2
        guard w > 2, !s.isEmpty else { return Rendered(image: nil, size: .zero, baselineFromTop: ascent + 1) }
        let pw = Int(w * scale), ph = Int(h * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return Rendered(image: nil, size: .zero, baselineFromTop: ascent + 1) }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.textPosition = CGPoint(x: 1, y: descent + 1)
        CTLineDraw(line, ctx)
        return Rendered(image: ctx.makeImage(), size: CGSize(width: w, height: h), baselineFromTop: ascent + 1)
    }

    /// Offset of UTF-16 index `i` within an unrendered line (caret/selection geometry).
    static func line(_ s: String, font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
    }
}

extension CALayer {
    /// A layer with every implicit animation disabled (Fred never animates layout).
    static func still() -> CALayer {
        let l = CALayer()
        l.actions = ["contents": NSNull(), "contentsRect": NSNull(), "position": NSNull(), "bounds": NSNull(),
                     "frame": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(), "opacity": NSNull(),
                     "cornerRadius": NSNull(), "sublayers": NSNull()]
        return l
    }
}
