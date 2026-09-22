import XCTest
@testable import seahelm

final class TerminalThemeModeTests: XCTestCase {

    // MARK: - Resolution

    // `app` is the only mode that looks at the appearance at all, and it looks
    // exactly once (the latch lives in GhosttyBridge) — here we only pin that
    // the pure resolution passes the appearance through.
    func testAppModeFollowsAppearance() {
        XCTAssertTrue(TerminalThemeMode.app.isDark(appAppearanceIsDark: true))
        XCTAssertFalse(TerminalThemeMode.app.isDark(appAppearanceIsDark: false))
    }

    // The point of pinning: a customer on macOS auto light/dark sets `dark` and
    // the palette stops moving under their agents, whatever the OS does.
    func testPinnedModesIgnoreAppearance() {
        for appearanceIsDark in [true, false] {
            XCTAssertTrue(TerminalThemeMode.dark.isDark(appAppearanceIsDark: appearanceIsDark))
            XCTAssertFalse(TerminalThemeMode.light.isDark(appAppearanceIsDark: appearanceIsDark))
        }
    }

    // MARK: - Parsing

    func testParseKnownValues() {
        XCTAssertEqual(TerminalThemeMode.parse("app"), .app)
        XCTAssertEqual(TerminalThemeMode.parse("dark"), .dark)
        XCTAssertEqual(TerminalThemeMode.parse("light"), .light)
        XCTAssertEqual(TerminalThemeMode.parse("DARK"), .dark)
    }

    // config.json is hand-edited, so a typo must not take the terminal with it.
    func testParseUnknownFallsBackToApp() {
        XCTAssertEqual(TerminalThemeMode.parse(""), .app)
        XCTAssertEqual(TerminalThemeMode.parse("system"), .app)
        XCTAssertEqual(TerminalThemeMode.parse("mocha"), .app)
    }

    // MARK: - Config

    func testConfigDefaultsToApp() {
        XCTAssertEqual(TerminalThemeMode.parse(Config().terminalThemeMode), .app)
    }

    // Every existing config.json predates the key, so the decode has to supply
    // it rather than throwing — and the value it supplies must reproduce the
    // old behaviour (match the app) for anyone who never asked for a pin.
    func testLegacyConfigWithoutKeyDecodesToApp() throws {
        let legacy = #"{"theme_mode":"dark"}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: legacy)
        XCTAssertEqual(TerminalThemeMode.parse(config.terminalThemeMode), .app)
    }

    func testConfigRoundTripsPinnedMode() throws {
        var config = Config()
        config.terminalThemeMode = TerminalThemeMode.dark.rawValue
        let data = try JSONEncoder().encode(config)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("terminal_theme_mode"))
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(TerminalThemeMode.parse(decoded.terminalThemeMode), .dark)
    }
}
