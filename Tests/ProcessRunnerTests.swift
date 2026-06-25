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

    func testOutputReturnsResult() {
        let output = ProcessRunner.output(["echo", "hello"])
        XCTAssertEqual(output, "hello")
    }

    func testOutputReturnsNilOnFailure() {
        let output = ProcessRunner.output(["false"])
        XCTAssertNil(output)
    }
}
