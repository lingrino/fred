import AppKit

/// Development benchmark (`fredctl glassbench`): what does each backdrop cost on show
/// (window becomes key) and on resize (result count changes)? Builds throwaway panels
/// off-screen, times AppKit's display pass + the commit for each variant.
@MainActor
enum GlassBench {
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    enum Variant: String, CaseIterable { case multi, singleResize, singleMasked, vibrancy }

    static func run(cycles: Int = 6) -> String {
        var out = "variant          show p50   show max   resize p50  resize max  (µs; display+commit)\n"
        for v in Variant.allCases { out += measure(v, cycles: cycles) + "\n" }
        return out
    }

    static func measure(_ v: Variant, cycles: Int) -> String {
        let w: CGFloat = 680, maxH: CGFloat = 498
        let heights: [CGFloat] = [60, 114, 162, 210, 258, 306]
        let p = Panel(contentRect: NSRect(x: -4000, y: -4000, width: w, height: maxH),
                      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none
        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: maxH))
        root.wantsLayer = true
        p.contentView = root

        var setHeight: (CGFloat) -> Void = { _ in }
        switch v {
        case .multi:
            var views: [NSGlassEffectView] = []
            for h in heights {
                let g = NSGlassEffectView(frame: NSRect(x: 0, y: maxH - h, width: w, height: h))
                g.cornerRadius = 24; g.isHidden = true
                root.addSubview(g); views.append(g)
            }
            var cur: NSGlassEffectView?
            setHeight = { h in
                let g = views[heights.firstIndex(of: h) ?? 0]
                g.isHidden = false; if cur !== g { cur?.isHidden = true }; cur = g
            }
        case .singleResize:
            let g = NSGlassEffectView(frame: NSRect(x: 0, y: maxH - 60, width: w, height: 60))
            g.cornerRadius = 24
            root.addSubview(g)
            setHeight = { h in g.frame = NSRect(x: 0, y: maxH - h, width: w, height: h) }
        case .singleMasked:
            // Glass is always full height (never re-rendered for size); a plain rounded
            // mask layer on a container decides how much of it shows.
            let container = NSView(frame: root.bounds)
            container.wantsLayer = true
            let g = NSGlassEffectView(frame: container.bounds)
            g.cornerRadius = 24
            container.addSubview(g)
            root.addSubview(container)
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            mask.cornerRadius = 24
            mask.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
            container.layer!.mask = mask
            setHeight = { h in mask.frame = CGRect(x: 0, y: maxH - h, width: w, height: h) }
        case .vibrancy:
            let e = NSVisualEffectView(frame: NSRect(x: 0, y: maxH - 60, width: w, height: 60))
            e.material = .popover; e.blendingMode = .behindWindow; e.state = .active
            e.wantsLayer = true; e.layer?.cornerRadius = 24; e.layer?.masksToBounds = true
            root.addSubview(e)
            setHeight = { h in e.frame = NSRect(x: 0, y: maxH - h, width: w, height: h) }
        }

        func commit() -> UInt64 {
            let t = nowNanos()
            p.displayIfNeeded()
            CATransaction.flush()
            return nowNanos() - t
        }

        setHeight(60)
        p.orderFrontRegardless()
        _ = commit()                              // first render (not measured)
        var show: [UInt64] = [], resize: [UInt64] = []
        for i in 0..<cycles {
            // Show: like park → present (become key) → first frame.
            p.orderOut(nil)
            p.orderFrontRegardless()
            _ = commit()
            p.makeKey()
            show.append(commit())
            // Resize: result count changes while typing.
            for h in [heights[(i % 5) + 1], 60] {
                setHeight(h)
                resize.append(commit())
            }
        }
        p.orderOut(nil)
        p.close()
        show.sort(); resize.sort()
        func f(_ ns: UInt64) -> String { String(format: "%9.0f", Double(ns) / 1000) }
        return v.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
            + f(show[show.count / 2]) + "  " + f(show.last!) + "   " + f(resize[resize.count / 2]) + "   " + f(resize.last!)
    }
}
