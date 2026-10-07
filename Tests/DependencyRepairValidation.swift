import Foundation

@main struct DependencyRepairValidation {
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.path.hasPrefix(fm.temporaryDirectory.resolvingSymlinksInPath().path + "/"), root.lastPathComponent.hasPrefix("CrossPlayDependencyTests-") else { throw HostError.message("Repair test requires a disposable fixture directory") }
        let support = root.appendingPathComponent("Support"), prefix = root.appendingPathComponent("DisposableMicrosoftTest")
        let liveSupport = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossPlay")
        let registry = RuntimeRegistry(applicationSupport: liveSupport)
        let runtime = registry.runtime(id: "crossover-26.2-gptk-4.0b2")!
        let marker = try String(contentsOf: prefix.appendingPathComponent("CrossPlayRuntime.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker == runtime.runtimeID else { throw HostError.message("Disposable fixture runtime mismatch") }
        let manager = GameDependencyManager(support: support, cache: root.appendingPathComponent("Cache"))
        let definition = GameDependencyManager.catalog.first { $0.id == "vc-v14-x64" }!
        let info = GameInfo(url: root.appendingPathComponent("game.exe"), architecture: "x86-64 Windows", graphics: "", imports: ["msvcp140.dll"])
        guard manager.verified(definition, prefix: prefix) else { throw HostError.message("Fixture not installed before repair") }
        try fm.removeItem(at: prefix.appendingPathComponent("drive_c/windows/system32/msvcp140.dll"))
        guard try manager.status(definition, info: info, runtimeID: runtime.runtimeID, prefix: prefix) == "Needs repair" else { throw HostError.message("Deleted fixture DLL not marked repair") }
        print("PASS: deleted disposable DLL produces Needs repair")
        let host = ExecutionHost(root: URL(fileURLWithPath: runtime.runtimePath), storage: support, registry: registry)
        host.runtimeID = runtime.runtimeID; host.prefixOverride = prefix; host.log = { print($0, terminator: "") }
        var result: Result<Void, Error>?
        Task { @MainActor in
            do {
                let installer = try await manager.download(definition)
                try manager.install(definition, installer: installer, info: info, host: host, repair: true) { result = $0 }
            } catch { result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(120)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard let result else { throw HostError.message("Repair timed out") }; try result.get()
        guard manager.verified(definition, prefix: prefix), try manager.records().contains(where: { $0.prefixPath == prefix.path && $0.dependencyID == definition.id && $0.status == "installed" }) else { throw HostError.message("Repair did not restore dependency") }
        print("PASS: official Microsoft repair restores missing native DLL and persists verified installation")
    }
}
