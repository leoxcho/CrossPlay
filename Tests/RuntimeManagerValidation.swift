import Foundation
import CryptoKit

@main struct RuntimeManagerValidation {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw HostError.message("FAIL: " + message) }
        print("PASS: " + message)
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { print("PASS: " + message + " (" + error.localizedDescription + ")"); return }
        throw HostError.message("FAIL: " + message)
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CrossPlayRuntimeTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("Support")
        let source = root.appendingPathComponent("SelectedRuntime")
        for file in ["bin/wine64", "bin/wineserver", "AppleGraphics/d3d11.dll", "AppleGraphics/dxgi.dll", "AppleGraphics/d3d12.dll", "lib/external/D3DMetal.framework/Versions/A/D3DMetal"] {
            let path = source.appendingPathComponent(file)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture component \(file)".utf8).write(to: path)
            if file.hasPrefix("bin/") { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path) }
        }
        let registry = RuntimeRegistry(applicationSupport: support)
        let a = try registry.install(source: source, version: "4.0b2", name: "GPTK 4.0b2")
        let host = ExecutionHost(root: source, storage: support, registry: registry)
        host.runtimeID = a.runtimeID
        let exe = root.appendingPathComponent("OriginalGame/game.exe")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("untouched original Windows game".utf8); try original.write(to: exe)
        let info = GameInfo(url: exe, architecture: "x86-64 Windows", graphics: "fixture", imports: [])
        let prefixA = host.prefix(for: info)
        try fm.createDirectory(at: prefixA, withIntermediateDirectories: true)
        let marker = prefixA.appendingPathComponent("CrossPlayRuntime.txt")
        try a.runtimeID.write(to: marker, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: marker)
        var game = LibraryGame(path: exe.path); game.title = "Fixture Game"; game.runtimeID = a.runtimeID; game.successfulRuntime = a.runtimeID
        let libraryURL = support.appendingPathComponent("Library.json")
        try JSONEncoder().encode([game]).write(to: libraryURL)
        let b = try registry.install(source: source, version: "4.1", name: "GPTK 4.1")
        try check(a.runtimeID != b.runtimeID && a.runtimePath != b.runtimePath && registry.runtimes.count == 2, "runtime generations coexist")
        try check(try Data(contentsOf: marker) == before, "install preserves existing prefix marker")
        host.runtimeID = b.runtimeID
        try check(try host.selectedRuntimeRoot().path == b.runtimePath, "dynamic runtime executes its registered tree")
        let prefixB = host.prefix(for: info)
        try check(prefixA != prefixB, "independent prefix per immutable runtime ID")
        host.prefixOverride = prefixA
        try rejects("mismatched override rejected before running Wine") { try host.launch(info, arguments: [], variables: [:]) }
        try check(try Data(contentsOf: marker) == before, "rejected launch leaves old marker intact")
        host.prefixOverride = nil; host.runtimeID = a.runtimeID
        try check(host.prefix(for: info).path == prefixA.path, "switch back reconnects existing prefix")
        game.prefix = prefixA.path
        game.selectRuntime(b.runtimeID)
        try check(game.prefix == nil && game.successfulRuntime == a.runtimeID && !game.verifiedWorking, "selection preserves successful runtime and detaches old override")
        game.selectRuntime(a.runtimeID)
        try check(game.prefix == prefixA.path && game.verifiedWorking, "known-good override and verification return when selected again")
        try rejects("removal blocked by library and retained prefix") { try registry.remove(runtimeID: a.runtimeID) }
        var usingSuccessful = game; usingSuccessful.runtimeID = b.runtimeID
        try JSONEncoder().encode([usingSuccessful]).write(to: libraryURL)
        try check(try registry.dependencies(for: a.runtimeID).contains("Game: Fixture Game"), "successful runtime remains a dependency after switching")
        try registry.recordWrapper(path: root.appendingPathComponent("Offline/Game.app").path, runtimeID: b.runtimeID, gameName: "Offline Wrapper")
        try rejects("wrapper dependency survives disconnected volume") { try registry.remove(runtimeID: b.runtimeID) }
        let library = LibraryModel(applicationSupport: support)
        try library.removeFromLibrary(usingSuccessful)
        try check(library.games.isEmpty && (try JSONDecoder().decode([LibraryGame].self, from: Data(contentsOf: libraryURL))).isEmpty, "library removal persists only removed entry")
        try check(try Data(contentsOf: exe) == original && Data(contentsOf: marker) == before, "library removal preserves original game and prefix")
        let reload = RuntimeRegistry(applicationSupport: support)
        try check(reload.runtimes.count == 2 && !(try reload.dependencies(for: b.runtimeID)).isEmpty, "registry and wrapper dependencies reload")
        let c = try reload.install(source: source, version: "4.2", name: "GPTK 4.2")
        try reload.remove(runtimeID: c.runtimeID)
        try check(reload.runtime(id: c.runtimeID) == nil && fm.fileExists(atPath: c.runtimePath), "unused runtime removal preserves payload")
        // Preserve the grandfathered legacy bottle whose immutable marker matches.
        let legacy = support.appendingPathComponent("Prefixes/" + info.key + "-selected-wine77-gptk4")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let knownID = "crossover-26.2-gptk-4.0b2"
        try knownID.write(to: legacy.appendingPathComponent("CrossPlayRuntime.txt"), atomically: true, encoding: .utf8)
        try "selected-wine77-gptk4".write(to: source.appendingPathComponent("RuntimeIdentity.txt"), atomically: true, encoding: .utf8)
        host.runtimeID = knownID
        try check(host.prefix(for: info).path == legacy.path, "grandfathered Crash-style matching legacy bottle preserved")
        try rejects("incomplete Apple graphics-only folder rejected") { _ = try reload.install(source: source.appendingPathComponent("lib/external"), version: "4.3", name: "Incomplete") }
        let link = source.appendingPathComponent("external-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: exe)
        try rejects("runtime with external symlink rejected") { _ = try reload.install(source: source, version: "4.3", name: "External link") }
        try fm.removeItem(at: link)
        let corrupted = root.appendingPathComponent("Corrupted")
        try fm.createDirectory(at: corrupted, withIntermediateDirectories: true)
        let corruptURL = corrupted.appendingPathComponent("Runtimes.json")
        try Data("broken registry".utf8).write(to: corruptURL)
        try rejects("corrupt registry fails closed") { _ = try RuntimeRegistry(applicationSupport: corrupted).install(source: source, version: "4.4", name: "Blocked") }
        try check(try String(contentsOf: corruptURL, encoding: .utf8) == "broken registry", "corrupt registry never overwritten")
        print("ALL RUNTIME MANAGER FIXTURE CHECKS PASSED; no real games launched")
    }
}
