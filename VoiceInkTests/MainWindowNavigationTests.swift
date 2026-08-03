import Combine
import Testing
@testable import VoiceInk

@MainActor
struct MainWindowNavigationTests {
    @Test func reselectingCurrentTabDoesNotPublishAChange() {
        let navigation = MainWindowNavigation.shared
        let originalSelection = navigation.selectedView
        navigation.selectedView = .dashboard
        defer { navigation.selectedView = originalSelection }

        var publishedChangeCount = 0
        let cancellable = navigation.objectWillChange.sink {
            publishedChangeCount += 1
        }

        navigation.navigate(to: .dashboard)
        #expect(publishedChangeCount == 0)

        navigation.navigate(to: .models)
        #expect(publishedChangeCount == 1)

        withExtendedLifetime(cancellable) {}
    }
}
