import XCTest
@testable import Jarvis

@MainActor
final class AgentToolsTests: XCTestCase {

    // MARK: - Helpers

    private func makeContext(allowedRoots: [URL]) -> AgentContext {
        AgentContext(allowedRoots: allowedRoots, audit: AgentAuditLog())
    }

    private func tempDir(name: String = UUID().uuidString) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-agent-\(name)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Workspace boundary

    func testWorkspaceBoundaryBlocksOutsideRoots() async throws {
        let allowed = tempDir(name: "allowed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: allowed) }

        let ctx = makeContext(allowedRoots: [allowed])
        do {
            _ = try ctx.resolveAndCheck(path: "/tmp/jarvis-evil-\(UUID().uuidString)")
            XCTFail("Expected outsideWorkspace")
        } catch let err as AgentError {
            if case .outsideWorkspace = err { /* OK */ } else { XCTFail("wrong error") }
        }
    }

    func testWorkspaceBoundaryAllowsInsidePaths() async throws {
        let allowed = tempDir(name: "allowed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: allowed) }

        let inside = allowed.appendingPathComponent("nested/file.txt").path
        let ctx = makeContext(allowedRoots: [allowed])
        let resolved = try ctx.resolveAndCheck(path: inside)
        XCTAssertEqual(resolved.path, inside)
    }

    // MARK: - read_file

    func testReadFileReturnsUTF8Contents() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hello.txt")
        try "hej jarvis\nlinje 2".write(to: path, atomically: true, encoding: .utf8)

        let ctx = makeContext(allowedRoots: [dir])
        let result = try await ReadFileTool.tool.execute(["path": path.path], ctx)
        XCTAssertTrue(result.contains("hej jarvis"))
        XCTAssertTrue(result.contains("linje 2"))
    }

    func testReadFileRejectsMissingPath() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = makeContext(allowedRoots: [dir])
        do {
            _ = try await ReadFileTool.tool.execute(["path": dir.appendingPathComponent("missing.txt").path], ctx)
            XCTFail("Expected notFound")
        } catch let err as AgentError {
            if case .notFound = err { /* OK */ } else { XCTFail("wrong error") }
        }
    }

    // MARK: - list_directory

    func testListDirectoryListsEntries() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)

        let ctx = makeContext(allowedRoots: [dir])
        let result = try await ListDirectoryTool.tool.execute(["path": dir.path], ctx)
        XCTAssertTrue(result.contains("a.txt"))
        XCTAssertTrue(result.contains("b.txt"))
        XCTAssertTrue(result.contains("sub"))
    }

    // MARK: - search_files

    func testSearchFilesMatchesGlob() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("skip.txt"), atomically: true, encoding: .utf8)

        let ctx = makeContext(allowedRoots: [dir])
        let result = try await SearchFilesTool.tool.execute(["base": dir.path, "pattern": "*.md"], ctx)
        XCTAssertTrue(result.contains("one.md"))
        XCTAssertTrue(result.contains("two.md"))
        XCTAssertFalse(result.contains("skip.txt"))
    }

    // MARK: - stat_file

    func testStatFileReportsSizeAndType() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("note.md")
        try "hello world".write(to: path, atomically: true, encoding: .utf8)

        let ctx = makeContext(allowedRoots: [dir])
        let result = try await StatFileTool.tool.execute(["path": path.path], ctx)
        XCTAssertTrue(result.contains("type: file"))
        XCTAssertTrue(result.contains("size: 11 bytes"))
    }

    // MARK: - Registry

    func testRegistryHasFourReadOnlyTools() {
        let registry = AgentToolRegistry.shared
        XCTAssertNotNil(registry.tool(named: "read_file"))
        XCTAssertNotNil(registry.tool(named: "list_directory"))
        XCTAssertNotNil(registry.tool(named: "search_files"))
        XCTAssertNotNil(registry.tool(named: "stat_file"))
        // None should require confirmation yet
        XCTAssertFalse(registry.tool(named: "read_file")!.requiresConfirmation)
    }
}
