import CryptoKit
import Foundation
import SwiftUI

struct UsageWindow: Equatable {
    let label: String
    let used: Double
    let resetsAt: Date?
}

struct UsageAccount: Identifiable, Equatable {
    let id: String
    let kind: AgentKind
    let name: String
    let detail: String?
    let windows: [UsageWindow]
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
            if kinds.contains(.omp) { fresh += await Self.ompAccounts() }
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
                  let five = window("5h", usage["five_hour"]), let seven = window("7d", usage["seven_day"]) else {
                NSLog("Niche could not fetch %@ usage", folder)
                continue
            }
            let suffix = folder.dropFirst(".claude".count).drop { $0 == "-" }
            found.append(UsageAccount(id: "claude-\(folder)", kind: .claude, name: suffix.isEmpty ? "claude" : String(suffix),
                                      detail: nil, windows: [five, seven]))
        }
        return found

        func window(_ label: String, _ value: Any?) -> UsageWindow? {
            guard let entry = value as? [String: Any], let used = entry["utilization"] as? Double else { return nil }
            let reset = (entry["resets_at"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
            }
            return UsageWindow(label: label, used: used / 100, resetsAt: reset)
        }
    }

    nonisolated private static func ompAccounts() async -> [UsageAccount] {
        let db = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".omp/agent/agent.db").path
        let query = """
            select u.provider, u.limit_id, u.label, u.window_label, u.used_fraction, u.resets_at from usage_history u
            join (select max(id) id from usage_history group by account_key, limit_id) latest on latest.id = u.id
            where u.used_fraction is not null and u.window_label is not null and u.resets_at > 0
              and exists (select 1 from auth_credentials a where a.provider = u.provider and a.disabled_cause is null
                          and instr(u.account_key, a.identity_key) > 0)
            """
        let output = AgentMonitor.run("/usr/bin/sqlite3", ["-readonly", "-json", db, query])
        guard let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { return [] }
        let now = Date()
        var cards: [String: (name: String, detail: String?, windows: [String: (span: Int, entries: [(used: Double, reset: Date)])])] = [:]
        for row in rows {
            guard let provider = row["provider"] as? String, let limit = row["limit_id"] as? String, let label = row["label"] as? String,
                  let windowLabel = row["window_label"] as? String, let used = row["used_fraction"] as? Double,
                  let resetsAt = row["resets_at"] as? Double, let span = span(of: windowLabel) else { continue }
            let card: (name: String, detail: String?)
            switch provider {
            case "anthropic":
                guard limit == "anthropic:5h" || limit == "anthropic:7d" else { continue }
                card = ("claude", nil)
            case "google-antigravity": card = (label.replacingOccurrences(of: " (shared)", with: "").lowercased(), "antigravity")
            case "openai-codex": card = ("codex", nil)
            default: card = (provider, nil)
            }
            let id = "omp-\(provider)-\(card.name)"
            let reset = Date(timeIntervalSince1970: resetsAt / 1000)
            cards[id, default: (card.name, card.detail, [:])].windows[span.label, default: (span.seconds, [])].entries.append((used, reset))
        }
        return cards.map { id, card in
            let windows = card.windows.sorted { $0.value.span < $1.value.span }.map { label, window in
                let used = window.entries.map { $0.reset < now ? 0 : $0.used }.reduce(0, +) / Double(window.entries.count)
                return UsageWindow(label: label, used: used, resetsAt: window.entries.map(\.reset).filter { $0 > now }.min())
            }
            return UsageAccount(id: id, kind: .omp, name: card.name, detail: card.detail, windows: windows)
        }

        func span(of window: String) -> (label: String, seconds: Int)? {
            switch window.lowercased() {
            case "daily": return ("1d", 86_400)
            case "weekly": return ("7d", 604_800)
            default:
                let parts = window.lowercased().split(separator: " ")
                guard parts.count == 2, let count = Int(parts[0]) else { return nil }
                if parts[1].hasPrefix("hour") { return ("\(count)h", count * 3_600) }
                if parts[1].hasPrefix("day") { return ("\(count)d", count * 86_400) }
                return nil
            }
        }
    }
}

struct UsageStrip: View {
    let accounts: [UsageAccount]

    static func columns(for accounts: [UsageAccount]) -> Int {
        accounts.count == 4 ? 2 : min(accounts.count, 3)
    }

    static func height(for accounts: [UsageAccount]) -> CGFloat {
        let rows = CGFloat((accounts.count + columns(for: accounts) - 1) / columns(for: accounts))
        return rows * cardHeight(for: accounts) + (rows - 1) * 6
    }

    private static func cardHeight(for accounts: [UsageAccount]) -> CGFloat {
        28 + 14 * CGFloat(accounts.reduce(0) { max($0, $1.windows.count) })
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: Self.columns(for: accounts)), spacing: 6) {
            ForEach(accounts) { account in
                UsageCard(account: account)
                    .frame(height: Self.cardHeight(for: accounts))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(height: Self.height(for: accounts))
    }
}

private struct UsageCard: View {
    let account: UsageAccount
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                AgentGlyph(kind: account.kind, size: 10)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        name
                        if let detail = account.detail {
                            Text(detail)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    name
                }
            }
            ForEach(account.windows, id: \.label) { meter($0) }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(isHovered ? 0.1 : 0.06)))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var name: some View {
        Text(account.name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
    }

    private func meter(_ window: UsageWindow) -> some View {
        let used = min(max(window.used, 0), 1)
        let tint = used >= 0.85 ? Color(red: 1, green: 0.36, blue: 0.3)
            : account.kind == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.55, green: 0.76, blue: 1)
        let reset = window.resetsAt.map { Self.short(max($0.timeIntervalSinceNow, 0)) } ?? "–"
        return HStack(spacing: 5) {
            Text(window.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize()
                .frame(width: 19, alignment: .leading)
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
