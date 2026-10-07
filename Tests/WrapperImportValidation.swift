import Foundation

@main struct WrapperImportValidation {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossPlayImport-" + UUID().uuidString)
        let resources = root.appendingPathComponent("Saved Game.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("game.exe")
        var pe = Data(repeating: 0, count: 128)
        pe[0] = 77; pe[1] = 90; pe[60] = 64; pe[64] = 80; pe[65] = 69; pe[68] = 0x64; pe[69] = 0x86
        try pe.write(to: exe)
        var profile = WrapperProfile(executable: exe.path, runtime: RuntimeProfile.current.rawValue, advertiseAVX: false, arguments: ["-windowed", "two words"], environment: ["WINEDEBUG": "-all"], prefix: root.appendingPathComponent("saved-prefix").path)
        profile.gameName = "Saved Game"; profile.displayPreferences = ["virtualDesktop": "1280x720"]
        let data = try JSONEncoder().encode(profile)
        let profileURL = resources.appendingPathComponent("GameProfile.json")
        try data.write(to: profileURL)
        let app = resources.deletingLastPathComponent().deletingLastPathComponent()
        let plist: [String: Any] = ["CFBundleIdentifier": "local.crossplay.game.import-test", "CFBundleName": "Saved Game", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let imported = try WrapperImporter.read(app).game
        guard imported.path == exe.path, imported.name == "Saved Game", imported.wrapped == true, !imported.avx,
              imported.prefix == profile.prefix, imported.displayPreferences == profile.displayPreferences,
              try JSONDecoder().decode([String].self, from: Data(imported.arguments.utf8)) == profile.arguments,
              try JSONDecoder().decode([String: String].self, from: Data(imported.environment.utf8)) == profile.environment,
              try Data(contentsOf: profileURL) == data else { throw HostError.message("Import did not preserve saved settings/source") }
        try FileManager.default.removeItem(at: exe)
        do { _ = try WrapperImporter.read(app); throw HostError.message("Missing EXE accepted") }
        catch HostError.message(let message) where message.contains("Game file is unavailable") { }
        do { _ = try WrapperImporter.read(root); throw HostError.message("Non-wrap accepted") }
        catch HostError.message(let message) where message.contains("Choose a game app") { }
        print("PASS: profile settings, unchanged source, missing-game rejection, non-wrap rejection")
    }
}
