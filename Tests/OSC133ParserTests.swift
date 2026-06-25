import XCTest
@testable import seahelm

final class OSC133ParserTests: XCTestCase {
    var parser: OSC133Parser!

    override func setUp() {
        parser = OSC133Parser()
    }

    // MARK: - Basic Marker Parsing

    func testPromptStart_BEL() {
        // ESC ] 1 3 3 ; A BEL
        let data = Data([0x1b, 0x5d] + "133;A".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .promptStart)
        XCTAssertNil(markers[0].exitCode)
    }

    func testPromptEnd_BEL() {
        let data = Data([0x1b, 0x5d] + "133;B".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .promptEnd)
    }

    func testPreExec_BEL() {
        let data = Data([0x1b, 0x5d] + "133;C".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .preExec)
    }

    func testPostExec_BEL() {
        let data = Data([0x1b, 0x5d] + "133;D".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .postExec)
        XCTAssertNil(markers[0].exitCode)
    }

    // MARK: - ST Terminator (ESC \)

    func testPromptStart_ST() {
        // ESC ] 1 3 3 ; A ESC \
        let data = Data([0x1b, 0x5d] + "133;A".utf8 + [0x1b, 0x5c])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .promptStart)
    }

    func testPostExec_ST() {
        let data = Data([0x1b, 0x5d] + "133;D".utf8 + [0x1b, 0x5c])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .postExec)
    }

    // MARK: - Exit Code Parsing

    func testPostExec_ExitCodeZero() {
        let data = Data([0x1b, 0x5d] + "133;D;0".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .postExec)
        XCTAssertEqual(markers[0].exitCode, 0)
    }

    func testPostExec_ExitCodeNonZero() {
        let data = Data([0x1b, 0x5d] + "133;D;1".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].exitCode, 1)
    }

    func testPostExec_ExitCodeWithPrefix() {
        let data = Data([0x1b, 0x5d] + "133;D;exitcode=127".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].exitCode, 127)
    }

    // MARK: - Multiple Markers in One Feed

    func testMultipleMarkers() {
        var bytes: [UInt8] = []
        bytes += [0x1b, 0x5d] + "133;A".utf8 + [0x07]
        bytes += [0x1b, 0x5d] + "133;B".utf8 + [0x07]
        bytes += [0x1b, 0x5d] + "133;C".utf8 + [0x07]
        let markers = parser.feed(Data(bytes))
        XCTAssertEqual(markers.count, 3)
        XCTAssertEqual(markers[0].kind, .promptStart)
        XCTAssertEqual(markers[1].kind, .promptEnd)
        XCTAssertEqual(markers[2].kind, .preExec)
    }

    // MARK: - Incremental Feed

    func testIncrementalFeed() {
        // Feed bytes one at a time
        var allMarkers: [ParsedMarker] = []
        let bytes: [UInt8] = [0x1b, 0x5d] + Array("133;A".utf8) + [0x07]
        for byte in bytes {
            allMarkers += parser.feed(Data([byte]))
        }
        XCTAssertEqual(allMarkers.count, 1)
        XCTAssertEqual(allMarkers[0].kind, .promptStart)
    }

    // MARK: - Mixed Content

    func testMarkersWithSurroundingText() {
        var bytes: [UInt8] = Array("hello world".utf8)
        bytes += [0x1b, 0x5d] + Array("133;C".utf8) + [0x07]
        bytes += Array("more text".utf8)
        let markers = parser.feed(Data(bytes))
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .preExec)
    }

    // MARK: - Invalid / Malformed

    func testNonOSC133_Ignored() {
        // OSC 7 (not 133)
        let data = Data([0x1b, 0x5d] + "7;file://host/path".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertTrue(markers.isEmpty)
    }

    func testInvalidMarkerKind_Ignored() {
        let data = Data([0x1b, 0x5d] + "133;Z".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertTrue(markers.isEmpty)
    }

    func testEmptyOSC_Ignored() {
        let data = Data([0x1b, 0x5d, 0x07])
        let markers = parser.feed(data)
        XCTAssertTrue(markers.isEmpty)
    }

    // MARK: - Command Line Parsing

    func testPreExec_WithCmdline() {
        let data = Data([0x1b, 0x5d] + "133;C;cmdline=brew install ffmpeg".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .preExec)
        XCTAssertEqual(markers[0].commandLine, "brew install ffmpeg")
    }

    func testPreExec_WithCmdlineUrl() {
        let data = Data([0x1b, 0x5d] + "133;C;cmdline_url=brew%20install%20ffmpeg".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].commandLine, "brew install ffmpeg")
    }

    func testPreExec_NoCmdline() {
        let data = Data([0x1b, 0x5d] + "133;C".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertNil(markers[0].commandLine)
    }

    func testPreExec_EmptyCmdline() {
        let data = Data([0x1b, 0x5d] + "133;C;cmdline=".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].commandLine, "")
    }

    func testPreExec_CmdlineUrlEncoded() {
        let data = Data([0x1b, 0x5d] + "133;C;cmdline_url=echo%20hello%3bworld".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].commandLine, "echo hello;world")
    }

    func testLongCmdline_WithinBuffer() {
        // A command longer than the old 256 limit but under 1024
        let longCmd = "docker run --rm -v /path/to/dir:/app -e FOO=bar -e BAZ=qux --name my-container-name-that-is-very-long ubuntu:22.04 bash -c 'echo hello world && sleep 100 && echo done done done done done done done done done done done done done done done'"
        let data = Data([0x1b, 0x5d] + "133;C;cmdline=\(longCmd)".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].commandLine, longCmd)
    }

    // MARK: - Reset

    func testReset() {
        // Start an OSC sequence
        _ = parser.feed(Data([0x1b, 0x5d] + Array("133".utf8)))
        parser.reset()
        // Now feed a complete sequence — should parse fine
        let data = Data([0x1b, 0x5d] + "133;A".utf8 + [0x07])
        let markers = parser.feed(data)
        XCTAssertEqual(markers.count, 1)
    }
}

// MARK: - ShellState Tests

final class ShellStateTests: XCTestCase {
    func testPhaseTransitions() {
        let state = ShellState()

        state.addMarker(ParsedMarker(kind: .promptStart, exitCode: nil, commandLine: nil))
        XCTAssertEqual(state.phase, .prompt)

        state.addMarker(ParsedMarker(kind: .promptEnd, exitCode: nil, commandLine: nil))
        XCTAssertEqual(state.phase, .input)

        state.addMarker(ParsedMarker(kind: .preExec, exitCode: nil, commandLine: nil))
        XCTAssertEqual(state.phase, .running)

        state.addMarker(ParsedMarker(kind: .postExec, exitCode: 0, commandLine: nil))
        XCTAssertEqual(state.phase, .output)
        XCTAssertEqual(state.lastExitCode, 0)
    }

    func testExitCodePersists() {
        let state = ShellState()
        state.addMarker(ParsedMarker(kind: .postExec, exitCode: 42, commandLine: nil))
        XCTAssertEqual(state.lastExitCode, 42)

        // Next prompt cycle doesn't clear exit code unless new postExec
        state.addMarker(ParsedMarker(kind: .promptStart, exitCode: nil, commandLine: nil))
        XCTAssertEqual(state.lastExitCode, 42)
    }

    func testReset() {
        let state = ShellState()
        state.addMarker(ParsedMarker(kind: .preExec, exitCode: nil, commandLine: nil))
        state.reset()
        XCTAssertEqual(state.phase, .output)
        XCTAssertNil(state.lastExitCode)
    }

    func testLastCommandLineFromPreExec() {
        let state = ShellState()
        state.addMarker(ParsedMarker(kind: .preExec, exitCode: nil, commandLine: "brew install ffmpeg"))
        XCTAssertEqual(state.lastCommandLine, "brew install ffmpeg")
        XCTAssertEqual(state.phase, .running)
    }

    func testLastCommandLinePersistsAcrossCycles() {
        let state = ShellState()
        state.addMarker(ParsedMarker(kind: .preExec, exitCode: nil, commandLine: "brew install"))
        state.addMarker(ParsedMarker(kind: .postExec, exitCode: 0, commandLine: nil))
        state.addMarker(ParsedMarker(kind: .promptStart, exitCode: nil, commandLine: nil))
        // commandLine persists until next preExec
        XCTAssertEqual(state.lastCommandLine, "brew install")
    }

    func testResetClearsCommandLine() {
        let state = ShellState()
        state.addMarker(ParsedMarker(kind: .preExec, exitCode: nil, commandLine: "brew install"))
        state.reset()
        XCTAssertNil(state.lastCommandLine)
    }
}

// Make MarkerKind Equatable for tests
extension MarkerKind: Equatable {}
extension ShellPhase: Equatable {}
