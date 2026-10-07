import Foundation
import CryptoKit

struct CrossPlayRuntime: Codable, Identifiable, Hashable {
    let runtimeID: String
    var displayName: String
    var gptkVersion: String
    var wineVersion: String
    var d3dMetalVersion: String
    var architecture: String
    var source: String
    var installedAt: Date
    var validated: Bool
    var componentHashes: [String: String]
    var runtimePath: String
    var schemaVersion: Int

    var id: String { runtimeID }
}

struct RuntimeRegistryDocument: Codable {
    var schemaVersion: Int = 1
    var defaultRuntimeID: String?
    var runtimes: [CrossPlayRuntime] = []
    var wrapperReferences: [RuntimeWrapperReference]?
    var removedRuntimeIDs: [String]?
    var retainedGameResources: [RuntimeWrapperReference]?
}

final class RuntimeRegistry {
    static let shared: RuntimeRegistry = {
        let applicationSupport = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossPlay")

        let registry = RuntimeRegistry(applicationSupport: applicationSupport)

        let currentRoot = URL(fileURLWithPath: "/usr/local/GPTK4")

        let journeyRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/CrossPlay/Runtimes/GPTK-1.1"
            )

        try? registry.registerBuiltInRuntimes(
            currentRoot: currentRoot,
            journeyCompatibilityRoot: journeyRoot
        )

        return registry
    }()
    static let schemaVersion = 1

    let registryURL: URL
    private(set) var document: RuntimeRegistryDocument
    private var loadError: Error?

    init(applicationSupport: URL) {
        registryURL = applicationSupport.appendingPathComponent("Runtimes.json")

        document = RuntimeRegistryDocument()
        if FileManager.default.fileExists(atPath: registryURL.path) {
            do { document = try JSONDecoder.crossPlay.decode(RuntimeRegistryDocument.self, from: Data(contentsOf: registryURL)) }
            catch { loadError = error }
        }
    }

    func reload() throws {
        document = try JSONDecoder.crossPlay.decode(RuntimeRegistryDocument.self, from: Data(contentsOf: registryURL))
        loadError = nil
    }

    var runtimes: [CrossPlayRuntime] {
        document.runtimes
    }

    var defaultRuntime: CrossPlayRuntime? {
        guard let id = document.defaultRuntimeID else { return nil }
        return runtime(id: id)
    }

    func runtime(id: String) -> CrossPlayRuntime? {
        document.runtimes.first { $0.runtimeID == id }
    }

    func runtime(named name: String) -> CrossPlayRuntime? {
        document.runtimes.first { $0.displayName == name }
    }

    func register(_ runtime: CrossPlayRuntime) throws {
        if let existing = self.runtime(id: runtime.runtimeID),
           existing.runtimePath != runtime.runtimePath || existing.componentHashes != runtime.componentHashes || existing.gptkVersion != runtime.gptkVersion {
            throw RuntimeRegistryError.invalidRuntime("Runtime IDs are immutable. Install a new generation instead of replacing an engine.")
        }
        let previous = document
        if let index = document.runtimes.firstIndex(
            where: { $0.runtimeID == runtime.runtimeID }
        ) {
            document.runtimes[index] = runtime
        } else {
            document.runtimes.append(runtime)
        }

        if document.defaultRuntimeID == nil {
            document.defaultRuntimeID = runtime.runtimeID
        }

        do { try save() } catch { document = previous; throw error }
    }

    func setDefault(runtimeID: String) throws {
        guard runtime(id: runtimeID) != nil else {
            throw RuntimeRegistryError.runtimeNotFound(runtimeID)
        }

        document.defaultRuntimeID = runtimeID
        try save()
    }

    func remove(runtimeID: String) throws {
        let dependencies = try dependencies(for: runtimeID)
        guard dependencies.isEmpty else {
            throw RuntimeRegistryError.invalidRuntime("This runtime is still used by:\n" + dependencies.joined(separator: "\n"))
        }
        guard runtime(id: runtimeID) != nil else {
            throw RuntimeRegistryError.runtimeNotFound(runtimeID)
        }

        let previous = document
        document.runtimes.removeAll { $0.runtimeID == runtimeID }
        document.removedRuntimeIDs = (document.removedRuntimeIDs ?? []) + [runtimeID]

        if document.defaultRuntimeID == runtimeID {
            document.defaultRuntimeID = document.runtimes.first?.runtimeID
        }

        do { try save() } catch { document = previous; throw error }
    }

    func save() throws {
        if let loadError { throw loadError }
        let directory = registryURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder.crossPlay.encode(document)
        try data.write(to: registryURL, options: .atomic)
    }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum RuntimeRegistryError: LocalizedError {
    case runtimeNotFound(String)
    case invalidRuntime(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound(let id):
            return "CrossPlay runtime not found: \(id)"
        case .invalidRuntime(let reason):
            return "Invalid CrossPlay runtime: \(reason)"
        }
    }
}

private extension JSONEncoder {
    static var crossPlay: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var crossPlay: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension RuntimeRegistry {
    func registerBuiltInRuntimes(
        currentRoot: URL,
        journeyCompatibilityRoot: URL
    ) throws {
        let current = CrossPlayRuntime(
            runtimeID: "apple-gptk-current",
            displayName: "CrossPlay Current",
            gptkVersion: "Current",
            wineVersion: "Managed by CrossPlay",
            d3dMetalVersion: "Matched Current Stack",
            architecture: "arm64 host / x86-64 Windows",
            source: "Existing CrossPlay runtime",
            installedAt: Date(),
            validated: FileManager.default.fileExists(
                atPath: currentRoot.appendingPathComponent("bin/wine64").path
            ) || FileManager.default.fileExists(
                atPath: currentRoot.appendingPathComponent("bin/wine").path
            ),
            componentHashes: [:],
            runtimePath: currentRoot.path,
            schemaVersion: Self.schemaVersion
        )

        let journey = CrossPlayRuntime(
            runtimeID: "apple-gptk-1.1",
            displayName: "GPTK 1.1 Compatibility",
            gptkVersion: "1.1",
            wineVersion: "Wine 7.7",
            d3dMetalVersion: "GPTK 1.1 matched D3DMetal",
            architecture: "arm64 host / x86-64 Windows",
            source: "Existing CrossPlay compatibility runtime",
            installedAt: Date(),
            validated: FileManager.default.fileExists(
                atPath: journeyCompatibilityRoot
                    .appendingPathComponent("bin/wine64").path
            ),
            componentHashes: [:],
            runtimePath: journeyCompatibilityRoot.path,
            schemaVersion: Self.schemaVersion
        )

        if runtime(id: current.runtimeID) == nil && !(document.removedRuntimeIDs ?? []).contains(current.runtimeID), !FileManager.default.fileExists(atPath: registryURL.path) {
            document.runtimes.append(current)
            document.runtimes.append(journey)
        }

        // CrossPlay-owned copy of the validated CrossOver 26.2 runtime.
        // This is intentionally independent of the installed CrossOver.app.
        let crossOverRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossPlay/Runtimes")
            .appendingPathComponent("crossover-26.2-gptk-4.0b2-native-layout")
            .appendingPathComponent("CrossOver")

        let crossOverWine = crossOverRoot
            .appendingPathComponent("CrossOver-Hosted Application/wine")

        let crossOverD3DMetal = crossOverRoot
            .appendingPathComponent(
                "lib64/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal"
            )

        if FileManager.default.fileExists(atPath: crossOverWine.path),
           FileManager.default.fileExists(atPath: crossOverD3DMetal.path) {

            let crossOver = CrossPlayRuntime(
                runtimeID: "crossover-26.2-gptk-4.0b2",
                displayName: "GPTK 4.0b2",
                gptkVersion: "4.0b2",
                wineVersion: "Wine 11.0",
                d3dMetalVersion: "4.0b2",
                architecture: "arm64 host / x86-64 Windows",
                source: "CrossPlay-owned import from CrossOver 26.2",
                installedAt: Date(),
                validated: true,
                componentHashes: [
                    "D3DMetal":
                        (try? Self.sha256(crossOverD3DMetal)) ?? ""
                ],
                runtimePath: crossOverRoot.path,
                schemaVersion: Self.schemaVersion
            )

            if let index = document.runtimes.firstIndex(where: { $0.runtimeID == crossOver.runtimeID }) {
                // Only migrate the friendly name; preserve path, hashes and identity.
                document.runtimes[index].displayName = "GPTK 4.0b2"
            } else if !FileManager.default.fileExists(atPath: registryURL.path) {
                document.runtimes.append(crossOver)
            }
        }

        if document.defaultRuntimeID == nil ||
           runtime(id: document.defaultRuntimeID ?? "") == nil {
            document.defaultRuntimeID = document.runtimes.first?.runtimeID
        }
        try save()
    }
}


struct RuntimeWrapperReference: Codable {
    var path: String
    var runtimeID: String
    var gameName: String
}

extension RuntimeRegistry {
    func retainGameResources(_ game: LibraryGame) throws {
        let previous = document
        var records = document.retainedGameResources ?? []
        let selected = game.runtimeID ?? RuntimeProfile(rawValue: game.runtime)?.stableRuntimeID
        for id in Set(([selected, game.successfulRuntime].compactMap { $0 }) + Array((game.runtimePrefixes ?? [:]).keys)) {
            // Older wrappers may be on disconnected drives and have no tracking record.
            if game.wrapped == true || game.prefix != nil || game.runtimePrefixes?[id] != nil {
                records.removeAll { $0.path == game.path && $0.runtimeID == id }
                records.append(RuntimeWrapperReference(path: game.path, runtimeID: id, gameName: game.name))
            }
        }
        document.retainedGameResources = records
        do { try save() } catch { document = previous; throw error }
    }

    func recordWrapper(path: String, runtimeID: String, gameName: String) throws {
        guard runtime(id: runtimeID) != nil else { throw RuntimeRegistryError.runtimeNotFound(runtimeID) }
        let previous = document
        var records = document.wrapperReferences ?? []
        records.removeAll { $0.path == path }
        records.append(RuntimeWrapperReference(path: path, runtimeID: runtimeID, gameName: gameName))
        document.wrapperReferences = records
        do { try save() } catch { document = previous; throw error }
    }

    func dependencies(for id: String) throws -> [String] {
        if let loadError { throw loadError }
        let support = registryURL.deletingLastPathComponent()
        let libraryURL = support.appendingPathComponent("Library.json")
        var result: [String] = []
        if FileManager.default.fileExists(atPath: libraryURL.path) {
            // Fail closed: an unreadable library cannot establish safe removal.
            let games = try JSONDecoder().decode([LibraryGame].self, from: Data(contentsOf: libraryURL))
            result += games.filter {
                ($0.runtimeID ?? RuntimeProfile(rawValue: $0.runtime)?.stableRuntimeID) == id || $0.successfulRuntime == id
            }.map { "Game: " + $0.name }
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"), home.appendingPathComponent("Desktop")]
        func inspectApps(_ directory: URL, depth: Int) throws {
            guard fm.fileExists(atPath: directory.path) else { return }
            for entry in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
                if entry.pathExtension.lowercased() == "app" {
                    let profileURL = entry.appendingPathComponent("Contents/Resources/GameProfile.json")
                    if fm.fileExists(atPath: profileURL.path) {
                        let profile = try JSONDecoder().decode(WrapperProfile.self, from: Data(contentsOf: profileURL))
                        if (profile.runtimeID ?? RuntimeProfile(rawValue: profile.runtime)?.stableRuntimeID) == id || profile.successfulRuntime == id {
                            result.append("Wrapper: " + (profile.gameName ?? entry.lastPathComponent) + " — " + entry.path)
                        }
                    }
                } else if depth > 0, (try entry.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                          entry.lastPathComponent.lowercased().contains("crossplay") {
                    try inspectApps(entry, depth: depth - 1)
                }
            }
        }
        if support.standardizedFileURL == home.appendingPathComponent("Library/Application Support/CrossPlay").standardizedFileURL {
            for root in roots { try inspectApps(root, depth: 2) }
        }
        result += (document.retainedGameResources ?? []).filter { $0.runtimeID == id }
            .map { "Retained game resources: " + $0.gameName }
        result += (document.wrapperReferences ?? []).filter { $0.runtimeID == id }
            .map { "Wrapper: " + $0.gameName + " — " + $0.path }
        // A library-only removal must never make a retained working bottle disposable.
        let prefixes = support.appendingPathComponent("Prefixes")
        if FileManager.default.fileExists(atPath: prefixes.path) {
            for prefix in try FileManager.default.contentsOfDirectory(at: prefixes, includingPropertiesForKeys: nil) {
                let marker = prefix.appendingPathComponent("CrossPlayRuntime.txt")
                if FileManager.default.fileExists(atPath: marker.path),
                   try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == id {
                    result.append("Retained prefix: " + prefix.lastPathComponent)
                }
            }
        }
        return Array(Set(result)).sorted()
    }

    // Import only complete, explicitly selected runtime trees. No downloader or in-place update.
    func install(source: URL, version: String, name: String) throws -> CrossPlayRuntime {
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeRegistryError.invalidRuntime("Enter a GPTK version and display name.")
        }
        if let loadError { throw loadError }
        let fm = FileManager.default
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let components = try Self.inspectImport(source)
        let id = "gptk-" + version.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() + "-" + UUID().uuidString.lowercased()
        let managed = registryURL.deletingLastPathComponent().appendingPathComponent("Runtimes/" + id)
        let staging = managed.deletingLastPathComponent().appendingPathComponent(".install-" + UUID().uuidString)
        try fm.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        let copied = try Self.inspectImport(staging)
        guard copied == components else { throw RuntimeRegistryError.invalidRuntime("Runtime components changed during import.") }
        guard !fm.fileExists(atPath: managed.path) else { throw RuntimeRegistryError.invalidRuntime("New runtime destination already exists.") }
        try fm.moveItem(at: staging, to: managed)
        let runtime = CrossPlayRuntime(runtimeID: id, displayName: name, gptkVersion: version,
            wineVersion: "User-selected Wine", d3dMetalVersion: version, architecture: "arm64 host / x86-64 Windows",
            source: "User-selected complete runtime: " + source.path, installedAt: Date(), validated: false,
            componentHashes: components, runtimePath: managed.path, schemaVersion: Self.schemaVersion)
        let previous = document
        do {
            // Re-read at commit so concurrent library/wrapper records cannot be dropped.
            if fm.fileExists(atPath: registryURL.path) { try reload() }
            try register(runtime)
        }
        catch { document = previous; try? fm.removeItem(at: managed); throw error }
        return runtime
    }

    static func inspectImport(_ root: URL) throws -> [String: String] {
        let fm = FileManager.default
        let wine = ["bin/wine64", "bin/wine"].first { fm.isExecutableFile(atPath: root.appendingPathComponent($0).path) }
        guard let wine, fm.isExecutableFile(atPath: root.appendingPathComponent("bin/wineserver").path) else {
            throw RuntimeRegistryError.invalidRuntime("Select the complete runtime root containing bin/wine64 (or wine) and bin/wineserver. A standalone D3DMetal framework or DMG is not a runnable engine.")
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("lib/external/D3DMetal.framework/Versions/A/D3DMetal").path) else {
            throw RuntimeRegistryError.invalidRuntime("The selected runtime must include lib/external/D3DMetal.framework and its matching Wine components.")
        }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, _ in false }) else {
            throw RuntimeRegistryError.invalidRuntime("Cannot inspect selected runtime.")
        }
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let resolved = file.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root.path + "/"), fm.fileExists(atPath: resolved.path) else {
                    throw RuntimeRegistryError.invalidRuntime("Runtime contains an external or broken symbolic link: " + file.path)
                }
            }
        }
        var paths = [wine, "bin/wineserver", "lib/external/D3DMetal.framework/Versions/A/D3DMetal"]
        for dll in ["d3d11.dll", "dxgi.dll", "d3d12.dll"] {
            guard let path = ["AppleGraphics/" + dll, "lib/wine/x86_64-windows/" + dll].first(where: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
                throw RuntimeRegistryError.invalidRuntime("Missing matched graphics component: " + dll)
            }
            paths.append(path)
        }
        return try Dictionary(uniqueKeysWithValues: paths.map { ($0, try sha256(root.appendingPathComponent($0))) })
    }
}
