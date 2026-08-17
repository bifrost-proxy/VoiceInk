import Carbon.HIToolbox
import Foundation
import Testing

@testable import VoiceInk

struct GlobalUtilityShortcutTests {
    @Test func highlightedMenuActionsAreGlobalAndStored() {
        let actions = ShortcutAction.globalUtilityActions

        #expect(actions.contains(.copyLastTranscription))
        #expect(actions.contains(.openHistoryWindow))
        #expect(actions.contains(.toggleDockIcon))
        #expect(ShortcutAction.copyLastTranscription.isStored)
        #expect(ShortcutAction.openHistoryWindow.isStored)
        #expect(ShortcutAction.toggleDockIcon.isStored)
        #expect(Set(actions.map(\.storageName)).count == actions.count)
    }

    @Test func highlightedMenuActionsKeepTheirPreviousDefaultKeys() throws {
        let defaults = ShortcutMigration.defaultMenuUtilityShortcuts

        let copy = try #require(defaults[.copyLastTranscription])
        #expect(copy.keyCode == UInt16(kVK_ANSI_C))
        #expect(copy.modifierFlags == [.shift, .command])

        let history = try #require(defaults[.openHistoryWindow])
        #expect(history.keyCode == UInt16(kVK_ANSI_H))
        #expect(history.modifierFlags == [.shift, .command])

        let dock = try #require(defaults[.toggleDockIcon])
        #expect(dock.keyCode == UInt16(kVK_ANSI_D))
        #expect(dock.modifierFlags == [.shift, .command])
    }

    @Test func olderBackupsDecodeWithoutNewShortcutFields() throws {
        let backup = try JSONDecoder().decode(GeneralBackup.self, from: Data("{}".utf8))

        #expect(backup.copyLastTranscriptionShortcut == nil)
        #expect(backup.toggleDockIconShortcut == nil)
    }
}
