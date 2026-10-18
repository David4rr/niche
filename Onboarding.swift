import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

enum OpenAtLogin {
    static var isOn: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Niche could not change open at login: %@", String(describing: error))
            }
        }
    }
}

struct OnboardingView: View {
    let lab: LabState
    let done: () -> Void
    @State private var openAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .padding(.top, 28)
            Text("Welcome to Niche")
                .font(.system(size: 22, weight: .bold))
                .padding(.top, 10)
            Text("Your music, agents, clipboard and system changes live in the notch. Hover it to peek, click to open, right-click for settings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
                .padding(.top, 6)

            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let trusted = AXIsProcessTrusted()
                    row(symbol: "hand.raised.fill", tint: .blue, title: "Accessibility",
                        detail: "Replaces the volume and brightness popups, pastes from your clipboard history, and opens the right terminal tab for an agent.") {
                        if trusted {
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.green)
                        } else {
                            Button("Allow") {
                                lab.liveActivities.requestAccessibility()
                                let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                                if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                }
                Divider().padding(.leading, 52)
                row(symbol: "power", tint: .gray, title: "Open at login",
                    detail: "Start Niche when you log in so the notch is always ready.") {
                    Toggle("", isOn: $openAtLogin).labelsHidden().toggleStyle(.switch)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            .padding(.horizontal, 24)
            .padding(.top, 22)

            Text("You can change these any time in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)

            Button {
                OpenAtLogin.isOn = openAtLogin
                done()
            } label: {
                Text("Get Started").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .frame(width: 420)
    }

    private func row(symbol: String, tint: Color, title: String, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(12)
    }
}
