import XCTest
@testable import seahelm

class ProcessRunnerTests: XCTestCase {
    func testCommandExistsForKnownCommand() {
        XCTAssertTrue(ProcessRunner.commandExists("ls"))
    }

    func testCommandExistsForUnknownCommand() {
        XCTAssertFalse(ProcessRunner.commandExists("definitely_not_a_real_command_12345"))
    }

    func testCommandPathReturnsResolvedExecutablePath() {
        let path = ProcessRunner.commandPath("ls")
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.hasSuffix("/ls") == true)
    }

    func testCommandPathReturnsNilForUnknownCommand() {
        let path = ProcessRunner.commandPath("definitely_not_a_real_command_12345")
        XCTAssertNil(path)
    }

    func testCommandPathsResolvesKnownAndOmitsUnknown() {
        let found = ProcessRunner.commandPaths(["uname", "definitely_not_a_real_command_12345"])
        XCTAssertTrue(found["uname"]?.hasSuffix("/uname") == true)
        XCTAssertNil(found["definitely_not_a_real_command_12345"])
    }

    func testParseCommandPathsIgnoresRcNoise() {
        let m = ProcessRunner.commandPathMarker
        let stdout = "Welcome back!\n[oh-my-zsh] update?\n\n\(m)claude=/Users/x/.local/bin/claude\n\n\(m)gemini=\n"
        XCTAssertEqual(ProcessRunner.parseCommandPaths(stdout), ["claude": "/Users/x/.local/bin/claude"])
    }

    func testOutputReturnsResult() {
        let output = ProcessRunner.output(["echo", "hello"])
        XCTAssertEqual(output, "hello")
    }

    func testOutputReturnsNilOnFailure() {
        let output = ProcessRunner.output(["false"])
        XCTAssertNil(output)
    }
}
