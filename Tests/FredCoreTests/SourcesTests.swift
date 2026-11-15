import Foundation
import Testing
@testable import FredCore

@Suite struct SourcesTests {
    @Test func chromeBookmarksParse() {
        let json = """
        {"checksum":"x","roots":{
          "bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[
            {"type":"url","name":"Team wiki","url":"https://wiki.example.com/team"},
            {"type":"folder","name":"Work","children":[
              {"type":"url","name":"","url":"https://metrics.example.com/d/abc"},
              {"type":"url","name":"Bookmarklet","url":"javascript:alert(1)"}
            ]}
          ]},
          "other":{"type":"folder","name":"Other","children":[
            {"type":"url","name":"notebook","url":"https://notebook.example/"}
          ]},
          "synced":{"type":"folder","name":"Mobile","children":[]}
        },"version":1}
        """
        let b = ChromeBookmarks.parse(Data(json.utf8))
        #expect(b.map(\.title) == ["Team wiki", "https://metrics.example.com/d/abc", "notebook"])
        #expect(b[1].folder == "Work")
        let items = ChromeBookmarks.items(b)
        #expect(items[0].secondary == ["wiki.example"])
        #expect(items[2].secondary == [])        // host "notebook" == title: no duplicate entry
        #expect(items[0].key == Catalog.key(.bookmark, "https://wiki.example.com/team"))
    }

    @Test func commandsHaveStableKeys() {
        let items = Command.items()
        #expect(items.contains { $0.title == "Empty Trash" && $0.aliases.contains("emptytrash") })
        // Raw values are learning-key payloads: never rename.
        #expect(Command(rawValue: "shutdown") == .shutDown)
    }

    @Test func settingsNamesLookUserFacing() {
        #expect(!SettingsScanner.isUserFacing("PowerPreferences"))
        #expect(!SettingsScanner.isUserFacing("TimeMachineSettings"))
        #expect(SettingsScanner.isUserFacing("Touch ID & Password"))
        #expect(SettingsScanner.isUserFacing("Keyboard"))
    }
}
