import AppKit
import Foundation

@MainActor
@Observable
final class Updater {
    struct Release: Equatable {
        let version: String
        let notes: String?
        let dmg: URL
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available, installing
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var latest: Release?
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    @ObservationIgnored private var timer: Timer?

    private static let latestRelease = URL(string: "https://api.github.com/repos/raihanadf/niche/releases/latest")!

    func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func check() async {
        guard phase != .checking, phase != .installing else { return }
        phase = .checking
        do {
            var request = URLRequest(url: Self.latestRelease)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as! HTTPURLResponse).statusCode
            if status == 404 {
                latest = nil
                phase = .upToDate
                return
            }
            guard status == 200 else { throw UpdateError.http(status) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true })?["browser_download_url"] as? String,
                  let dmgURL = URL(string: dmg) else { throw UpdateError.malformed }
            let release = Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                                  notes: json["body"] as? String, dmg: dmgURL)
            latest = release
            phase = Self.isNewer(release.version, than: current) ? .available : .upToDate
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func install() async {
        guard phase == .available, let latest else { return }
        phase = .installing
        do {
            let (download, _) = try await URLSession.shared.download(from: latest.dmg)
            let work = FileManager.default.temporaryDirectory.appending(path: "niche-update-\(UUID().uuidString)")
            let mount = work.appending(path: "mount")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try await Self.run("/usr/bin/hdiutil", ["attach", download.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
            let staged = work.appending(path: "Niche.app")
            try await Self.run("/usr/bin/ditto", [mount.appending(path: "Niche.app").path, staged.path])
            try await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])

            let installed = Bundle.main.bundleURL
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", installed.path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private enum UpdateError: LocalizedError {
        case http(Int), malformed, tool(String, Int32)
        var errorDescription: String? {
            switch self {
            case .http(let status): "github answered \(status)"
            case .malformed: "the latest release has no dmg"
            case .tool(let tool, let status): "\(tool) failed with \(status)"
            }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError.tool(URL(fileURLWithPath: tool).lastPathComponent, process.terminationStatus)
            }
        }.value
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = installed.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
