import Foundation
import Testing
@testable import FredCore

/// Golden values for Fred's one-way doors: item keys (learning history refers to them),
/// command ids, clip hashes (image file names) and both log formats. Round-trip tests
/// can't catch a change that is consistent on both sides; these can. If one fails, the
/// change orphans the user's data — migrate it, don't update the expectation.
@Suite struct FormatTests {
    @Test func catalogKeysAreStable() {
        #expect(Catalog.key(.app, "com.apple.Safari") == 0x4b7d_74da_eff6_eee4)
        #expect(Catalog.key(.settings, "displays") == 0xdafa_72b6_3df3_6bb3)
        #expect(Catalog.key(.command, "emptytrash") == 0x227f_6011_8a7d_ac34)
        #expect(Catalog.key(.bookmark, "https://www.example.com/") == 0xb56a_94e5_7f0b_0b48)
        #expect(Catalog.key(.contact, "ABCD-1234:ABPerson") == 0xe290_5477_bea3_1d2a)
        #expect(Catalog.Kind.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
    }

    @Test func commandIdsAreStable() {
        #expect(Command.allCases.map(\.rawValue) == ["emptytrash", "sleep", "lock", "restart", "shutdown",
                                                     "forcequit", "quitfred", "restartfred", "fredsettings"])
    }

    @Test func clipHashesAreStable() {
        #expect(ClipStore.hash("hello", kind: .text) == 0xa430_d846_80aa_bd0b)
        #expect(ClipStore.hash("/tmp/a.png", kind: .files) == 0x312e_0243_c3a2_8704)
        #expect([ClipStore.Kind.text, .image, .files].map(\.rawValue) == [0, 1, 2])
    }

    func tmpDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fredfmt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func learningLogBytes() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learning.log")
        Learning(logURL: url).record(.init(time: 0x0102_0304, key: 0x1122_3344_5566_7788, query: Array("ab".utf8), row: 3))
        let bytes = Array(try Data(contentsOf: url))
        #expect(bytes == Array("FRDL".utf8) + [1, 0, 0, 0]
            + [0x04, 0x03, 0x02, 0x01] + [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11] + [3, 2] + Array("ab".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func clipboardLogBytes() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let s = ClipStore(dir: dir, now: 0x0A0B_0C0D)
            s.add(kind: .text, text: "hi", hash: 0x0102_0304_0506_0708, app: "com.x", time: 0x0A0B_0C0D)
            s.touch(0, time: 0x0A0B_0C0E)
            s.delete(0)
        }
        let bytes = Array(try Data(contentsOf: dir.appendingPathComponent("clipboard.log")))
        let h: [UInt8] = [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
        #expect(bytes == Array("FRDC".utf8) + [1, 0, 0, 0]
            + [1] + [0x0D, 0x0C, 0x0B, 0x0A] + h + [0] + [5, 0] + Array("com.x".utf8) + [2, 0, 0, 0] + Array("hi".utf8)
            + [2] + [0x0E, 0x0C, 0x0B, 0x0A] + h
            + [3] + [0, 0, 0, 0] + h)
    }

    @Test func otherVersionsAreMovedAsideNotOverwritten() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = Data(Array("FRDL".utf8) + [2, 0, 0, 0] + [1, 2, 3, 4, 5])
        let url = dir.appendingPathComponent("learning.log")
        try future.write(to: url)
        let l = Learning(logURL: url)
        #expect(l.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = names.filter { $0.hasPrefix("learning.log.unrecognized-") }
        #expect(aside.count == 1)
        if let a = aside.first { #expect(try Data(contentsOf: dir.appendingPathComponent(a)) == future) }
        #expect(Array(try Data(contentsOf: url)) == EventLog.magic)

        let clip = Data(Array("FRDC".utf8) + [9, 0, 0, 0] + [7, 7, 7])
        try clip.write(to: dir.appendingPathComponent("clipboard.log"))
        #expect(ClipStore(dir: dir).count == 0)
        let clipAside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("clipboard.log.unrecognized-") }
        #expect(clipAside.count == 1)
    }
}
