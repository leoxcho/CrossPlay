import Foundation
import AppKit

@main struct DependencyValidation {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw HostError.message("FAIL: " + message) }
        print("PASS: " + message)
    }
    static func pe(_ machine: UInt16 = 0x8664) -> Data {
        var d = Data(repeating: 0, count: 512)
        d[0] = 77; d[1] = 90; d[60] = 64; d[64] = 80; d[65] = 69
        d[68] = UInt8(machine & 255); d[69] = UInt8(machine >> 8)
        return d
    }
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CrossPlayDependencyTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("Support")
        let manager = GameDependencyManager(support: support, cache: root.appendingPathComponent("Cache"))
        let exe = root.appendingPathComponent("game.exe")
        try (pe() + Data("vcruntime140_1.dll MSVCR120.dll msvcp110.dll msvcr100.dll".utf8)).write(to: exe)
        let info = try GameInfo.inspect(exe)
        try check(manager.requirements(info).count == 4, "bounded sample detects every supported family including v14 _1")
        let x86 = GameInfo(url: exe, architecture: "x86 Windows (unsupported)", graphics: "", imports: ["msvcr120.dll"])
        try check(manager.requirements(x86).first?.id == "vc-2013-x86", "x86 requirement independent of x64")
        let v14 = GameDependencyManager.catalog.first { $0.id == "vc-v14-x64" }!
        let prefixA = root.appendingPathComponent("PrefixA")
        let prefixB = root.appendingPathComponent("PrefixB")
        try check(!manager.verified(v14, prefix: prefixA, imports: info.imports), "missing prefix requests install")
        try check(!fm.fileExists(atPath: support.path) && !fm.fileExists(atPath: prefixA.path), "read-only preflight / cancellation creates no metadata, cache or prefix")
        for dll in v14.dlls + ["vcruntime140_1.dll"] {
            let file = prefixA.appendingPathComponent("drive_c/windows/system32/" + dll)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pe().write(to: file)
        }
        try check(manager.verified(v14, prefix: prefixA, imports: info.imports), "native architecture-matched DLLs satisfy dependency")
        try manager.remember(v14, info: info, runtimeID: "runtime-A", prefix: prefixA, success: true, hash: "test", detail: nil)
        let reloaded = GameDependencyManager(support: support)
        try check(try reloaded.records().first?.runtimeID == "runtime-A", "installation persists with runtime/prefix association")
        try check(reloaded.verified(v14, prefix: prefixA, imports: info.imports), "second preflight requires no reinstall")
        try check(!reloaded.verified(v14, prefix: prefixB), "another runtime-specific prefix independently missing")
        try fm.removeItem(at: prefixA.appendingPathComponent("drive_c/windows/system32/vcruntime140_1.dll"))
        try check(try reloaded.status(v14, info: info, runtimeID: "runtime-A", prefix: prefixA) == "Needs repair", "metadata mismatch becomes repair")
        let builtin = prefixA.appendingPathComponent("drive_c/windows/system32/vcruntime140.dll")
        try (pe() + Data("Wine builtin DLL".utf8)).write(to: builtin)
        try check(!GameDependencyManager.nativeDLL(builtin, architecture: "x64"), "Wine builtin is not confirmed Microsoft dependency")
        try pe(0x14c).write(to: builtin)
        try check(!GameDependencyManager.nativeDLL(builtin, architecture: "x64"), "wrong DLL architecture rejected")
        try check(!GameDependencyManager.official(URL(string: "https://download.microsoft.com.evil.test/a")!), "lookalike source rejected")
        try manager.remember(v14, info: info, runtimeID: "runtime-B", prefix: prefixB, success: false, hash: nil, detail: "test failure")
        try check(try manager.records().last?.installedAt == nil, "failed install never gets installation date")
        var saved = LibraryGame(path: exe.path); saved.dependencyRequirements = [v14.id]; saved.successfulRuntime = "runtime-A"
        let decoded = try JSONDecoder().decode(LibraryGame.self, from: JSONEncoder().encode(saved))
        try check(decoded.dependencyRequirements == saved.dependencyRequirements && decoded.successfulRuntime == "runtime-A", "library requirements and successfulRuntime persist separately")
        // Descriptor and name beyond 8 MiB exercise RVA reads, not sampling.
        let far = root.appendingPathComponent("far-import.exe")
        var header = pe(); header[70] = 1; header[84] = 240; header[88] = 0x0b; header[89] = 2
        func put(_ n: Int, _ value: Int) { for i in 0..<4 { header[n+i] = UInt8((value >> (i*8)) & 255) } }
        put(208, 0x1000); put(212, 40)
        put(340, 0x1000); put(344, 4096); put(348, 9*1024*1024)
        try header.write(to: far)
        let h = try FileHandle(forWritingTo: far); try h.seek(toOffset: 9*1024*1024)
        var descriptor = Data(repeating: 0, count: 256); descriptor[12] = 0x80; descriptor[13] = 0x10
        descriptor.replaceSubrange(128..<141, with: Data("msvcp120.dll\0\0".utf8))
        try h.write(contentsOf: descriptor); try h.close()
        try check(GameInfo.peImports(far).contains("msvcp120.dll"), "bounded RVA import read beyond sample")
        if CommandLine.arguments.contains("--prompt-test") {
            let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching(); app.activate(ignoringOtherApps: true)
            let before = try Data(contentsOf: manager.stateURL)
            let response = DependencyPrompts.required([v14], prefix: prefixB, runtimeID: "runtime-B").runModal()
            try check(response == .alertSecondButtonReturn, "native missing-dependency prompt cancelled")
            try check(try Data(contentsOf: manager.stateURL) == before && !fm.fileExists(atPath: prefixB.path) && !fm.fileExists(atPath: manager.cache.path), "native cancellation preserves metadata, prefix and cache")
        }
        if CommandLine.arguments.contains("--real-install") || CommandLine.arguments.contains("--real-install-all") {
            let liveSupport = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossPlay")
            let registry = RuntimeRegistry(applicationSupport: liveSupport)
            guard let runtime = registry.runtime(id: "crossover-26.2-gptk-4.0b2") else { throw HostError.message("Test runtime unavailable") }
            let host = ExecutionHost(root: URL(fileURLWithPath: runtime.runtimePath), storage: support, registry: registry)
            host.runtimeID = runtime.runtimeID
            host.prefixOverride = root.appendingPathComponent("DisposableMicrosoftTest")
            host.log = { print($0, terminator: "") }
            var result: Result<Void, Error>?
            Task { @MainActor in
                do {
                    let definitions = CommandLine.arguments.contains("--real-install-all") ? GameDependencyManager.catalog : [v14]
                    for definition in definitions {
                        print("INSTALLING DISPOSABLE: " + definition.id)
                        let installer = try await manager.download(definition)
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            do { try manager.install(definition, installer: installer, info: GameInfo(url: exe, architecture: "x86-64 Windows", graphics: "", imports: []), host: host) { outcome in continuation.resume(with: outcome) } }
                            catch { continuation.resume(throwing: error) }
                        }
                        try check(manager.verified(definition, prefix: host.prefixOverride!), "real install " + definition.id)
                    }
                    // A harmless Windows command verifies launch after prerequisites using the same host/prefix.
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        host.finished = { code in
                            if code == 0 { continuation.resume() }
                            else { continuation.resume(throwing: HostError.message("Post-install test command failed")) }
                        }
                        do { try host.launch(GameInfo(url: host.prefixOverride!.appendingPathComponent("drive_c/windows/system32/cmd.exe"), architecture: "x86-64 Windows", graphics: "", imports: []), arguments: ["/c", "exit", "0"], variables: [:]) }
                        catch { continuation.resume(throwing: error) }
                    }
                    try check(host.runtimeID == runtime.runtimeID && host.prefix(for: info).path == host.prefixOverride!.path, "post-install launch keeps original runtime ID and prefix")
                    result = .success(())
                } catch { result = .failure(error) }
            }
            let deadline = Date().addingTimeInterval(480)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            guard let result else { throw HostError.message("Disposable installer timed out at " + root.path) }
            try result.get()
            try check(manager.verified(v14, prefix: host.prefixOverride!), "official Microsoft v14 x64 installed and verified in disposable prefix")
            try check(try manager.records().contains { $0.runtimeID == runtime.runtimeID && $0.status == "installed" }, "real installation remembered")
            try check(manager.requirements(info).filter { $0.id == v14.id && !manager.verified($0, prefix: host.prefixOverride!, imports: ["vcruntime140.dll"]) }.isEmpty, "second launch preflight skips real installed v14")
        }
        print("TEST ARTIFACTS: " + root.path)
        print("ALL DEPENDENCY CHECKS PASSED")
    }
}
