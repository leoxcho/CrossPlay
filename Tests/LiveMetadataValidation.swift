import Foundation

@main struct LiveMetadataValidation {
    static func main() throws {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossPlay")
        let checkpoint = URL(fileURLWithPath: CommandLine.arguments[1])
        let live = LibraryModel(applicationSupport: support)
        let previous = try JSONDecoder().decode([LibraryGame].self, from: Data(contentsOf: checkpoint.appendingPathComponent("Library.json")))
        let registry = RuntimeRegistry(applicationSupport: support)
        let oldRegistry = RuntimeRegistry(applicationSupport: checkpoint)
        guard live.games.count == previous.count, registry.runtimes.count == oldRegistry.runtimes.count else { throw HostError.message("Live metadata count changed") }
        let runtimeRoot = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("CrossPlay.app/Contents/Resources/Runtime")
        for saved in live.games {
            guard let original = previous.first(where: { $0.path == saved.path }),
                  saved.runtimeID == original.runtimeID, saved.successfulRuntime == original.successfulRuntime,
                  saved.prefix == original.prefix, saved.runtimePrefixes == original.runtimePrefixes else { throw HostError.message("Game runtime metadata changed") }
            let info = GameInfo(url: URL(fileURLWithPath: saved.path), architecture: saved.architecture ?? "x86-64 Windows", graphics: saved.graphics ?? "", imports: saved.imports ?? [])
            let host = ExecutionHost(root: runtimeRoot, storage: support, registry: registry)
            host.runtimeProfile = RuntimeProfile(rawValue: saved.runtime) ?? .current
            host.runtimeID = saved.runtimeID; host.prefixOverride = saved.prefix.map { URL(fileURLWithPath: $0) }
            let oldHost = ExecutionHost(root: runtimeRoot, storage: support, registry: oldRegistry)
            oldHost.runtimeProfile = host.runtimeProfile; oldHost.runtimeID = original.runtimeID; oldHost.prefixOverride = original.prefix.map { URL(fileURLWithPath: $0) }
            guard host.prefix(for: info).path == oldHost.prefix(for: info).path else { throw HostError.message("Prefix resolution changed") }
            print("PASS: " + saved.name + " → " + (saved.runtimeID ?? "legacy") + " → " + host.prefix(for: info).path)
            _ = try host.selectedRuntimeRoot()
        }
        print("PASS: existing library and registry decode; all previous runtime assignments, successfulRuntime values and prefix paths preserved; no game launched")
    }
}
