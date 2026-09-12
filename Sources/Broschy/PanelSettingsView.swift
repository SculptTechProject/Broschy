import SwiftUI

struct PanelSettingsView: View {
    @ObservedObject var preferences: PanelPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Make it yours.").font(.system(size: 19, weight: .semibold, design: .rounded))
                Spacer()
                Image(systemName: "slider.horizontal.3").foregroundStyle(Ink.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $preferences.quietFocusEnabled) {
                    Label("Quiet Focus", systemImage: "moon")
                        .font(.system(size: 12, weight: .medium))
                }.toggleStyle(.switch).controlSize(.small)
                Text("During a running timer, only agent questions and permission requests interrupt the notch. Results stay in their tabs.")
                    .font(.system(size: 11)).foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            }
            Rectangle().fill(Ink.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                Text("IN YOUR PANEL").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Ink.muted)
                ForEach(PanelTab.displayOrder) { tab in
                    Toggle(isOn: Binding(get: { preferences.visibleTabs.contains(tab) },
                                         set: { preferences.setVisible($0, for: tab) })) {
                        Label(tab.displayTitle, systemImage: tab.systemSymbol)
                            .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .disabled(preferences.visibleTabs.count == 1 && preferences.visibleTabs.contains(tab))
                }
                Text("Hidden tabs also leave the compact notch. Connections keep running. Keep at least one tab visible.")
                    .font(.system(size: 10)).foregroundStyle(Ink.muted).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Reset panel settings") { preferences.resetDefaults() }
                .buttonStyle(.link).font(.system(size: 11))
                .help("Show all tabs and turn Quiet Focus off. Your data and connections stay unchanged.")
        }
        .foregroundStyle(Ink.text).padding(20).frame(width: 320)
    }
}
