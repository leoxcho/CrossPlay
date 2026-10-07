import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArtworkMatch: Decodable, Identifiable {
    let id: Int
    let name: String
    let tiny_image: URL
    var storeURL: URL { URL(string: "https://store.steampowered.com/app/\(id)/")! }
}
enum GameArtwork {
    static func search(_ title: String) async throws -> [ArtworkMatch] {
        var url = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        url.queryItems = [URLQueryItem(name: "term", value: title), URLQueryItem(name: "l", value: "english"), URLQueryItem(name: "cc", value: "US")]
        struct Results: Decodable { let items: [ArtworkMatch] }
        let data = try await fetch(url.url!)
        return try JSONDecoder().decode(Results.self, from: data).items
    }
    static func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw HostError.message("Artwork requires HTTPS.") }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 12_000_000 else { throw HostError.message("Artwork service returned an invalid or oversized response.") }
        return data
    }
    static func download(_ match: ArtworkMatch) async throws -> Data {
        // Fetch the chosen Steam app's metadata, never another search result's artwork.
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(match.id)&l=english")!
        let metadata = try await fetch(url)
        struct Details: Decodable { let success: Bool; let data: AppData? }
        struct AppData: Decodable { let steam_appid: Int; let name: String; let header_image: URL }
        let results = try JSONDecoder().decode([String: Details].self, from: metadata)
        guard let details = results[String(match.id)], details.success, let app = details.data,
              app.steam_appid == match.id, app.name == match.name else { throw HostError.message("Steam title/ID changed. Search again before applying this icon.") }
        let data = try await fetch(app.header_image)
        guard NSImage(data: data) != nil else { throw HostError.message("Downloaded artwork is not an image.") }
        return data
    }
    static func makeIcon(image: NSImage?, name: String, at destination: URL) throws {
        // PNG ICNS elements: retain the complete selected artwork rather than cropping a different subject.
        var elements = Data()
        for (type, size) in [("icp4",16), ("icp5",32), ("icp6",64), ("ic07",128), ("ic08",256), ("ic09",512), ("ic10",1024)] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw HostError.message("Could not render game icon.") }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            let rect = NSRect(x: 0, y: 0, width: size, height: size)
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(size)*0.025, dy: CGFloat(size)*0.025), xRadius: CGFloat(size)*0.2, yRadius: CGFloat(size)*0.2)
            shape.addClip(); NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.16, alpha: 1).setFill(); shape.fill()
            if let image = image, image.size.width > 0, image.size.height > 0 {
                let scale = min(CGFloat(size)*0.95/image.size.width, CGFloat(size)*0.95/image.size.height)
                let width = image.size.width*scale, height = image.size.height*scale
                image.draw(in: NSRect(x: (CGFloat(size)-width)/2, y: (CGFloat(size)-height)/2, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
                let text = NSAttributedString(string: initials, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(size)*0.36, weight: .bold), .foregroundColor: NSColor.white])
                let textSize = text.size(); text.draw(at: NSPoint(x: (CGFloat(size)-textSize.width)/2, y: (CGFloat(size)-textSize.height)/2))
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw HostError.message("Could not encode game icon.") }
            elements.append(Data(type.utf8)); var length = UInt32(png.count+8).bigEndian
            withUnsafeBytes(of: &length) { elements.append(contentsOf: $0) }; elements.append(png)
        }
        var icon = Data("icns".utf8); var length = UInt32(elements.count+8).bigEndian
        withUnsafeBytes(of: &length) { icon.append(contentsOf: $0) }; icon.append(elements)
        try icon.write(to: destination, options: .atomic)
    }
    static func updateWrapper(for game: LibraryGame, app: URL, host: URL) throws {
        guard game.artworkPath != nil else { throw HostError.message("Select the correct game artwork before updating an existing app.") }
        let metadataURL = app.appendingPathComponent("Contents/Resources/GameProfile.json")
        let profile = try JSONDecoder().decode(WrapperProfile.self, from: Data(contentsOf: metadataURL))
        guard URL(fileURLWithPath: profile.executable).standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: game.path).standardizedFileURL.resolvingSymlinksInPath() else { throw HostError.message("This wrapper belongs to a different game. Its icon was not changed.") }
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        guard plist?["CFBundleExecutable"] as? String == "CrossPlayBootstrap", (plist?["CFBundleIdentifier"] as? String)?.hasPrefix("local.crossplay.game.") == true else { throw HostError.message("Only CrossPlay game wrappers can be updated here.") }
        let staging = app.deletingLastPathComponent().appendingPathComponent(".CrossPlay-icon-" + UUID().uuidString + ".app")
        try FileManager.default.copyItem(at: app, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try embed(for: game, in: staging)
        let bootstrap = staging.appendingPathComponent("Contents/MacOS/CrossPlayBootstrap")
        try FileManager.default.removeItem(at: bootstrap)
        try FileManager.default.copyItem(at: host.appendingPathComponent("Contents/Resources/CrossPlayBootstrap"), to: bootstrap)
        var updatedProfile = profile; updatedProfile.host = host.path
        try JSONEncoder().encode(updatedProfile).write(to: staging.appendingPathComponent("Contents/Resources/GameProfile.json"), options: .atomic)
        for arguments in [["--force", "--sign", "-", staging.path], ["--verify", "--deep", "--strict", staging.path]] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); process.arguments = arguments; try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw HostError.message("Updated wrapper failed signature verification; original app preserved.") }
        }
        let backup = app.deletingLastPathComponent().appendingPathComponent(app.deletingPathExtension().lastPathComponent + "-before-icon-" + UUID().uuidString + ".app")
        try FileManager.default.moveItem(at: app, to: backup)
        do { try FileManager.default.moveItem(at: staging, to: app) }
        catch { try? FileManager.default.moveItem(at: backup, to: app); throw error }
        NSWorkspace.shared.noteFileSystemChanged(app.path)
    }
    static func embed(for game: LibraryGame, in app: URL) throws {
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let exe = URL(fileURLWithPath: game.path)
        let folder = exe.deletingLastPathComponent()
        let local = [exe.deletingPathExtension().appendingPathExtension("icns"), exe.deletingPathExtension().appendingPathExtension("ico"), folder.appendingPathComponent("icon.ico"), folder.appendingPathComponent("icon.icns")].first { NSImage(contentsOf: $0) != nil }
        let installed = local.flatMap { NSImage(contentsOf: $0) }
        let extracted = installed == nil ? PEIcon.image(at: exe) : nil
        let selected = game.artworkPath.flatMap { NSImage(contentsOfFile: $0) }
        let image = installed ?? extracted ?? selected
        if game.artworkPath != nil && selected == nil && image == nil { throw HostError.message("Saved game artwork is missing. Import or search for it again.") }
        try makeIcon(image: image, name: game.name, at: resources.appendingPathComponent("GameIcon.icns"))
        var provenance: [String: Any] = ["executable": game.path, "gameName": game.name, "source": local?.path ?? (extracted != nil ? "exe-resource-icon" : (game.artworkSource ?? (image == nil ? "generated-initials" : "user-selected-image")))]
        if let title = game.artworkTitle { provenance["selectedTitle"] = title }
        if let id = game.artworkAppID { provenance["steamAppID"] = id }
        try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys]).write(to: resources.appendingPathComponent("GameArtwork.json"), options: .atomic)
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any] else { throw HostError.message("Invalid wrapper metadata.") }
        plist["CFBundleIconFile"] = "GameIcon.icns"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL, options: .atomic)
    }
}
struct IconSearchView: View {
    @ObservedObject var model: LibraryModel
    let game: LibraryGame
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var matches: [ArtworkMatch] = []
    @State private var chosen: ArtworkMatch?
    @State private var busy = false
    @State private var message = "Search by the full game title, then confirm its artwork."
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Find Game Icon").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.disabled(busy) }
            Text("Assigning artwork to: \(game.name)").font(.headline)
            Text(game.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack { TextField("Full game title", text: $query).textFieldStyle(.roundedBorder).onSubmit(search); Button("Search", action: search).disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            Text("Search sends only this title to Steam. Review the title and image; no result is automatically assigned.").font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView() }
            ScrollView { VStack(spacing: 10) { ForEach(matches) { match in
                Button { chosen = match } label: {
                    HStack(spacing: 14) { AsyncImage(url: match.tiny_image) { image in image.resizable().scaledToFit() } placeholder: { Color.gray.opacity(0.2) }.frame(width: 150, height: 62); VStack(alignment: .leading, spacing: 5) { Text(match.name).font(.headline); Text("Steam app \(match.id)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: chosen?.id == match.id ? "checkmark.circle.fill" : "circle") }.padding(10).background(chosen?.id == match.id ? Color.blue.opacity(0.2) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(busy)
            } } }.frame(minHeight: 230)
            if let chosen { HStack { Link("View game on Steam", destination: chosen.storeURL); Spacer(); Button("Use \(chosen.name) for \(game.name)") { apply(chosen) }.buttonStyle(.borderedProminent).disabled(busy) } }
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack { Button("Import Local Image…") { model.importArtwork(for: game.path) }; Spacer(); Text("PNG, JPEG, TIFF or ICNS").font(.caption).foregroundStyle(.secondary) }.disabled(busy)
        }.padding(24).frame(width: 690, height: 580).preferredColorScheme(.dark).onAppear { query = game.name }
    }
    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !term.isEmpty else { return }; busy = true; chosen = nil; matches = []
        Task { @MainActor in
            defer { busy = false }
            do { matches = try await GameArtwork.search(term); message = matches.isEmpty ? "No matches. Try the full title or import your own image." : "Choose the exact game and edition. Similar titles may appear." }
            catch { message = error.localizedDescription }
        }
    }
    func apply(_ match: ArtworkMatch) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { let data = try await GameArtwork.download(match); try model.storeArtwork(data, for: game.path, source: match.storeURL.absoluteString, title: match.name, appID: match.id); message = "Icon saved for \(game.name). New wrappers will include it. Use Update Existing App Icon for wrappers already created." }
            catch { message = error.localizedDescription }
        }
    }
}

extension LibraryModel {
    func storeArtwork(_ data: Data, for path: String, source: String, title: String, appID: Int?) throws {
        guard let index = games.firstIndex(where: { $0.path == path }), let image = NSImage(data: data), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), bitmap.pixelsWide <= 8192, bitmap.pixelsHigh <= 8192, let png = bitmap.representation(using: .png, properties: [:]) else { throw HostError.message("Select a valid image for an imported game (up to 8192 pixels).") }
        let key = try GameInfo.inspect(URL(fileURLWithPath: path)).key
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossPlay/Artwork")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(key + "-" + UUID().uuidString + ".png")
        try png.write(to: destination, options: .atomic)
        games[index].artworkPath = destination.path; games[index].artworkSource = source; games[index].artworkTitle = title; games[index].artworkAppID = appID
        save(); status = "Saved icon for " + games[index].name
    }
    func importArtwork(for path: String) {
        let chooser = NSOpenPanel(); chooser.title = "Choose the game’s icon or artwork"; chooser.allowedContentTypes = [.png, .jpeg, .tiff, .icns]; chooser.canChooseDirectories = false
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 12_000_000 else { throw HostError.message("Choose an image smaller than 12 MB.") }
            try storeArtwork(data, for: path, source: "local-import", title: url.lastPathComponent, appID: nil)
        } catch { status = error.localizedDescription }
    }
}
