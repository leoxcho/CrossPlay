import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class DropView: NSView {
    var receive: ((URL) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let str = sender.draggingPasteboard.string(forType: .fileURL), let url = URL(string: str) else { return false }
        receive?(url); return true
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    let library = LibraryModel()
    var window: NSWindow!
    var info = NSTextField(labelWithString: "Drop a Windows game here\nor select EXE")
    var args = NSTextField(string: "")
    var env = NSTextField(string: "")
    var logs = NSTextView()
    var launchButton: NSButton!
    var runtimePopup = NSPopUpButton()
    var avxToggle = NSButton(
        checkboxWithTitle: "Advertise AVX through Rosetta",
        target: nil,
        action: nil
    )
    var game: GameInfo?
    var wrapperMode = false
    lazy var dependencyManager = GameDependencyManager(support: library.applicationSupport)
    lazy var host: ExecutionHost = {
        let root = Bundle.main.resourceURL!.appendingPathComponent("Runtime")
        // Retained storage identity preserves existing game prefixes and saves.
        let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossPlay")
        let h = ExecutionHost(root: root, storage: storage)
        h.log = { [weak self] message in self?.append(message) }
        h.started = { [weak self] in
            guard let self else { return }
            self.library.record { $0.compatibilityStatus = "Launches" }
            self.library.status = "Launches • Gameplay unverified"
            let launched = self.host.process
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, let launched, self.host.process === launched, launched.isRunning else { return }

                // Process survival does not prove rendering or gameplay.
                // Keep the game in Launches until the user or a future frame-health
                // probe confirms that a real menu/game frame is being presented.
                self.library.status = "Process still running (20 seconds) • Rendering, menu, input and gameplay unverified"
                self.append("Process survived 20 seconds; this is not treated as rendering success.\n")
            }
        }
        h.finished = { [weak self] status in self?.launchButton.isEnabled = true; self?.library.running = false; self?.library.status = "Game process ended (status \(status))"; if status != 0 { self?.library.record { $0.compatibilityStatus = "Failed" } }; if self?.wrapperMode == true { if status != 0 { let alert = NSAlert(); alert.messageText = "Game launch failed"; alert.informativeText = "The game exited with status \(status). Open CrossPlay Logs for diagnostics."; alert.runModal() }; NSApp.terminate(nil) }; self?.append(status == 0 ? "Process ended.\n" : "Launch failed; inspect diagnostics above.\n") }
        return h
    }()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationItem = NSMenuItem(); menu.addItem(applicationItem)
        let applicationMenu = NSMenu(title: "CrossPlay")
        applicationMenu.addItem(withTitle: "About CrossPlay", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(NSMenuItem.separator())
        applicationMenu.addItem(withTitle: "Quit CrossPlay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:1180,height:780), styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing:.buffered, defer:false)
        window.title = "CrossPlay"; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 980, height: 700)
        launchButton = NSButton(title: "Launch Game", target: self, action: #selector(run))
        runtimePopup.addItems(withTitles: RuntimeProfile.allCases.map { $0.rawValue })
        runtimePopup.selectItem(withTitle: RuntimeProfile.current.rawValue)
        avxToggle.state = .on
        library.choose = { [weak self] in self?.choose() }
        library.importWrap = { [weak self] in self?.chooseExistingWrap() }
        library.select = { [weak self] in self?.select(URL(fileURLWithPath: $0)) }
        library.manageDependencies = { [weak self] in self?.manageDependencies() }
        library.launch = { [weak self] in self?.run() }
        library.stop = { [weak self] in self?.stopGame() }
        library.batchWrap = { [weak self] in self?.createBatchWrappers() }
        library.wrap = { [weak self] in self?.createWrapper() }
        library.updateWrapperIcon = { [weak self] in self?.updateExistingWrapperIcon() }
        library.configure = { [weak self] in self?.configure($0) }
        window.contentView = NSHostingView(rootView: CrossPlayView(model: library))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if let i = CommandLine.arguments.firstIndex(of:"--select"), CommandLine.arguments.count > i+1 { select(URL(fileURLWithPath:CommandLine.arguments[i+1])) }
        if let i = CommandLine.arguments.firstIndex(of:"--arguments"), CommandLine.arguments.count > i+1 { args.stringValue = CommandLine.arguments[i+1] }
        if let i = CommandLine.arguments.firstIndex(of: "--runtime"), CommandLine.arguments.count > i+1,
           let profile = RuntimeProfile(rawValue: CommandLine.arguments[i+1]) {
            runtimePopup.selectItem(withTitle: profile.rawValue); runtimeChanged()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--environment"), CommandLine.arguments.count > i+1 { env.stringValue = CommandLine.arguments[i+1] }
        if CommandLine.arguments.contains("--no-avx") { avxToggle.state = .off; avxChanged() }
        if let i = CommandLine.arguments.firstIndex(of: "--prefix"), CommandLine.arguments.count > i+1 { host.prefixOverride = URL(fileURLWithPath: CommandLine.arguments[i+1]) }
        if let i = CommandLine.arguments.firstIndex(of: "--profile"), CommandLine.arguments.count > i+1 {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i+1]))
                let profile = try JSONDecoder().decode(WrapperProfile.self, from: data)
                wrapperMode = true
                let executable = try profile.resolvedExecutable()
                select(executable)
                guard game != nil else { throw HostError.message("The saved executable could not be inspected.") }
                host.workingDirectoryOverride = profile.resolvedWorkingDirectory(for: executable)
                host.displayPreferences = profile.displayPreferences ?? [:]
                guard let runtime = RuntimeProfile(rawValue: profile.runtime) else { throw HostError.message("Unknown runtime in profile: " + profile.runtime) }
                runtimePopup.selectItem(withTitle: runtime.rawValue)
                runtimeChanged()
                host.runtimeID = profile.runtimeID ?? runtime.stableRuntimeID
                host.prefixOverride = profile.prefix.map { URL(fileURLWithPath: $0) }
                host.advertiseAVX = profile.advertiseAVX; avxToggle.state = profile.advertiseAVX ? .on : .off
                args.stringValue = String(decoding: try JSONEncoder().encode(profile.arguments), as: UTF8.self)
                env.stringValue = String(decoding: try JSONEncoder().encode(profile.environment), as: UTF8.self)
                window.title = URL(fileURLWithPath: profile.executable).deletingPathExtension().lastPathComponent
                run()
                if host.process != nil { window.orderOut(nil); NSApp.setActivationPolicy(.accessory) }
            } catch { append("Wrapper profile error: " + error.localizedDescription + "\n"); let alert = NSAlert(); alert.messageText = "Game unavailable"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--launch") { run() }
    }
    func append(_ message:String) {
        library.diagnostics += message
        if library.diagnostics.count > 200000 { library.diagnostics = String(library.diagnostics.suffix(150000)) }
        logs.textStorage?.append(NSAttributedString(string:message, attributes: [.foregroundColor: NSColor.textColor, .font: NSFont.monospacedSystemFont(ofSize:11, weight:.regular)]))
        if logs.string.count > 200000 { logs.textStorage?.deleteCharacters(in:NSRange(location:0,length:50000)) }
        logs.scrollToEndOfDocument(nil)
    }
    // Selecting an existing library game should never re-inspect its
    // executable from external storage. Import still performs the initial
    // inspection; subsequent selections reuse the result in memory.
    private var gameInfoCache: [String: GameInfo] = [:]

    private func cachedGameInfo(for url: URL) throws -> GameInfo {
        // Fastest path: already cached during this process.
        if let cached = gameInfoCache[url.path] {
            return cached
        }

        // Persistent fast path: use metadata already stored in Library.json.
        if let saved = library.games.first(where: { $0.path == url.path }),
           let architecture = saved.architecture,
           let graphics = saved.graphics,
           let imports = saved.imports {
            let info = GameInfo(
                url: url,
                architecture: architecture,
                graphics: graphics,
                imports: imports
            )
            gameInfoCache[url.path] = info
            return info
        }

        // Migration/import path: inspect once, then persist the result.
        let inspected = try GameInfo.inspect(url)
        gameInfoCache[url.path] = inspected

        if let index = library.games.firstIndex(where: { $0.path == url.path }) {
            library.games[index].architecture = inspected.architecture
            library.games[index].graphics = inspected.graphics
            library.games[index].imports = inspected.imports
            library.save()
        }

        return inspected
    }

    func select(_ url:URL) {
        guard !library.running else { return }
        if url.pathExtension.lowercased() == "app" { importExistingWrap(url); return }
        do {
            var url = url
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let candidates = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "exe" && !$0.lastPathComponent.lowercased().contains("unins") && !$0.lastPathComponent.lowercased().contains("crash") }.sorted { $0.path < $1.path }
                guard !candidates.isEmpty else { throw HostError.message("No Windows executables found in this directory.") }
                if candidates.count == 1 { url = candidates[0] }
                else { let chooser = NSOpenPanel(); chooser.title = "Select the game's executable"; chooser.directoryURL = url; chooser.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]; guard chooser.runModal() == .OK, let chosen = chooser.url else { return }; url = chosen }
            }
            let selectionStart = CFAbsoluteTimeGetCurrent()
            func selectionMark(_ label: String) {
                let elapsed = CFAbsoluteTimeGetCurrent() - selectionStart
                fputs(String(format: "[CrossPlay Selection] %.3fs  %@\n", elapsed, label), stderr)
            }

            selectionMark("begin")

            let g = try cachedGameInfo(for: url)
            game = g
            selectionMark("GameInfo ready")

            if !library.games.contains(where: { $0.path == url.path }) {
                library.games.append(LibraryGame(path: url.path))
                library.save()
            }
            selectionMark("library membership ready")

            library.selected = url.path
            library.section = "My Games"
            selectionMark("selection assigned")

            if let saved = library.current {
                selectionMark("configure begin")
                configure(saved)
                selectionMark("configure end")
            }

            library.status = "Imported • Gameplay status unverified"
            selectionMark("status ready")

            let prefixPath = host.prefix(for: g).path
            selectionMark("prefix calculated")

            info.stringValue = "Game: \(url.lastPathComponent)\nArchitecture: \(g.architecture)\nGraphics API: \(g.graphics)\nCompatibility environment: isolated Wine / Rosetta / GPTK 4\n\(prefixPath)"
            launchButton.isEnabled = g.architecture == "x86-64 Windows"

            selectionMark("finished") }
        catch { game = nil; launchButton.isEnabled = false; append(error.localizedDescription + "\n") }
    }
    func chooseExistingWrap() {
        let panel = NSOpenPanel()
        panel.title = "Add Existing CrossPlay Wrap"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importExistingWrap(url) }
    }
    func importExistingWrap(_ app: URL) {
        guard !library.running else { return }
        do {
            let imported = try WrapperImporter.read(app)
            var saved = library.games.first { $0.path == imported.game.path } ?? imported.game
            // The chosen wrap supplies launch settings; retain existing library artwork.
            let artwork = saved
            saved = imported.game
            saved.dependencyRequirements = artwork.dependencyRequirements
            saved.dependencyInspectionStamp = artwork.dependencyInspectionStamp
            saved.artworkPath = artwork.artworkPath
            saved.artworkSource = artwork.artworkSource
            saved.artworkTitle = artwork.artworkTitle
            saved.artworkAppID = artwork.artworkAppID
            if let index = library.games.firstIndex(where: { $0.path == saved.path }) { library.games[index] = saved }
            else { library.games.append(saved) }
            library.selected = saved.path
            library.section = "My Games"
            library.save()
            if saved.artworkPath == nil, let data = imported.iconData {
                do { try library.storeArtwork(data, for: saved.path, source: "existing-wrap", title: saved.name, appID: nil) }
                catch { append("Wrap imported, but its icon could not be saved: " + error.localizedDescription + "\n") }
            }
            game = imported.info
            configure(library.current ?? saved)
            launchButton.isEnabled = imported.info.architecture == "x86-64 Windows"
            library.status = "Added existing wrap: " + saved.name
        } catch {
            library.status = "Could not add wrap: " + error.localizedDescription
            append(library.status + "\n")
            let alert = NSAlert(); alert.messageText = "Could not add wrap"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    @objc func runtimeChanged() {
        guard let title = runtimePopup.selectedItem?.title,
              let profile = RuntimeProfile(rawValue: title)
        else { return }

        host.runtimeProfile = profile
        host.runtimeID = profile.stableRuntimeID

        if profile == .journeyCompatible {
            avxToggle.state = .on
            host.advertiseAVX = true
        }

        if let g = game {
            info.stringValue =
                "Game: \(g.url.lastPathComponent)\n" +
                "Architecture: \(g.architecture)\n" +
                "Graphics API: \(g.graphics)\n" +
                "Runtime: \(host.runtimeID ?? profile.rawValue)\n" +
                "Prefix: \(host.prefix(for: g).path)"
        }
    }

    @objc func avxChanged() {
        host.advertiseAVX = avxToggle.state == .on
    }

    @objc func stopGame() {
        do { try host.stop() }
        catch { append(error.localizedDescription + "\n") }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    @objc func choose() { let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension:"exe") ?? .data]; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true; if panel.runModal() == .OK { for url in panel.urls { select(url) } } }
    @objc func toggleLogs(_ sender:NSButton) { logs.enclosingScrollView?.isHidden = sender.state != .on }
    @objc func run() {
        guard let g = game else { return }
        do {
            let a = args.stringValue.isEmpty ? [] : try JSONDecoder().decode([String].self,from:Data(args.stringValue.utf8))
            let e = env.stringValue.isEmpty ? [:] : try JSONDecoder().decode([String:String].self,from:Data(env.stringValue.utf8))
            guard !library.running else { return }
            library.running = true
            launchButton.isEnabled = false
            library.status = "Checking Windows dependencies…"
            let path = g.url.path
            _ = try host.selectedRuntimeRoot()
            let selectedID = host.runtimeID
            let prefix = host.prefix(for: g)
            let stamp = inspectionStamp(g.url)
            let cached = library.current.flatMap { saved -> GameInfo? in
                saved.dependencyInspectionStamp == stamp ? gameInfoCache[g.url.path] : nil
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let inspection = Result { try cached ?? GameInfo.inspect(g.url) }
                DispatchQueue.main.async {
                    do {
                        let inspected = try inspection.get()
                        guard self.game?.url.path == path, self.host.runtimeID == selectedID, self.host.prefix(for: g) == prefix else {
                            throw HostError.message("Game selection changed during dependency inspection. Launch again.")
                        }
                        self.gameInfoCache[path] = inspected
                        self.game = inspected
                        let required = self.dependencyManager.requirements(inspected, manual: self.library.current?.dependencyRequirements ?? [])
                        let missing = required.filter { !self.dependencyManager.verified($0, prefix: prefix, imports: inspected.imports) }
                        if !missing.isEmpty {
                            let alert = DependencyPrompts.required(missing, prefix: prefix, runtimeID: selectedID ?? "unknown")
                            guard alert.runModal() == .alertFirstButtonReturn else { self.endDependencyWork(); return }
                            self.installDependencies(missing, info: inspected, relaunch: { self.startGame(inspected, arguments: a, variables: e) })
                        } else { self.startGame(inspected, arguments: a, variables: e) }
                    } catch { self.dependencyError(error) }
                }
            }
        } catch { library.record { $0.compatibilityStatus = "Failed" }; library.status = error.localizedDescription; append("Error: " + error.localizedDescription + "\n"); if wrapperMode { let alert = NSAlert(); alert.messageText = "Game could not start"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil) } }
    }
    func inspectionStamp(_ url: URL) -> String {
        [url, url.deletingLastPathComponent().appendingPathComponent("UnityPlayer.dll")].map {
            let values = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        }.joined(separator: "|") + "|dependencies-v2"
    }
    func endDependencyWork() {
        library.running = false; launchButton.isEnabled = true
        library.status = "Windows dependency check finished"
        refreshDependencySummary()
    }
    func dependencyError(_ error: Error) {
        endDependencyWork(); library.status = error.localizedDescription
        append("Dependency error: " + error.localizedDescription + "\n")
        let alert = NSAlert(); alert.messageText = "Windows dependency operation failed"
        alert.informativeText = error.localizedDescription + "\nDetails are available in CrossPlay Logs."
        alert.runModal()
    }
    func startGame(_ info: GameInfo, arguments: [String], variables: [String: String]) {
        do {
            try host.launch(info, arguments: arguments, variables: variables)
            library.record { $0.architecture = info.architecture; $0.imports = info.imports; $0.graphics = info.graphics; $0.dependencyInspectionStamp = self.inspectionStamp(info.url) }
            library.running = true; launchButton.isEnabled = false
            library.status = "Game process started • Gameplay unverified"
            if wrapperMode { window.orderOut(nil); NSApp.setActivationPolicy(.accessory) }
        } catch { dependencyError(error) }
    }
    func installDependencies(_ definitions: [GameDependencyDefinition], info: GameInfo, repair: Bool = false, relaunch: (() -> Void)?) {
        guard let first = definitions.first else {
            endDependencyWork()
            if let relaunch { relaunch() } else { manageDependencies() }
            return
        }
        library.running = true; launchButton.isEnabled = false
        library.status = "Downloading / installing " + first.displayName
        Task { @MainActor in
            do {
                let installer = try await dependencyManager.download(first)
                let currentStatus = try dependencyManager.status(first, info: info, runtimeID: host.runtimeID ?? "", prefix: host.prefix(for: info))
                let needsRepair = repair || currentStatus == "Needs repair"
                try dependencyManager.install(first, installer: installer, info: info, host: host, repair: needsRepair) { result in
                    switch result {
                    case .success:
                        self.library.record {
                            var ids = $0.dependencyRequirements ?? []
                            if !ids.contains(first.id) { ids.append(first.id) }
                            $0.dependencyRequirements = ids
                            if $0.runtimeID == nil { $0.runtimeID = self.host.runtimeID }
                        }
                        self.installDependencies(Array(definitions.dropFirst()), info: info, repair: repair, relaunch: relaunch)
                    case .failure(let error): self.dependencyError(error)
                    }
                }
            } catch { dependencyError(error) }
        }
    }
    func manageDependencies() {
        guard let selected = game, !library.running, host.process == nil else { return }
        library.running = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try GameInfo.inspect(selected.url) }
            DispatchQueue.main.async {
                self.endDependencyWork()
                do { let info = try result.get(); self.game = info; self.presentDependencies(info) }
                catch { self.dependencyError(error) }
            }
        }
    }
    func presentDependencies(_ info: GameInfo) {
        do {
            let prefix = host.prefix(for: info)
            guard let runtimeID = host.runtimeID ?? host.runtimeProfile.stableRuntimeID else { throw HostError.message("Select an installed runtime first.") }
            let detected = dependencyManager.requirements(info, manual: library.current?.dependencyRequirements ?? []).map(\.id)
            let alert = NSAlert(); alert.messageText = "Windows Dependencies"
            alert.informativeText = "Runtime: " + runtimeID + "\nPrefix: " + prefix.path + "\nSelect components to install or repair. Downloads come from Microsoft."
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
            var checks: [NSButton] = []
            for definition in GameDependencyManager.catalog {
                let status = try dependencyManager.status(definition, info: info, runtimeID: runtimeID, prefix: prefix)
                let check = NSButton(checkboxWithTitle: definition.displayName + " — " + status + (detected.contains(definition.id) ? " • Required" : ""), target: nil, action: nil)
                check.state = detected.contains(definition.id) ? .on : .off
                checks.append(check); stack.addArrangedSubview(check)
            }
            stack.frame = NSRect(x: 0, y: 0, width: 640, height: 240)
            alert.accessoryView = stack
            alert.addButton(withTitle: "Install Missing"); alert.addButton(withTitle: "Repair Selected"); alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            guard response != .alertThirdButtonReturn else { return }
            let selected = zip(GameDependencyManager.catalog, checks).filter { $0.1.state == .on }.map { $0.0 }
            library.record { $0.dependencyRequirements = selected.map(\.id) }
            let install = response == .alertSecondButtonReturn ? selected : selected.filter { !dependencyManager.verified($0, prefix: prefix, imports: info.imports) }
            guard !install.isEmpty else { return }
            installDependencies(install, info: info, repair: response == .alertSecondButtonReturn, relaunch: nil)
        } catch { dependencyError(error) }
    }
    func refreshDependencySummary() {
        guard let info = game else { return }
        let required = dependencyManager.requirements(info, manual: library.current?.dependencyRequirements ?? [])
        let prefix = host.prefix(for: info)
        library.dependencySummary = required.map {
            $0.displayName + " — " + ((try? dependencyManager.status($0, info: info, runtimeID: host.runtimeID ?? "", prefix: prefix)) ?? "State unavailable")
        }
        if required.isEmpty { library.dependencySummary = ["No requirements in cached EXE inspection. Manage Dependencies can check again or select components manually."] }
    }
    func configure(_ saved: LibraryGame) {
        guard host.process == nil, !library.running else { return }
        runtimePopup.selectItem(withTitle: saved.runtime)
        let resolvedRuntime = RuntimeProfile(rawValue: saved.runtime == RuntimeProfile.automatic.rawValue ? (saved.successfulRuntime ?? saved.runtime) : saved.runtime) ?? .automatic
        host.runtimeProfile = resolvedRuntime
        host.runtimeID = saved.runtimeID ?? resolvedRuntime.stableRuntimeID ?? host.registry.defaultRuntime?.runtimeID ?? RuntimeProfile.current.stableRuntimeID
        host.prefixOverride = saved.prefix.map { URL(fileURLWithPath: $0) }
        host.workingDirectoryOverride = saved.workingDirectory.map { URL(fileURLWithPath: $0) }
        host.displayPreferences = saved.displayPreferences ?? [:]
        host.advertiseAVX = saved.avx; avxToggle.state = saved.avx ? .on : .off
        refreshDependencySummary()
        args.stringValue = saved.arguments; env.stringValue = saved.environment
    }
    func createWrapper() {
        guard let game = game else { return }
        let panel = NSSavePanel(); panel.title = "Create Mac App"; panel.nameFieldStringValue = game.url.deletingPathExtension().lastPathComponent + ".app"; panel.canCreateDirectories = true; panel.allowedContentTypes = [.applicationBundle]; panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw HostError.message("Choose a new destination to preserve the existing app.") }
            guard let saved = library.current else { return }
            let profile = try WrapperProfile.capture(game: game, host: host, saved: saved,
                arguments: args.stringValue.isEmpty ? [] : JSONDecoder().decode([String].self, from: Data(args.stringValue.utf8)),
                environment: env.stringValue.isEmpty ? [:] : JSONDecoder().decode([String:String].self, from: Data(env.stringValue.utf8)))
            try WrapperGenerator.create(profile: profile, game: saved, destination: destination)
            library.record { $0.wrapped = true }
            library.status = "Created " + destination.lastPathComponent
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { library.status = error.localizedDescription; append("Wrapper: " + error.localizedDescription + "\n") }
    }
    func createBatchWrappers() {
        let games = library.games.filter { library.batchSelection.contains($0.path) }
        guard !games.isEmpty else { library.status = "Select games using their Wrap checkboxes."; return }
        let panel = NSOpenPanel(); panel.title = "Choose folder for game apps"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var succeeded = 0, failures: [String] = []
        for saved in games {
            do {
                let info = try GameInfo.inspect(URL(fileURLWithPath: saved.path))
                let execution = ExecutionHost(root: host.root, storage: host.storage)
                let resolvedRuntime = RuntimeProfile(rawValue: saved.runtime == "Automatic" ? (saved.successfulRuntime ?? saved.runtime) : saved.runtime) ?? .automatic
                execution.runtimeProfile = resolvedRuntime
                execution.runtimeID = saved.runtimeID ?? resolvedRuntime.stableRuntimeID
                execution.displayPreferences = saved.displayPreferences ?? [:]; execution.advertiseAVX = saved.avx; execution.prefixOverride = saved.prefix.map { URL(fileURLWithPath: $0) }; execution.workingDirectoryOverride = saved.workingDirectory.map { URL(fileURLWithPath: $0) }
                let profile = try WrapperProfile.capture(game: info, host: execution, saved: saved, arguments: saved.arguments.isEmpty ? [] : JSONDecoder().decode([String].self, from: Data(saved.arguments.utf8)), environment: saved.environment.isEmpty ? [:] : JSONDecoder().decode([String:String].self, from: Data(saved.environment.utf8)))
                let name = saved.name.replacingOccurrences(of: "/", with: "-")
                try WrapperGenerator.create(profile: profile, game: saved, destination: folder.appendingPathComponent(name + ".app"))
                if let i = library.games.firstIndex(where: { $0.path == saved.path }) { library.games[i].wrapped = true }; succeeded += 1
            } catch { failures.append(saved.name + ": " + error.localizedDescription) }
        }
        library.save(); library.status = "Wrapped \(succeeded) of \(games.count) games"
        append(failures.joined(separator: "\n") + "\n")
    }
    func updateExistingWrapperIcon() {
        guard let selected = library.current else { return }
        let chooser = NSOpenPanel(); chooser.title = "Update icon for " + selected.name; chooser.allowedContentTypes = [.applicationBundle]; chooser.canChooseDirectories = false; chooser.treatsFilePackagesAsDirectories = false
        guard chooser.runModal() == .OK, let app = chooser.url else { return }
        do { try GameArtwork.updateWrapper(for: selected, app: app, host: Bundle.main.bundleURL); library.status = "Updated " + app.lastPathComponent + " • original app backed up"; NSWorkspace.shared.activateFileViewerSelecting([app]) }
        catch { library.status = error.localizedDescription }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { host.process == nil }
}
// CLI and native UI use the same transactional generator.
if let index = CommandLine.arguments.firstIndex(of: "--create-wrapper-request") {
    do {
        guard CommandLine.arguments.count > index + 2 else { throw HostError.message("Expected request JSON and destination app.") }
        let request = try JSONDecoder().decode(WrapperProfile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        let game = try GameInfo.inspect(try request.resolvedExecutable())
        guard let runtime = RuntimeProfile(rawValue: request.runtime) else { throw HostError.message("Unknown runtime.") }
        let host = ExecutionHost(root: Bundle.main.resourceURL!.appendingPathComponent("Runtime"), storage: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossPlay"))
        host.runtimeProfile = runtime
        host.runtimeID = request.runtimeID ?? runtime.stableRuntimeID
        host.advertiseAVX = request.advertiseAVX
        host.prefixOverride = request.prefix.map { URL(fileURLWithPath: $0) }
        host.workingDirectoryOverride = request.workingDirectory.map { URL(fileURLWithPath: $0) }
        var saved = LibraryGame(path: game.url.path); saved.title = request.gameName
        let library = LibraryModel()
        if let existing = library.games.first(where: { $0.path == game.url.path }) { saved = existing }
        if let icon = request.icon, icon != "GameIcon.icns" { saved.artworkPath = icon; saved.artworkSource = "cli-selected" }
        var profile = try WrapperProfile.capture(game: game, host: host, saved: saved, arguments: request.arguments, environment: request.environment)
        profile.displayPreferences = request.displayPreferences ?? saved.displayPreferences
        try WrapperGenerator.create(profile: profile, game: saved, destination: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
// Maintenance helper only updates a wrapper whose profile matches the supplied executable.
if let index = CommandLine.arguments.firstIndex(of: "--update-wrapper-icon") {
    do {
        guard CommandLine.arguments.count > index + 3 else { throw HostError.message("Expected artwork image, wrapper app and game executable.") }
        var game = LibraryGame(path: CommandLine.arguments[index + 3]); game.artworkPath = CommandLine.arguments[index + 1]
        try GameArtwork.updateWrapper(for: game, app: URL(fileURLWithPath: CommandLine.arguments[index + 2]), host: Bundle.main.bundleURL)
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
// Headless packaging helper: render artwork without opening the UI or launching a game.
if let index = CommandLine.arguments.firstIndex(of: "--make-game-icon") {
    do {
        guard CommandLine.arguments.count > index + 3 else { throw HostError.message("Expected image, output ICNS and game name.") }
        let source = CommandLine.arguments[index + 1]
        let image = source == "-" ? nil : NSImage(contentsOfFile: source)
        if source != "-" && image == nil { throw HostError.message("Invalid game artwork image.") }
        try GameArtwork.makeIcon(image: image, name: CommandLine.arguments[index + 3], at: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
let app = NSApplication.shared
let delegate = Delegate()
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
