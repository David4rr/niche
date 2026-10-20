import CryptoKit
import Foundation
import SwiftUI

struct UsageWindow: Equatable {
    let used: Double
    let resetsAt: Date?
}

struct UsageAccount: Identifiable, Equatable {
    let id: String
    let kind: AgentKind
    let name: String
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
}

@MainActor
@Observable
final class AgentUsage {
    private(set) var accounts: [UsageAccount] = []
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var kinds: Set<AgentKind> = []

    func refresh(kinds: Set<AgentKind>) {
        if kinds == self.kinds, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 300 { return }
        self.kinds = kinds
        fetchedAt = Date()
        Task {
            var fresh = kinds.contains(.claude) ? await Self.claudeAccounts() : []
            if kinds.contains(.omp), let omp = await Self.ompAccount() { fresh.append(omp) }
            let kept = accounts.filter { old in kinds.contains(old.kind) && !fresh.contains { $0.id == old.id } }
            let merged = (fresh + kept).sorted { ($0.kind == .omp ? 1 : 0, $0.id) < ($1.kind == .omp ? 1 : 0, $1.id) }
            guard merged != accounts else { return }
            withAnimation(.spring(Spring(duration: 0.35, bounce: 0.2), blendDuration: 0)) { accounts = merged }
        }
    }

    nonisolated private static func claudeAccounts() async -> [UsageAccount] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: fm.homeDirectoryForCurrentUser, includingPropertiesForKeys: nil) else { return [] }
        var found: [UsageAccount] = []
        for config in entries where config.lastPathComponent.hasPrefix(".claude") && config.hasDirectoryPath {
            let folder = config.lastPathComponent
            let hash = SHA256.hash(data: Data(config.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
            let service = folder == ".claude" ? "Claude Code-credentials" : "Claude Code-credentials-\(hash)"
            let raw = AgentMonitor.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
            guard let stored = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let oauth = stored["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String else { continue }
            if let expires = oauth["expiresAt"] as? Double, expires / 1000 < Date().timeIntervalSince1970 {
                NSLog("Niche skipped %@ usage, its login has expired", folder)
                continue
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let five = window(usage["five_hour"]), let seven = window(usage["seven_day"]) else {
                NSLog("Niche could not fetch %@ usage", folder)
                continue
            }
            let suffix = folder.dropFirst(".claude".count).drop { $0 == "-" }
            found.append(UsageAccount(id: "claude-\(folder)", kind: .claude, name: suffix.isEmpty ? "claude" : String(suffix),
                                      fiveHour: five, sevenDay: seven))
        }
        return found

        func window(_ value: Any?) -> UsageWindow? {
            guard let entry = value as? [String: Any], let used = entry["utilization"] as? Double else { return nil }
            let reset = (entry["resets_at"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
            }
            return UsageWindow(used: used / 100, resetsAt: reset)
        }
    }

    nonisolated private static func ompAccount() async -> UsageAccount? {
        let db = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".omp/agent/agent.db").path
        let query = """
            select u.limit_id, u.used_fraction, u.resets_at from usage_history u
            join (select max(id) id from usage_history where provider = 'anthropic' and limit_id in ('anthropic:5h', 'anthropic:7d')
                  group by account_key, limit_id) latest on latest.id = u.id
            where exists (select 1 from auth_credentials a where a.provider = 'anthropic' and a.disabled_cause is null
                          and u.account_key like '%' || a.identity_key)
            """
        let output = AgentMonitor.run("/usr/bin/sqlite3", ["-readonly", "-json", db, query])
        guard let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]], !rows.isEmpty else { return nil }
        let now = Date()
        func pool(_ limit: String) -> UsageWindow {
            let entries = rows.filter { $0["limit_id"] as? String == limit }.compactMap { row -> (used: Double, reset: Date?)? in
                guard let used = row["used_fraction"] as? Double else { return nil }
                let reset = (row["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                return (reset.map { $0 < now } == true ? 0 : used, reset)
            }
            let next = entries.compactMap(\.reset).filter { $0 > now }.min()
            return UsageWindow(used: entries.isEmpty ? 0 : entries.map(\.used).reduce(0, +) / Double(entries.count), resetsAt: next)
        }
        return UsageAccount(id: "omp", kind: .omp, name: "omp", fiveHour: pool("anthropic:5h"), sevenDay: pool("anthropic:7d"))
    }
}

struct UsageStrip: View {
    let accounts: [UsageAccount]
    static let height: CGFloat = 56

    var body: some View {
        HStack(spacing: 6) {
            ForEach(accounts) { account in
                UsageCard(account: account)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(height: Self.height)
    }
}

private struct UsageCard: View {
    let account: UsageAccount
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                AgentGlyph(kind: account.kind, size: 10)
                Text(account.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            meter("5h", account.fiveHour)
            meter("7d", account.sevenDay)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(isHovered ? 0.1 : 0.06)))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func meter(_ label: String, _ window: UsageWindow) -> some View {
        let used = min(max(window.used, 0), 1)
        let tint = used >= 0.85 ? Color(red: 1, green: 0.36, blue: 0.3)
            : account.kind == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.55, green: 0.76, blue: 1)
        let reset = window.resetsAt.map { Self.short(max($0.timeIntervalSinceNow, 0)) } ?? "–"
        return HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 13, alignment: .leading)
            Capsule()
                .fill(.white.opacity(0.1))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(tint).frame(width: max(proxy.size.width * used, used > 0 ? 3 : 0))
                    }
                }
                .frame(height: 4)
            Text(isHovered ? reset : "\(Int((used * 100).rounded()))%")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(isHovered ? 0.55 : 0.8))
                .contentTransition(.interpolate)
                .frame(width: 26, alignment: .trailing)
        }
    }

    private static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 1440 { return "\(minutes / 1440)d" }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(max(minutes, 1))m"
    }
}
