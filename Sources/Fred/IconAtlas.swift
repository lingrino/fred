import AppKit
import FredCore

/// Every icon Fred can show, pre-rendered once into one bitmap.
///
/// Rows never decode or rasterize anything while you type: an icon is just a
/// `contentsRect` into this shared image (all row layers share one backing store).
/// App and settings-pane icons are rendered in parallel across all cores when the app
/// list changes (≈3 ms/icon single-threaded → a few tens of ms total); static symbol
/// icons (commands, bookmarks, contacts, calculator) occupy the first slots.
///
/// Not a cache: it is part of the index, rebuilt wholesale with it, never invalidated.
final class IconAtlas: @unchecked Sendable {
    static let px = 64                  // slot size in pixels (32 pt @2x)
    static let columns = 16

    let image: CGImage
    let slots: Int
    /// Slot index by key (app/pane path, or a static symbol name).
    private let slotByKey: [String: Int32]

    enum Static: String, CaseIterable {
        case bookmark, contact, calculator, emptyTrash, sleep, lock, restart, shutDown, forceQuit, fred, generic, text, image, files
        case phone, email, address, url, birthday
        var symbol: String {
            switch self {
            case .bookmark: "bookmark.fill"
            case .contact: "person.fill"
            case .calculator: "equal"
            case .emptyTrash: "trash.fill"
            case .sleep: "moon.fill"
            case .lock: "lock.fill"
            case .restart: "arrow.clockwise"
            case .shutDown: "power"
            case .forceQuit: "xmark"
            case .fred: "f.cursive"
            case .generic: "app.dashed"
            case .text: "text.alignleft"
            case .image: "photo"
            case .files: "doc.on.doc.fill"
            case .phone: "phone.fill"
            case .email: "envelope.fill"
            case .address: "house.fill"
            case .url: "link"
            case .birthday: "gift.fill"
            }
        }
        /// Tile color (macOS Settings-style rounded square behind a white glyph).
        var tint: NSColor {
            switch self {
            case .bookmark: .systemBlue
            case .contact: .systemGray
            case .calculator: .systemOrange
            case .emptyTrash, .forceQuit: .systemRed
            case .sleep: .systemIndigo
            case .lock: .systemGray
            case .restart, .shutDown: .systemGray
            case .fred: .systemPurple
            case .generic: .systemGray
            case .text: .systemTeal
            case .image: .systemGreen
            case .files: .systemBlue
            case .phone: .systemGreen
            case .email: .systemBlue
            case .address: .systemBrown
            case .url: .systemIndigo
            case .birthday: .systemPink
            }
        }
    }

    /// Renders statics + one slot per file path (app bundles, settings appexes).
    init(paths: [String]) {
        let statics = Static.allCases
        let total = statics.count + paths.count
        slots = total
        let px = Self.px, cols = Self.columns
        let rows = max(1, (total + cols - 1) / cols)
        let width = cols * px, height = rows * px
        let rowBytes = width * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 128)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: rowBytes * height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        // Each slot is drawn through its own CGContext that windows into the shared buffer,
        // so threads never touch the same pixels.
        func context(slot: Int) -> CGContext {
            let x = (slot % cols) * px
            let y = (slot / cols) * px   // top-down in memory
            let base = buffer + y * rowBytes + x * 4
            let ctx = CGContext(data: base, width: px, height: px, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                space: cs, bitmapInfo: info)!
            ctx.interpolationQuality = .high
            return ctx
        }

        DispatchQueue.concurrentPerform(iterations: total) { slot in
            let ctx = context(slot: slot)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let rect = NSRect(x: 0, y: 0, width: px, height: px)
            if slot < statics.count {
                Self.drawSymbolTile(statics[slot], in: rect)
            } else {
                let icon = NSWorkspace.shared.icon(forFile: paths[slot - statics.count])
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                          hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        let provider = CGDataProvider(dataInfo: nil, data: buffer, size: rowBytes * height) { _, data, _ in
            data.deallocate()
        }!
        image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                        space: cs, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                        shouldInterpolate: true, intent: .defaultIntent)!
        var map: [String: Int32] = [:]
        for (i, s) in statics.enumerated() { map["@" + s.rawValue] = Int32(i) }
        for (i, p) in paths.enumerated() { map[p] = Int32(statics.count + i) }
        slotByKey = map
        subimages = (0..<total).map { slot in
            image.cropping(to: CGRect(x: (slot % cols) * px, y: (slot / cols) * px, width: px, height: px))!
        }
    }

    /// Per-slot sub-images; `CGImage.cropping` shares the atlas pixels (no copy).
    private var subimages: [CGImage] = []

    func image(_ slot: Int32) -> CGImage? {
        slot >= 0 && Int(slot) < subimages.count ? subimages[Int(slot)] : nil
    }

    func slot(path: String) -> Int32? { slotByKey[path] }
    func slot(_ s: Static) -> Int32 { slotByKey["@" + s.rawValue]! }

    static func drawSymbolTile(_ s: Static, in rect: NSRect) {
        let inset = rect.insetBy(dx: rect.width * 0.09, dy: rect.height * 0.09)
        let path = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.225, yRadius: inset.width * 0.225)
        s.tint.setFill()
        path.fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: rect.height * 0.42, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let img = NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let sz = img.size
            let r = NSRect(x: inset.midX - sz.width / 2, y: inset.midY - sz.height / 2, width: sz.width, height: sz.height)
            img.draw(in: r)
        }
    }
}
