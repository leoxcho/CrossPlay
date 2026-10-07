import AppKit
import Darwin

func fail(_ message: String) -> Never {
    let alert = NSAlert(); alert.messageText = "CrossPlay Game"; alert.informativeText = message; alert.runModal(); exit(1)
}
let profileURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/GameProfile.json")
do {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: profileURL)) as? [String: Any]
    var candidates: [URL] = []
    if let path = object?["host"] as? String { candidates.append(URL(fileURLWithPath: path)) }
    if let located = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.crossplay.app") { candidates.append(located) }
    candidates += [URL(fileURLWithPath: "/Applications/CrossPlay.app"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossPlay.app")]
    guard let host = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == "local.crossplay.app" && FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/CrossPlay").path) }) else { fail("CrossPlay could not be located. Install or restore CrossPlay, then open this game again.") }
    let executable = host.appendingPathComponent("Contents/MacOS/CrossPlay").path
    var argv = [executable, "--profile", profileURL.path].map { strdup($0) }; argv.append(nil)
    argv.withUnsafeMutableBufferPointer { _ = execv(executable, $0.baseAddress!) }
    fail("CrossPlay could not start: " + String(cString: strerror(errno)))
} catch { fail("The game profile could not be read: " + error.localizedDescription) }
