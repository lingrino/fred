import FredCore
import Foundation

// fredbench <command>
//   scan     print what every source finds on this machine (no Contacts: needs the app's grant)
//   bench    micro-benchmarks over the real catalog, compared with Benchmarks/baseline.tsv
//   save     same, then overwrite the baseline
let args = CommandLine.arguments.dropFirst()
switch args.first ?? "bench" {
case "scan":
    let t0 = DispatchTime.now().uptimeNanoseconds
    let apps = AppScanner.scan()
    let t1 = DispatchTime.now().uptimeNanoseconds
    let panes = SettingsScanner.scan()
    let t2 = DispatchTime.now().uptimeNanoseconds
    let bms = ChromeBookmarks.load()
    let t3 = DispatchTime.now().uptimeNanoseconds
    for a in apps { print("app   \(a.name) | file=\(a.fileName) bn=\(a.bundleName ?? "-") id=\(a.bundleID ?? "-") \(a.path)") }
    for p in panes { print("pane  \(p.name) | \(p.bundleID)") }
    for b in bms.prefix(20) { print("bm    \(b.title) | \(b.url)") }
    print("apps=\(apps.count) \((t1-t0)/1000)µs  panes=\(panes.count) \((t2-t1)/1000)µs  bookmarks=\(bms.count) \((t3-t2)/1000)µs")
case "save":
    Bench.run(save: true)
default:
    Bench.run(save: false)
}
