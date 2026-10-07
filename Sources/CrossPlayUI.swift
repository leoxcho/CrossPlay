import SwiftUI
import CryptoKit

private enum CrossPlayArtworkCache {
    static let cache = NSCache<NSString, NSImage>()

    static func image(at path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }

        let key = path as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let image = NSImage(contentsOfFile: path) else {
            return nil
        }

        cache.setObject(image, forKey: key)
        return image
    }

    static func invalidate(_ path: String?) {
        guard let path else { return }
        cache.removeObject(forKey: path as NSString)
    }
}
import AppKit

struct LibraryGame: Codable, Identifiable {
    var id: String { path }
    let path: String
    var title: String?
    var name: String { title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    var artworkPath: String?
    var artworkSource: String?
    var artworkTitle: String?
    var artworkAppID: Int?
    var runtime = RuntimeProfile.automatic.rawValue
    // Immutable runtime identity used by new CrossPlay wrappers.
    // Optional so existing Library.json files remain compatible.
    var runtimeID: String?
    var compatibilityStatus: String?
    var wrapped: Bool?
    var displayPreferences: [String: String]?
    var workingDirectory: String?
    var prefix: String?
    var successfulRuntime: String?
    var runtimePrefixes: [String: String]?

    var selectedRuntimeID: String { runtimeID ?? RuntimeProfile(rawValue: runtime)?.stableRuntimeID ?? "apple-gptk-current" }
    var verifiedWorking: Bool { selectedRuntimeID == successfulRuntime }
    mutating func selectRuntime(_ id: String) {
        let previousRuntimeID = selectedRuntimeID
        if let prefix {
            if runtimePrefixes == nil { runtimePrefixes = [:] }
            runtimePrefixes?[previousRuntimeID] = prefix
        }
        prefix = runtimePrefixes?[id]
        runtimeID = id
        runtime = id == "apple-gptk-1.1" ? RuntimeProfile.journeyCompatible.rawValue : RuntimeProfile.current.rawValue
    }

    // Cached executable inspection metadata.
    // Optional so existing Library.json files remain fully compatible.
    var dependencyRequirements: [String]?
    var dependencyInspectionStamp: String?
    var architecture: String?
    var graphics: String?
    var imports: [String]?

    var avx = true
    var arguments = ""
    var environment = ""
}
final class LibraryModel: ObservableObject {
    @Published var section = "My Games"
    @Published var games: [LibraryGame] = []
    @Published var selected: String?
    @Published var search = ""
    @Published var grid = true
    @Published var diagnostics = ""
    @Published var status = "Select a game to get started"
    @Published var running = false
    @Published var dependencySummary: [String] = []
    var choose: () -> Void = {}
    var importWrap: () -> Void = {}
    var select: (String) -> Void = { _ in }
    var launch: () -> Void = {}
    var manageDependencies: () -> Void = {}
    var stop: () -> Void = {}
    var wrap: () -> Void = {}
    var batchWrap: () -> Void = {}
    @Published var batchSelection: Set<String> = []
    var updateWrapperIcon: () -> Void = {}
    var configure: (LibraryGame) -> Void = { _ in }
    let applicationSupport: URL
    private var libraryURL: URL { applicationSupport.appendingPathComponent("Library.json") }
    init(applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossPlay")) {
        self.applicationSupport = applicationSupport
        games = (try? JSONDecoder().decode([LibraryGame].self, from: Data(contentsOf: libraryURL))) ?? []
    }
    var current: LibraryGame? { games.first { $0.path == selected } }
    func save() {
        do { try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(games).write(to: libraryURL, options: .atomic) }
        catch { status = "Could not save library: \(error.localizedDescription)" }
    }
    func removeFromLibrary(_ game: LibraryGame) throws {
        guard !running else { throw HostError.message("Stop the running game before removing a library entry.") }
        try RuntimeRegistry(applicationSupport: applicationSupport).retainGameResources(game)
        let remaining = games.filter { $0.path != game.path }
        // This action writes only Library.json. Wrappers, prefixes, artwork and original games remain.
        try JSONEncoder().encode(remaining).write(to: libraryURL, options: .atomic)
        games = remaining
        batchSelection.remove(game.path)
        selected = games.first?.path
        if let current { configure(current) }
        status = "Removed from CrossPlay; game files and generated resources preserved"
    }
    func record(_ mutate: (inout LibraryGame) -> Void) { guard let i = games.firstIndex(where: { $0.path == selected }) else { return }; mutate(&games[i]); save() }
    func update(_ mutate: (inout LibraryGame) -> Void) { guard let i = games.firstIndex(where: { $0.path == selected }) else { return }; mutate(&games[i]); configure(games[i]); save() }
}
private let ink = Color(red: 0.035, green: 0.045, blue: 0.09)
private let panel = Color(red: 0.075, green: 0.085, blue: 0.15)
private let accent = Color(red: 0.1, green: 0.42, blue: 1)
struct CrossPlayView: View {
    @ObservedObject var model: LibraryModel
    @State private var iconGame: LibraryGame?
    @State private var runtimeRevision = 0
    @State private var installingRuntime = false

    private var availableRuntimes: [CrossPlayRuntime] {
        let _ = runtimeRevision
        let registry = RuntimeRegistry.shared

        let result = registry.runtimes

        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func selectedRuntimeID(for game: LibraryGame) -> String {
        if let id = game.runtimeID {
            return id
        }

        return RuntimeProfile(rawValue: game.runtime)?.stableRuntimeID
            ?? "apple-gptk-current"
    }

    private func runtimeDisplayName(for game: LibraryGame) -> String {
        let id = selectedRuntimeID(for: game)

        if let runtime = availableRuntimes.first(where: { $0.runtimeID == id }) {
            return runtime.displayName
        }

        return game.runtime
    }

    private func legacyRuntimeName(for runtimeID: String) -> String {
        switch runtimeID {
        case "apple-gptk-1.1":
            return RuntimeProfile.journeyCompatible.rawValue
        case "apple-gptk-current":
            return RuntimeProfile.current.rawValue
        default:
            // Dynamic runtimes are represented by runtimeID.
            // Keep legacy runtime field compatible with existing code.
            return RuntimeProfile.current.rawValue
        }
    }
    let sections = [("My Games", "square.grid.2x2"), ("Add Game", "plus.circle"), ("Settings", "gearshape"), ("Manage Runtimes", "square.3.layers.3d"), ("Game Profiles", "slider.horizontal.3"), ("Logs", "doc.text"), ("Help", "questionmark.circle")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(nsImage: NSImage(contentsOf: Bundle.main.url(forResource: "CrossPlay", withExtension: "icns")!) ?? NSImage()).resizable().frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 3) { Text("CrossPlay").font(.system(size: 23, weight: .bold)); Text("WINDOWS → MAC").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary) }
                }.padding(.bottom, 28)
                ForEach(sections, id: \.0) { item in
                    Button { model.section = item.0 } label: { Label(item.0, systemImage: item.1).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(model.section == item.0 ? accent.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
                    if item.0 == "Game Profiles" { Divider().padding(.vertical, 14) }
                }
                Spacer()
                Text("Play Windows Games on macOS").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(width: 220).background(.ultraThinMaterial)
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text(model.section).font(.system(size: 27, weight: .bold)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer()
                    if model.section == "My Games" { TextField("Search games…", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 220) }
                    Button { model.section = "Help" } label: { Image(systemName: "info.circle").font(.title3) }.buttonStyle(.plain)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch model.section {
                        case "My Games": library
                        case "Add Game": addGame
                        case "Settings", "Game Profiles": settings
                        case "Manage Runtimes": runtimes
                        case "Logs": logView
                        default: help
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 20)
                }
                HStack(spacing: 8) { Circle().fill(model.running ? .green : .purple).frame(width: 6, height: 6); Text(model.status).lineLimit(2).font(.system(size: 11)).foregroundStyle(.secondary); Spacer() }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(ink)
        }.preferredColorScheme(.dark).tint(accent).frame(minWidth: 980, minHeight: 660)
        .disabled(installingRuntime)
        .sheet(item: $iconGame) { IconSearchView(model: model, game: $0) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { model.select(url.path) } } } }; return !providers.isEmpty
        }
    }
    var subtitle: String { switch model.section { case "My Games": return "Your Windows games. At home on Mac."; case "Add Game": return "Bring your next adventure to macOS."; case "Manage Runtimes": return "Choose the right compatibility environment."; default: return "Make CrossPlay work your way." } }
    var library: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let game = model.current {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.indigo.opacity(0.85), .purple.opacity(0.45), panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let path = game.artworkPath, let image = CrossPlayArtworkCache.image(at: path) { Image(nsImage: image).resizable().scaledToFill().frame(height: 250).clipped().opacity(0.5) }
                    Image(systemName: "sparkle").font(.system(size: 160, weight: .ultraLight)).foregroundStyle(.white.opacity(0.12)).frame(maxWidth: .infinity, alignment: .trailing).padding(30)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 12) { Text("YOUR NEXT ADVENTURE").font(.system(size: 10, weight: .semibold)).tracking(3).foregroundStyle(.white.opacity(0.6)); Text(game.name).font(.system(size: 36, weight: .bold)); Text(runtimeDisplayName(for: game)).foregroundStyle(.secondary); Text((game.wrapped == true ? "Wrapped • " : "") + (game.compatibilityStatus ?? "Unverified")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        VStack(spacing: 10) { Button(action: model.launch) { Label(model.running ? "Game Running" : "Launch Game", systemImage: "play.fill").frame(width: 180).padding(8) }.buttonStyle(.borderedProminent).disabled(model.running); Button(action: model.wrap) { Label("Create Mac App", systemImage: "shippingbox").frame(width: 180).padding(6) }.buttonStyle(.bordered); Button("Find Game Icon") { iconGame = game }.buttonStyle(.plain).font(.caption); Button("Game Settings") { model.section = "Game Profiles" }.buttonStyle(.plain).font(.caption) }
                    }.padding(26)
                }.frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1)))
            } else { addGame }
            HStack { Text("My Games").font(.title3.bold()); Text("\(model.games.count)").foregroundStyle(.secondary); Spacer(); Button("Add Existing Wrap…", action: model.importWrap); Button("Wrap Selected (\(model.batchSelection.count))…", action: model.batchWrap).disabled(model.batchSelection.isEmpty); Button { model.grid.toggle() } label: { Image(systemName: model.grid ? "list.bullet" : "square.grid.2x2") }.buttonStyle(.plain) }
            LazyVGrid(columns: model.grid ? [GridItem(.adaptive(minimum: 170), spacing: 16)] : [GridItem(.flexible())], spacing: 16) {
                ForEach(model.games.filter { model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search) }) { game in
                    Button { model.select(game.path) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            ZStack { LinearGradient(colors: [.indigo, panel], startPoint: .topLeading, endPoint: .bottomTrailing); if let path = game.artworkPath, let image = CrossPlayArtworkCache.image(at: path) { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "gamecontroller").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.white.opacity(0.7)) } }.frame(height: model.grid ? 100 : 45).clipShape(RoundedRectangle(cornerRadius: 9))
                            Toggle("Wrap", isOn: Binding(get: { model.batchSelection.contains(game.path) }, set: { if $0 { model.batchSelection.insert(game.path) } else { model.batchSelection.remove(game.path) } })).font(.caption)
                            Text(game.name).font(.system(size: 13, weight: .semibold)).lineLimit(1); Text(runtimeDisplayName(for: game)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selected == game.path ? accent : .white.opacity(0.1), lineWidth: model.selected == game.path ? 2 : 1))
                    }.buttonStyle(.plain)
                }
                Button { model.section = "Add Game" } label: { VStack(spacing: 16) { Image(systemName: "plus").font(.system(size: 30, weight: .ultraLight)); Text("Add Game").font(.caption) }.frame(maxWidth: .infinity).frame(height: 165).background(panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [6]))) }.buttonStyle(.plain)
            }
        }
    }
    var addGame: some View {
        VStack(spacing: 20) { Image(systemName: "plus.app").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(.purple); Text("Add a Windows Game").font(.title2.bold()); Text("Drag your .exe file here").font(.title3); Text("Your game stays where it is, including on an external drive.").font(.caption).foregroundStyle(.secondary); Button("Browse Files…", action: model.choose).buttonStyle(.borderedProminent); Button("Add Existing Wrap…", action: model.importWrap).buttonStyle(.bordered); Text("You can also drop an existing CrossPlay .app here.").font(.caption).foregroundStyle(.secondary); Text("Configure your game, then create its own Mac app.").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(45).background(panel, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [6])))
    }
    private func showError(_ error: Error) {
        model.status = error.localizedDescription
        let alert = NSAlert(); alert.messageText = "CrossPlay"; alert.informativeText = error.localizedDescription; alert.runModal()
    }
    private func installRuntime() {
        let panel = NSOpenPanel(); panel.title = "Select a complete Wine/GPTK runtime folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Install Runtime"
        alert.informativeText = "Enter the version from your selected runtime's source. CrossPlay will copy this complete folder into a new runtime directory; existing engines and prefixes are preserved. Import checks component structure, not gameplay compatibility or Apple provenance."
        let fields = NSStackView(); fields.orientation = .vertical
        let version = NSTextField(string: ""); version.placeholderString = "GPTK version (e.g. 4.0b2)"
        let name = NSTextField(string: ""); name.placeholderString = "Display name (e.g. GPTK 4.0b2)"
        fields.addArrangedSubview(version); fields.addArrangedSubview(name); fields.frame = NSRect(x: 0, y: 0, width: 380, height: 60)
        alert.accessoryView = fields; alert.addButton(withTitle: "Install"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedVersion = version.stringValue, selectedName = name.stringValue
        installingRuntime = true
        let support = RuntimeRegistry.shared.registryURL.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RuntimeRegistry(applicationSupport: support).install(source: source, version: selectedVersion, name: selectedName) }
            DispatchQueue.main.async {
                installingRuntime = false
                do {
                    let runtime = try result.get()
                    try RuntimeRegistry.shared.reload()
                    runtimeRevision += 1
                    model.status = "Installed " + runtime.displayName + " alongside existing runtimes; gameplay untested"
                } catch { showError(error) }
            }
        }
    }
    private func removeRuntime(_ runtime: CrossPlayRuntime) {
        do {
            try RuntimeRegistry.shared.reload()
            let dependencies = try RuntimeRegistry.shared.dependencies(for: runtime.runtimeID)
            let alert = NSAlert()
            if !dependencies.isEmpty {
                let count = dependencies.filter { $0.hasPrefix("Game: ") }.count
                alert.messageText = runtime.displayName + (count > 0 ? " is used by \(count) games." : " has retained dependencies.")
                alert.informativeText = dependencies.joined(separator: "\n") + "\n\nResolve these dependencies explicitly before removing this runtime."
                alert.addButton(withTitle: "Cancel"); alert.runModal(); return
            }
            alert.messageText = "Remove " + runtime.displayName + " from CrossPlay?"
            alert.informativeText = "Removes the runtime registration. Runtime files remain at " + runtime.runtimePath + ". No game files or prefixes are deleted."
            alert.addButton(withTitle: "Remove Runtime"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try RuntimeRegistry.shared.remove(runtimeID: runtime.runtimeID)
            runtimeRevision += 1; model.status = "Removed runtime registration; runtime files preserved"
        } catch { showError(error) }
    }
    private func removeGame(_ game: LibraryGame) {
        let alert = NSAlert(); alert.messageText = "Remove " + game.name + " from CrossPlay?"
        let key = String(SHA256.hash(data: Data(game.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
        let prefixRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossPlay/Prefixes")
        let prefixes = ((try? FileManager.default.contentsOfDirectory(atPath: prefixRoot.path)) ?? []).filter { $0.hasPrefix(key + "-") }
        alert.informativeText = "Only the library entry is removed. Original Windows files, generated wrappers, cached artwork and all prefixes remain.\n\nRetained runtime-specific prefixes (\(prefixes.count)):\n" + prefixes.joined(separator: "\n")
        alert.addButton(withTitle: "Remove from CrossPlay"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try model.removeFromLibrary(game); try RuntimeRegistry.shared.reload() } catch { showError(error) }
    }
    var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let game = model.current {
                Text(game.name).font(.title2.bold())
                GroupBox("Game Icon") {
                    HStack(spacing: 18) {
                        if let path = game.artworkPath, let image = CrossPlayArtworkCache.image(at: path) { Image(nsImage: image).resizable().scaledToFit().frame(width: 120, height: 90) }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(game.artworkTitle ?? "No artwork selected • wrappers use game initials").font(.caption).foregroundStyle(.secondary)
                            HStack { Button("Search Game Icon…") { iconGame = game }; Button("Import Image…") { model.importArtwork(for: game.path) } }
                            Button("Update Existing App Icon…", action: model.updateWrapperIcon).disabled(game.artworkPath == nil)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Compatibility") { VStack(alignment: .leading, spacing: 18) {
                    Picker(
                        "Runtime",
                        selection: Binding(
                            get: {
                                guard let game = model.current else {
                                    return "apple-gptk-current"
                                }
                                return selectedRuntimeID(for: game)
                            },
                            set: { runtimeID in
                                model.update {
                                    $0.selectRuntime(runtimeID)
                                }
                            }
                        )
                    ) {
                        ForEach(availableRuntimes, id: \.runtimeID) { runtime in
                            Text(runtime.displayName).tag(runtime.runtimeID)
                        }
                    }
                    Text(runtimeDisplayName(for: game) + (selectedRuntimeID(for: game) == game.successfulRuntime ? "  ✓ Verified Working" : ""))
                        .foregroundStyle(selectedRuntimeID(for: game) == game.successfulRuntime ? .green : .secondary)
                    if let successful = game.successfulRuntime, successful != selectedRuntimeID(for: game) {
                        Text("Known-working runtime: " + (RuntimeRegistry.shared.runtime(id: successful)?.displayName ?? successful) + ". Its prefix is preserved.").font(.caption)
                    }
                    Toggle("Advertise AVX through Rosetta", isOn: Binding(get: { model.current?.avx ?? true }, set: { value in model.update { $0.avx = value } }))
                    Text("Each runtime uses its own isolated game environment and matching graphics stack.").font(.caption).foregroundStyle(.secondary)
                }.padding(12).disabled(model.running) }
                GroupBox("Windows Dependencies") { VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.dependencySummary, id: \.self) { Text($0).font(.caption) }
                    Text("Requirements and installation status are evaluated for this game’s selected runtime and prefix.").font(.caption)
                    Button("Manage Dependencies…", action: model.manageDependencies).disabled(model.running)
                    Button("Game didn’t start? Check / Install Windows Dependencies", action: model.manageDependencies).disabled(model.running)
                }.padding(12) }
                GroupBox("Advanced") { VStack(alignment: .leading, spacing: 12) {
                    Text("Launch arguments (JSON array)").font(.caption); TextField("[\"-windowed\"]", text: Binding(get: { model.current?.arguments ?? "" }, set: { value in model.update { $0.arguments = value } })).textFieldStyle(.roundedBorder)
                    Text("Environment variables (JSON object)").font(.caption); TextField("{}", text: Binding(get: { model.current?.environment ?? "" }, set: { value in model.update { $0.environment = value } })).textFieldStyle(.roundedBorder)
                    Text(game.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(12) }
                Button("Remove from CrossPlay…") { removeGame(game) }.disabled(model.running)
                Text("Library removal preserves original files, wrappers, artwork, and every runtime-specific prefix.").font(.caption).foregroundStyle(.secondary)
                Button("Create Mac App", action: model.wrap).buttonStyle(.borderedProminent)
                Button("Wrap Selected Games (\(model.batchSelection.count))…", action: model.batchWrap).disabled(model.batchSelection.isEmpty)
                TextField("Working directory (blank uses EXE folder)", text: Binding(get: { model.current?.workingDirectory ?? "" }, set: { value in model.update { $0.workingDirectory = value.isEmpty ? nil : value } }))
                TextField("Wine prefix (blank uses isolated default)", text: Binding(get: { model.current?.prefix ?? "" }, set: { value in model.update { $0.prefix = value.isEmpty ? nil : value } }))
                TextField("Virtual desktop (blank uses game display; e.g. 1280x720)", text: Binding(get: { model.current?.displayPreferences?["virtualDesktop"] ?? "" }, set: { value in model.update { if $0.displayPreferences == nil { $0.displayPreferences = [:] }; $0.displayPreferences?["virtualDesktop"] = value } }))
                Picker("Observed compatibility", selection: Binding(get: { model.current?.compatibilityStatus ?? "Unverified" }, set: { value in model.update { $0.compatibilityStatus = value; if value == "Menu Verified" || value == "Gameplay Verified" { $0.successfulRuntime = $0.selectedRuntimeID } } })) { ForEach(["Unverified", "Launches", "Process Stable", "Menu Verified", "Gameplay Verified", "Failed"], id: \.self) { Text($0).tag($0) } }
                Text("Menu and gameplay verification require your observation. Process survival only records Process Stable.").font(.caption)
            } else { Text("Select a game in My Games to edit its settings.").foregroundStyle(.secondary); Button("My Games") { model.section = "My Games" }.buttonStyle(.bordered) }
        }
    }
    var runtimes: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(installingRuntime ? "Installing Runtime…" : "Install Runtime…") { installRuntime() }
                .disabled(installingRuntime || model.running)
            Text("Import a complete, user-selected Wine/GPTK runtime folder. New generations are installed alongside existing engines. No automatic downloads or updates.").font(.caption).foregroundStyle(.secondary)
            ForEach(availableRuntimes, id: \.runtimeID) { runtime in
                HStack(spacing: 16) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.title)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(runtime.displayName)
                            .font(.headline)

                        HStack(spacing: 8) {
                            Text("GPTK \(runtime.gptkVersion)")
                            Text(runtime.wineVersion)
                            Text("D3DMetal \(runtime.d3dMetalVersion)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(runtime.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(runtime.runtimeID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button("Remove Runtime…") { removeRuntime(runtime) }.disabled(model.running || installingRuntime)
                    Text(runtime.validated ? "Installed" : "Installed • Untested")
                        .font(.caption)
                        .padding(8)
                        .background(
                            (runtime.validated ? Color.teal : Color.orange).opacity(0.2),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .padding(20)
                .background(panel, in: RoundedRectangle(cornerRadius: 12))
            }

            Text("Select a runtime per game in Game Profiles. Existing games keep their assigned runtime until you change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    var logView: some View { VStack(alignment: .leading, spacing: 14) { HStack { Text("Launch Diagnostics").font(.headline); Spacer(); Button("Stop Game", action: model.stop).disabled(!model.running) }; Text(model.diagnostics.isEmpty ? "Launch diagnostics will appear here." : model.diagnostics).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(panel, in: RoundedRectangle(cornerRadius: 12)) } }
    var help: some View { VStack(alignment: .leading, spacing: 20) { Text("CrossPlay").font(.largeTitle.bold()); Text("Play Windows Games on macOS").font(.title3).foregroundStyle(.secondary); Text("1. Add your Windows game executable.\n\n2. Choose a runtime and save your game settings.\n\n3. Create Mac App to launch the game from Finder."); Text("Game apps reference CrossPlay and your existing game files. Keep both accessible. Imported games are not automatically marked playable.").foregroundStyle(.secondary) }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 16)) }
}

// Shared by automatic preflight and the native cancellation validation harness.
enum DependencyPrompts {
    static func required(_ definitions: [GameDependencyDefinition], prefix: URL, runtimeID: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Required component detected"
        alert.informativeText = definitions.map(\.displayName).joined(separator: "\n") + "\n\nMissing from this game’s Windows environment. Download from Microsoft and install into:\n" + prefix.path + "\nRuntime: " + runtimeID
        alert.addButton(withTitle: "Install & Relaunch"); alert.addButton(withTitle: "Cancel")
        return alert
    }
}
