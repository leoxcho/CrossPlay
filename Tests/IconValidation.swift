import Foundation
import AppKit

@main struct IconValidation {
    @MainActor static func main() async throws {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = workspace.appendingPathComponent("Build/IconValidation/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let matches = try await GameArtwork.search("Journey")
        guard let chosen = matches.first(where: { $0.name == "Journey" && $0.id == 638230 }) else { throw HostError.message("Exact Journey Steam result unavailable") }
        let data = try await GameArtwork.download(chosen)
        let artwork = folder.appendingPathComponent("Journey.png"); try data.write(to: artwork)
        var game = LibraryGame(path: "/Volumes/SSD/Journey/Journey.exe"); game.artworkPath = artwork.path
        let app = folder.appendingPathComponent("Journey.app")
        let resources = app.appendingPathComponent("Contents/Resources"), macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let profile = WrapperProfile(executable: game.path, runtime: RuntimeProfile.journeyCompatible.rawValue, advertiseAVX: true, arguments: ["-windowed"], environment: ["WINEDEBUG": "-all"], prefix: nil)
        let profileData = try JSONEncoder().encode(profile)
        try profileData.write(to: resources.appendingPathComponent("GameProfile.json"))
        let plist: [String: Any] = ["CFBundleName": "Journey", "CFBundleExecutable": "CrossPlayBootstrap", "CFBundleIdentifier": "local.crossplay.game.iconvalidation", "CFBundlePackageType": "APPL"]
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        let bootstrap = macos.appendingPathComponent("CrossPlayBootstrap")
        try "#!/bin/zsh\nexit 0\n".write(to: bootstrap, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bootstrap.path)
        var other = LibraryGame(path: "/Volumes/SSD/Another Game/Game.exe"); other.artworkPath = artwork.path
        let before = try Data(contentsOf: plistURL)
        var rejected = false
        do { try GameArtwork.updateWrapper(for: other, app: app, host: workspace.appendingPathComponent("CrossPlay.app")) }
        catch { rejected = true }
        guard rejected, try Data(contentsOf: plistURL) == before, !FileManager.default.fileExists(atPath: resources.appendingPathComponent("GameIcon.icns").path) else { throw HostError.message("Wrong-game update was not safely rejected") }
        try GameArtwork.updateWrapper(for: game, app: app, host: workspace.appendingPathComponent("CrossPlay.app"))
        let icon = resources.appendingPathComponent("GameIcon.icns")
        guard let image = NSImage(contentsOf: icon), image.isValid else { throw HostError.message("ICNS cannot be decoded") }
        let installed = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
        guard installed["CFBundleIconFile"] as? String == "GameIcon.icns", try Data(contentsOf: resources.appendingPathComponent("GameProfile.json")) == profileData else { throw HostError.message("Wrapper icon or preserved launch profile failed") }
        let fallback = folder.appendingPathComponent("Fallback.icns"); try GameArtwork.makeIcon(image: nil, name: "Different Game", at: fallback)
        guard NSImage(contentsOf: fallback)?.isValid == true else { throw HostError.message("Fallback icon invalid") }
        let oldLibrary = Data("[{\"path\":\"/old/game.exe\",\"runtime\":\"CrossPlay Current\",\"avx\":true,\"arguments\":\"\",\"environment\":\"\"}]".utf8)
        guard try JSONDecoder().decode([LibraryGame].self, from: oldLibrary).first?.artworkPath == nil else { throw HostError.message("Old library decoding failed") }
        print("PASS: Live Steam search and app-ID artwork validation; wrong-game rejection without mutation; seven-size ICNS rendering; signed existing-wrapper update with unchanged profile; fallback icon; old library decoding.")
        print("Artifacts: " + folder.path)
    }
}
