import Foundation
import Testing
@testable import FredCore

@Suite struct ClipStoreTests {
    func tmpDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fredtest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func addDedupeSearch() {
        let s = ClipStore(dir: nil)
        let t: UInt32 = 1_800_000_000
        s.add(kind: .text, text: "hello world", hash: ClipStore.hash("hello world", kind: .text), app: "com.a", time: t)
        s.add(kind: .text, text: "Second CLIP about Kubernetes", hash: ClipStore.hash("Second CLIP about Kubernetes", kind: .text), app: nil, time: t + 1)
        s.add(kind: .text, text: "hello world", hash: ClipStore.hash("hello world", kind: .text), app: "com.a", time: t + 2)
        #expect(s.count == 2)
        #expect(s.text(1) == "hello world")             // moved to newest
        #expect(s.search("", limit: 10) == [1, 0])
        #expect(s.search("kube", limit: 10) == [0])
        #expect(s.search("clip second", limit: 10) == [0])   // token AND, any order
        #expect(s.search("world xyz", limit: 10).isEmpty)
    }

    @Test func persistReplayDeletePrune() {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t: UInt32 = 1_800_000_000
        do {
            let s = ClipStore(dir: dir, now: t)
            for k in 0..<5 {
                let txt = "item \(k)"
                s.add(kind: .text, text: txt, hash: ClipStore.hash(txt, kind: .text), app: "com.app\(k % 2)", time: t + UInt32(k))
            }
            s.delete(s.index(ofHash: ClipStore.hash("item 2", kind: .text))!)
            s.touch(s.index(ofHash: ClipStore.hash("item 0", kind: .text))!, time: t + 10)
        }
        let s2 = ClipStore(dir: dir, now: t + 20)
        #expect(s2.count == 4)
        #expect((0..<4).map { s2.text($0) } == ["item 1", "item 3", "item 4", "item 0"])
        #expect(s2.app(0) == "com.app1")
        // 91 days later everything is pruned (and the log compacted).
        let s3 = ClipStore(dir: dir, now: t + 91 * 86400)
        #expect(s3.count == 0)
        let s4 = ClipStore(dir: dir, now: t + 91 * 86400)
        #expect(s4.count == 0)
    }

    @Test func unicodeSearch() {
        let s = ClipStore(dir: nil)
        s.add(kind: .text, text: "Café Crème\nnext line", hash: 1, app: nil, time: 1)
        #expect(s.search("creme", limit: 5) == [0])
        #expect(s.search("cafe next", limit: 5) == [0])
    }
}
