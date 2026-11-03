import Testing
@testable import BoothCore

@Suite("Menu bar placement")
struct MenuBarPlacementTests {
    /// A 1512-point MacBook display's menu bar, right to left: the clock, Control Centre, Now
    /// Playing, a battery app, Wi-Fi, then two more apps.
    let icons: [(minX: Double, maxX: Double)] = [
        (1379, 1514), (1351, 1379), (1332, 1351), (1288, 1332), (1264, 1288), (1246, 1264), (1209, 1246),
    ]

    /// What macOS keeps for an icon drawn with this right edge.
    func kept(_ maxX: Double) -> Double { 1512 - maxX - MenuBarPlacement.inset }

    @Test func goesFourthAfterTheClockAndControlCentre() throws {
        let position = try #require(MenuBarPlacement.preferredPosition(icons: icons, screenMaxX: 1512))
        // Between Wi-Fi's position and the next app's, half an icon from either.
        #expect(position == 218)
        #expect(position > kept(1288) + 10 && position < kept(1264) - 10)
    }

    /// Measured with a test icon on macOS 26: aiming at Wi-Fi's middle, here the third icon after
    /// Control Centre, gave 238, and macOS put the icon just left of Wi-Fi.
    @Test func matchesWhatMacOSDid() {
        let measured: [(minX: Double, maxX: Double)] = [
            (1379, 1514), (1351, 1379), (1312, 1331), (1268, 1312), (1244, 1268), (1226, 1244),
        ]
        #expect(MenuBarPlacement.preferredPosition(icons: measured, screenMaxX: 1512) == 238)
    }

    @Test func orderDoesNotMatter() {
        #expect(MenuBarPlacement.preferredPosition(icons: icons.reversed(), screenMaxX: 1512) == 218)
    }

    @Test func aGuessThatLandsFourthStays() {
        var search = MenuBarPlacement.Search(position: 218)
        #expect(search.next(iconsToTheRight: 3, available: 6) == nil)
    }

    /// The case that needed it: Wi-Fi still had its position from before an icon to its right went
    /// away, so the guess landed in front of it.
    @Test func aGuessOneShortMovesOnAnIcon() {
        var search = MenuBarPlacement.Search(position: 218)
        #expect(search.next(iconsToTheRight: 2, available: 6) == 242)
        #expect(search.next(iconsToTheRight: 3, available: 6) == nil)
        #expect(search.position == 242)
    }

    @Test func overshootingHalvesTheGap() {
        var search = MenuBarPlacement.Search(position: 218)
        #expect(search.next(iconsToTheRight: 2, available: 6) == 242)
        #expect(search.next(iconsToTheRight: 4, available: 6) == 230)
        #expect(search.next(iconsToTheRight: 3, available: 6) == nil)
    }

    /// Hidden off the screen, every icon is on its right: it comes back the whole way at once.
    @Test func fromOffTheScreenItComesBack() {
        var search = MenuBarPlacement.Search(position: 400)
        #expect(search.next(iconsToTheRight: 7, available: 7) == 400 - 4 * MenuBarPlacement.Search.step)
    }

    @Test func withFewerIconsAfterAllOfThemIsEnough() {
        var search = MenuBarPlacement.Search(position: 0)
        #expect(search.next(iconsToTheRight: 2, available: 2) == nil)
        var none = MenuBarPlacement.Search(position: 0)
        #expect(none.next(iconsToTheRight: 0, available: 0) == nil)
    }

    @Test func itGivesUpAfterEightTries() {
        var search = MenuBarPlacement.Search(position: 100)
        var tries = 0
        // A menu bar that never reports what it should: the icon stays where the last try put it.
        while search.next(iconsToTheRight: tries % 2 == 0 ? 0 : 6, available: 6) != nil { tries += 1 }
        #expect(tries < MenuBarPlacement.Search.maxTries)
    }

    @Test func withFewerIconsItGoesAfterTheLast() {
        let one = Array(icons.prefix(3))
        #expect(MenuBarPlacement.preferredPosition(icons: one, screenMaxX: 1512) == 1512 - 1341.5 - 18)
        #expect(MenuBarPlacement.preferredPosition(icons: Array(icons.prefix(2)), screenMaxX: 1512) == nil)
        #expect(MenuBarPlacement.preferredPosition(icons: [], screenMaxX: 1512) == nil)
    }
}
