import AppKit
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @Bindable var lab: LabState
    @State private var pane: Pane? = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", music = "Music", agents = "Agents", lockScreen = "Lock Screen", updates = "Updates"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .music: "music.note"
            case .agents: "sparkles"
            case .lockScreen: "lock.fill"
            case .updates: "arrow.down.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .general: .gray
            case .music: Color(red: 1, green: 0.42, blue: 0.55)
            case .agents: Color(red: 0.72, green: 0.5, blue: 0.95)
            case .lockScreen: .blue
            case .updates: .green
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.rawValue)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(pane.tint.gradient))
                }
                .badge(pane == .updates && lab.updater.phase == .available ? 1 : 0)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Form {
                switch pane ?? .general {
                case .general: general
                case .music: music
                case .agents: agents
                case .lockScreen: lockScreen
                case .updates: updates
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane?.rawValue ?? "")
        }
        .frame(width: 640, height: 420)
    }

    private var general: some View {
        Group {
            Section {
                Toggle("Show in menu bar", isOn: $lab.showInMenuBar)
            } footer: {
                Text("Right-click the notch to open these settings when the menu bar icon is hidden.")
            }
            Section {
                Button("Quit Niche") { NSApp.terminate(nil) }
            }
        }
    }

    private var music: some View {
        Section {
            Toggle("Live visualizer", isOn: $lab.liveVisualizer)
        } footer: {
            Text("Live bars follow the playing app's audio. Capturing it makes macOS show its purple recording indicator; with this off the bars move on their own and nothing is captured.")
        }
    }

    private var agents: some View {
        Group {
            Section {
                Toggle("Show agent sessions", isOn: $lab.showAgents)
            } footer: {
                Text("Running agent sessions get a mark in the open notch and their own mode in the feature switcher. Only live sessions are listed.")
            }
            Section("Agents") {
                Toggle(isOn: $lab.showClaude) {
                    Label { Text("Claude Code") } icon: { AgentGlyph(kind: .claude, size: 12) }
                }
                Toggle(isOn: $lab.showOmp) {
                    Label { Text("omp") } icon: { AgentGlyph(kind: .omp, size: 12) }
                }
            }
            .disabled(!lab.showAgents)
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let trusted = AXIsProcessTrusted()
                    LabeledContent("Accessibility") {
                        HStack(spacing: 8) {
                            Text(trusted ? "Allowed" : "Not allowed")
                                .foregroundStyle(trusted ? .green : .orange)
                            if !trusted {
                                Button("Open Settings") {
                                    let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                                    if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Open session on click")
            } footer: {
                Text("Clicking a session switches tmux to its pane and brings the terminal forward. Picking the right terminal tab needs the accessibility permission.")
            }
        }
    }

    private var lockScreen: some View {
        Section {
            Toggle("Show lock indicator", isOn: $lab.showLockIndicator)
        } footer: {
            Text("A padlock sits beside the notch on the lock screen and springs open when you unlock.")
        }
    }

    private var updates: some View {
        let updater = lab.updater
        return Group {
            Section {
                LabeledContent("Installed", value: updater.current)
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        switch updater.phase {
                        case .idle, .checking: ProgressView().controlSize(.small)
                        case .upToDate: Text("Up to date").foregroundStyle(.secondary)
                        case .available: Text("\(updater.latest?.version ?? "") available").foregroundStyle(.green)
                        case .installing: Text("Installing…").foregroundStyle(.secondary)
                        case .failed(let reason): Text(reason).foregroundStyle(.orange).lineLimit(2)
                        }
                        Button("Check now") { Task { await updater.check() } }
                            .disabled(updater.phase == .checking || updater.phase == .installing)
                    }
                }
            } footer: {
                Text("Niche checks GitHub for a new release on launch and every six hours.")
            }
            if let release = updater.latest {
                Section(updater.phase == .available ? "What's new in \(release.version)" : "Latest release, \(release.version)") {
                    Text(LocalizedStringKey(release.notes ?? "No notes for this release."))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if updater.phase == .available || updater.phase == .installing {
                        Button(updater.phase == .installing ? "Installing…" : "Install and restart") {
                            Task { await updater.install() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.phase == .installing)
                    }
                }
            }
        }
    }
}
