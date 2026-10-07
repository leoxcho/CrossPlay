import AppKit

// Optional additions keep the original generated profiles readable.
struct WrapperProfile: Codable {
    let executable: String
    let runtime: String
    // Concrete runtime identity. Legacy wrappers may not contain this field.
    var runtimeID: String?
    var successfulRuntime: String?
    let advertiseAVX: Bool
    let arguments: [String]
    let environment: [String: String]
    let prefix: String?
    var schemaVersion: Int? = 2
    var gameID: String?
    var gameName: String?
    var host: String?
    var workingDirectory: String?
    var sourceVolumePath: String?
    var sourceVolumeUUID: String?
    var relativeExecutable: String?
    var bookmark: Data?
    var graphicsStack: String?
    var displayPreferences: [String: String]?
    var compatibilityStatus: String?
    var icon: String? = "GameIcon.icns"

    func resolvedExecutable() throws -> URL {
        let original = URL(fileURLWithPath: executable)
        let fm = FileManager.default
        // Volume identity prevents launching an unrelated drive with the same name.
        if let uuid = sourceVolumeUUID {
            let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
            guard let volume = volumes.first(where: { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == uuid }) else {
                throw HostError.message("Game volume is unavailable. Reconnect \(sourceVolumePath ?? "the source drive"). Your game profile is preserved.")
            }
            if let relative = relativeExecutable {
                let resolved = volume.appendingPathComponent(relative).standardizedFileURL
                guard resolved.path.hasPrefix(volume.path + "/"), fm.fileExists(atPath: resolved.path) else { throw HostError.message("Game file is unavailable on \(volume.path). Reconnect or restore its recorded location; the profile is preserved.") }
                return resolved
            }
        }
        if fm.fileExists(atPath: original.path) { return original }
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), fm.fileExists(atPath: resolved.path) { return resolved }
        }
        throw HostError.message("Game file is unavailable: \(executable). Reconnect its source drive. Your game profile is preserved.")
    }
    func resolvedWorkingDirectory(for executableURL: URL) -> URL {
        guard let workingDirectory else { return executableURL.deletingLastPathComponent() }
        if let sourceVolumePath, workingDirectory.hasPrefix(sourceVolumePath + "/"), let relativeExecutable {
            var volume = executableURL
            for _ in relativeExecutable.split(separator: "/") { volume.deleteLastPathComponent() }
            return volume.appendingPathComponent(String(workingDirectory.dropFirst(sourceVolumePath.count + 1)))
        }
        return URL(fileURLWithPath: workingDirectory)
    }
    static func capture(game: GameInfo, host: ExecutionHost, saved: LibraryGame, arguments: [String], environment: [String: String]) throws -> WrapperProfile {
        var profile = WrapperProfile(executable: game.url.path, runtime: host.runtimeProfile.rawValue, advertiseAVX: host.advertiseAVX, arguments: arguments, environment: environment, prefix: host.prefix(for: game).path)
        profile.runtimeID = host.runtimeID ?? saved.runtimeID ?? host.runtimeProfile.stableRuntimeID
        profile.successfulRuntime = saved.successfulRuntime
        guard let id = profile.runtimeID, RuntimeRegistry.shared.runtime(id: id) != nil else {
            throw HostError.message("Install the selected runtime before creating its wrapper.")
        }
        profile.gameID = game.key; profile.gameName = saved.name; profile.host = Bundle.main.bundleURL.path
        profile.workingDirectory = host.workingDirectoryOverride?.path ?? game.url.deletingLastPathComponent().path
        let values = try game.url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
        profile.sourceVolumePath = values.volume?.path; profile.sourceVolumeUUID = values.volumeUUIDString
        if let volume = values.volume, game.url.path.hasPrefix(volume.path + "/") { profile.relativeExecutable = String(game.url.path.dropFirst(volume.path.count + 1)) }
        profile.bookmark = try? game.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        profile.graphicsStack = host.runtimeProfile == .journeyCompatible ? "GPTK 1.1 matched Wine 7.7 + D3DMetal" : "CrossPlay current matched graphics"
        profile.displayPreferences = saved.displayPreferences ?? [:]; profile.compatibilityStatus = saved.compatibilityStatus ?? "Unverified"
        return profile
    }
}
enum WrapperGenerator {
    static func create(profile: WrapperProfile, game: LibraryGame, destination: URL) throws {
        let fm = FileManager.default
        guard destination.pathExtension == "app", !fm.fileExists(atPath: destination.path) else { throw HostError.message("Choose a new .app destination to preserve existing apps.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".CrossPlay-" + UUID().uuidString + ".app")
        defer { try? fm.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("Contents"), resources = staging.appendingPathComponent("Contents/Resources"), macos = staging.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true); try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: resources.appendingPathComponent("GameProfile.json"))
        try fm.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/CrossPlayBootstrap"), to: macos.appendingPathComponent("CrossPlayBootstrap"))
        let plist: [String: Any] = ["CFBundleName": game.name, "CFBundleDisplayName": game.name, "CFBundleExecutable": "CrossPlayBootstrap", "CFBundleIdentifier": "local.crossplay.game." + (profile.gameID ?? game.id), "CFBundlePackageType": "APPL", "CFBundleVersion": "2", "LSApplicationCategoryType": "public.app-category.games", "NSHighResolutionCapable": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try GameArtwork.embed(for: game, in: staging)
        for arguments in [["--force", "--sign", "-", staging.path], ["--verify", "--deep", "--strict", staging.path]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); p.arguments = arguments; try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw HostError.message("Wrapper signature validation failed.") }
        }
        guard let id = profile.runtimeID else { throw HostError.message("Wrapper requires an immutable runtime ID.") }
        // Record first so a persistence failure cannot leave an untracked generated wrapper.
        try RuntimeRegistry.shared.recordWrapper(path: destination.path, runtimeID: id, gameName: game.name)
        try fm.moveItem(at: staging, to: destination)
    }
}

// Read profiles without executing or changing the selected app.
enum WrapperImporter {
    static func read(_ app: URL) throws -> (game: LibraryGame, info: GameInfo, iconData: Data?) {
        guard app.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier?.hasPrefix("local.crossplay.game.") == true else {
            throw HostError.message("Choose a game app created by CrossPlay.")
        }
        let resources = app.appendingPathComponent("Contents/Resources")
        let profile = try JSONDecoder().decode(WrapperProfile.self, from: Data(contentsOf: resources.appendingPathComponent("GameProfile.json")))
        guard RuntimeProfile(rawValue: profile.runtime) != nil else { throw HostError.message("This wrap uses an unsupported runtime: " + profile.runtime) }
        let executable = try profile.resolvedExecutable()
        let info = try GameInfo.inspect(executable)
        var game = LibraryGame(path: executable.path)
        game.title = profile.gameName ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        game.successfulRuntime = profile.successfulRuntime
        game.runtime = profile.runtime
        game.runtimeID = profile.runtimeID ?? RuntimeProfile(rawValue: profile.runtime)?.stableRuntimeID
        game.avx = profile.advertiseAVX
        game.arguments = String(decoding: try JSONEncoder().encode(profile.arguments), as: UTF8.self)
        game.environment = String(decoding: try JSONEncoder().encode(profile.environment), as: UTF8.self)
        game.prefix = profile.prefix
        game.workingDirectory = profile.resolvedWorkingDirectory(for: executable).path
        game.displayPreferences = profile.displayPreferences
        game.compatibilityStatus = profile.compatibilityStatus ?? "Unverified"
        game.wrapped = true
        if let id = game.runtimeID {
            try RuntimeRegistry.shared.recordWrapper(path: app.path, runtimeID: id, gameName: game.name)
        }
        let iconName = (bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String) ?? profile.icon ?? "GameIcon.icns"
        // Only read a resource filename, never an arbitrary profile-supplied path.
        let icon = resources.appendingPathComponent(URL(fileURLWithPath: iconName).lastPathComponent)
        let iconURL = icon.pathExtension.isEmpty ? icon.appendingPathExtension("icns") : icon
        let data = try? Data(contentsOf: iconURL)
        return (game, info, data.flatMap { NSImage(data: $0) == nil ? nil : $0 })
    }
}
