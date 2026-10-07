import Foundation
import CryptoKit

struct GameDependencyDefinition: Identifiable {
    let family: String
    let architecture: String
    let version: String
    let source: URL
    let dlls: [String]
    // Definitions can later supply another prerequisite product and its installer options.
    var identifierPrefix = "vc"
    var productName = "Microsoft Visual C++"
    var customInstallerArguments: [String]?
    var detectionMethod: String { "Native PE libraries matching the requested architecture" }
    var id: String { "\(identifierPrefix)-\(family)-\(architecture)" }
    var displayName: String { "\(productName) \(family == "v14" ? "modern v14 (2015–2022+)" : family) \(architecture)" }
    var installerFilename: String { id + ".exe" }
    var installerArguments: [String] { arguments(repair: false) }
    func arguments(repair: Bool) -> [String] {
        if let customInstallerArguments { return customInstallerArguments }
        if family == "2010" { return (repair ? ["/repair"] : []) + ["/q", "/norestart"] }
        return [repair ? "/repair" : "/install", "/quiet", "/norestart"]
    }
}

struct GameDependencyState: Codable {
    let gamePath: String
    let runtimeID: String
    let prefixPath: String
    let dependencyID: String
    var status: String
    var installedAt: Date?
    var verifiedAt: Date
    var installerSHA256: String?
    var detail: String?
}

// These records describe installations, never runtime selection. Read-only checks do not save.
final class GameDependencyManager {
    static let catalog: [GameDependencyDefinition] = ["x64", "x86"].flatMap { arch in
        [
            GameDependencyDefinition(family: "v14", architecture: arch, version: "modern v14", source: URL(string: "https://aka.ms/vc14/vc_redist.\(arch).exe")!, dlls: ["vcruntime140.dll", "msvcp140.dll"]),
            GameDependencyDefinition(family: "2013", architecture: arch, version: "12.0.40664.0", source: URL(string: "https://aka.ms/highdpimfc2013\(arch)enu")!, dlls: ["msvcr120.dll", "msvcp120.dll"]),
            GameDependencyDefinition(family: "2012", architecture: arch, version: "11.0.61030.0", source: URL(string: "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_\(arch).exe")!, dlls: ["msvcr110.dll", "msvcp110.dll"]),
            GameDependencyDefinition(family: "2010", architecture: arch, version: "10.0.40219.325", source: URL(string: "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_\(arch).exe")!, dlls: ["msvcr100.dll", "msvcp100.dll"])
        ]
    }
    let stateURL: URL
    let cache: URL
    private var installerHost: ExecutionHost?
    init(support: URL, cache: URL? = nil) {
        stateURL = support.appendingPathComponent("DependencyState.json")
        self.cache = cache ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/CrossPlay/DependencyInstallers")
    }
    func records() throws -> [GameDependencyState] {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return [] }
        return try JSONDecoder().decode([GameDependencyState].self, from: Data(contentsOf: stateURL))
    }
    func requirements(_ info: GameInfo, manual: [String] = []) -> [GameDependencyDefinition] {
        let arch = info.architecture == "x86-64 Windows" ? "x64" : (info.architecture.hasPrefix("x86 Windows") ? "x86" : "")
        return Self.catalog.filter { d in
            manual.contains(d.id) || (d.architecture == arch && info.imports.contains { name in
                d.dlls.contains(name.lowercased()) || (d.family == "v14" && name.lowercased() == "vcruntime140_1.dll")
            })
        }
    }
    // Read PE machine and reject Wine builtin stubs; file existence alone is insufficient.
    static func nativeDLL(_ url: URL, architecture: String) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 65536), data.count > 64,
              data[0] == 77, data[1] == 90,
              !String(decoding: data, as: UTF8.self).contains("Wine builtin DLL") else { return false }
        let pe = Int(data[60]) | Int(data[61]) << 8 | Int(data[62]) << 16 | Int(data[63]) << 24
        guard pe >= 64, pe + 6 <= data.count, Array(data[pe..<pe+4]) == [80,69,0,0] else { return false }
        let machine = Int(data[pe+4]) | Int(data[pe+5]) << 8
        return machine == (architecture == "x64" ? 0x8664 : 0x14c)
    }
    func verified(_ definition: GameDependencyDefinition, prefix: URL, imports: [String] = []) -> Bool {
        let folder = prefix.appendingPathComponent(
            "drive_c/windows/" + (definition.architecture == "x64" ? "system32" : "syswow64")
        )

        var dlls = definition.dlls
        if definition.family == "v14",
           imports.contains(where: { $0.lowercased() == "vcruntime140_1.dll" }) {
            dlls.append("vcruntime140_1.dll")
        }

        return dlls.allSatisfy {
            Self.nativeDLL(
                folder.appendingPathComponent($0),
                architecture: definition.architecture
            )
        }
    }

    func status(_ definition: GameDependencyDefinition, info: GameInfo, runtimeID: String, prefix: URL) throws -> String {
        if verified(definition, prefix: prefix, imports: info.imports) { return "Installed (prefix verified)" }
        let old = try records().first { $0.gamePath == info.url.path && $0.runtimeID == runtimeID && $0.prefixPath == prefix.path && $0.dependencyID == definition.id }
        return old?.status == "installed" ? "Needs repair" : "Missing"
    }
    func remember(_ definition: GameDependencyDefinition, info: GameInfo, runtimeID: String, prefix: URL, success: Bool, hash: String?, detail: String?) throws {
        var values = try records()
        values.removeAll { $0.gamePath == info.url.path && $0.runtimeID == runtimeID && $0.prefixPath == prefix.path && $0.dependencyID == definition.id }
        values.append(GameDependencyState(gamePath: info.url.path, runtimeID: runtimeID, prefixPath: prefix.path, dependencyID: definition.id, status: success ? "installed" : "failed", installedAt: success ? Date() : nil, verifiedAt: Date(), installerSHA256: hash, detail: detail))
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: stateURL, options: .atomic)
    }
    static func official(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "aka.ms" || host == "download.microsoft.com" || host == "download.visualstudio.microsoft.com"
    }
    private final class MicrosoftRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(GameDependencyManager.official) == true ? request : nil)
        }
    }
    func download(_ definition: GameDependencyDefinition) async throws -> URL {
        let destination = cache.appendingPathComponent(definition.installerFilename)
        let receipt = destination.appendingPathExtension("sha256")
        if let stored = try? String(contentsOf: receipt, encoding: .utf8),
           let hash = try? RuntimeRegistry.sha256(destination), stored == hash { return destination }
        let session = URLSession(configuration: .ephemeral, delegate: MicrosoftRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(from: definition.source)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let final = response.url, Self.official(final) else { throw HostError.message("Microsoft installer download failed or redirected outside approved Microsoft hosts.") }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (100_000...100_000_000).contains(size) else { throw HostError.message("Unexpected installer size.") }
        let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
        guard let header = try h.read(upToCount: 2), header == Data([77,90]) else { throw HostError.message("Download is not a Windows installer.") }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(contentsOf: file).write(to: destination, options: .atomic)
        try RuntimeRegistry.sha256(destination).write(to: receipt, atomically: true, encoding: .utf8)
        return destination
    }
    // Reuse ExecutionHost's validated runtime, prefix lock, bottle bootstrap and exact environment.
    // Caller must obtain native user approval before invoking this method.
    func install(_ definition: GameDependencyDefinition, installer: URL, info: GameInfo, host: ExecutionHost, repair: Bool = false, completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard installerHost == nil, host.process == nil else { throw HostError.message("Stop the game or current dependency installation first.") }
        _ = try records() // Fail closed before altering a prefix if persistence is unreadable.
        let prefix = host.prefix(for: info)
        guard let runtimeID = host.runtimeID ?? host.runtimeProfile.stableRuntimeID else { throw HostError.message("Select an installed immutable runtime first.") }
        let worker = ExecutionHost(root: host.root, storage: host.storage, registry: host.registry)
        worker.runtimeProfile = host.runtimeProfile; worker.runtimeID = runtimeID
        worker.prefixOverride = prefix; worker.advertiseAVX = host.advertiseAVX
        worker.log = host.log
        let hash = try RuntimeRegistry.sha256(installer)
        worker.finished = { [weak self] code in
            guard let self else { return }
            self.installerHost = nil

            guard code == 0 || code == 3010 else {
                do {
                    try self.remember(
                        definition,
                        info: info,
                        runtimeID: runtimeID,
                        prefix: prefix,
                        success: false,
                        hash: hash,
                        detail: "Installer exit \(code)"
                    )
                    completion(.failure(HostError.message(
                        "\(definition.displayName) installer failed with exit \(code). See CrossPlay Logs."
                    )))
                } catch {
                    completion(.failure(error))
                }
                return
            }

            // Wine installers may terminate before filesystem updates become visible.
            // Retry verification briefly instead of reporting a false failure.
            DispatchQueue.global(qos: .userInitiated).async {
                var verified = false
                for attempt in 0..<10 {
                    if self.verified(definition, prefix: prefix, imports: info.imports) {
                        verified = true
                        break
                    }
                    if attempt < 9 {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }

                DispatchQueue.main.async {
                    do {
                        try self.remember(
                            definition,
                            info: info,
                            runtimeID: runtimeID,
                            prefix: prefix,
                            success: verified,
                            hash: hash,
                            detail: "Installer exit \(code); post-install verification \(verified ? "passed" : "failed")"
                        )

                        if verified {
                            completion(.success(()))
                        } else {
                            completion(.failure(HostError.message(
                                "\(definition.displayName) installer completed successfully, but CrossPlay could not verify the required DLLs in this game's prefix. See CrossPlay Logs."
                            )))
                        }
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        }
        installerHost = worker
        do {
            // The selected host supports running x86 installers within its 64-bit bottle.
            try worker.launch(GameInfo(url: installer, architecture: "x86-64 Windows", graphics: "Installer", imports: []), arguments: definition.arguments(repair: repair), variables: [:])
        } catch { installerHost = nil; throw error }
    }
}
