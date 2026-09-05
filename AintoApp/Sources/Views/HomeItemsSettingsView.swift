import SwiftUI

struct HomeItemsSettingsView: View {
    @Binding var clipboardHistory: Bool
    @Binding var fileSearch: Bool
    @Binding var aiCommands: Bool
    @Binding var selectedAICommandIDs: [String]
    let aiEnabled: Bool

    private let maximumAICommands = 4

    private var commands: [AICommand] {
        (AICommand.loadAll() ?? []).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var availableSelectedCount: Int {
        let availableIDs = Set(commands.map(\.id))
        return selectedAICommandIDs.filter(availableIDs.contains).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Home Items", icon: "house")

            Text(
                "Choose what appears when search is empty. Hidden items remain searchable, "
                    + "and their aliases and shortcuts continue to work."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    homeToggle("Clipboard History", icon: "doc.on.clipboard", isOn: $clipboardHistory)
                    Divider().opacity(0.25)
                    homeToggle("File Search", icon: "doc.text.magnifyingglass", isOn: $fileSearch)
                    Divider().opacity(0.25)
                    Divider().opacity(0.25)

                    HStack(spacing: 10) {
                        Image(systemName: "sparkle")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text("AI Commands")
                            .font(.system(size: 13))
                        Spacer()
                        Toggle("", isOn: $aiCommands)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .disabled(!aiEnabled)
                    }

                    if aiCommands {
                        VStack(alignment: .leading, spacing: 9) {
                            if commands.isEmpty {
                                Text("No AI Commands configured.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(commands) { command in
                                    Toggle(isOn: commandBinding(command.id)) {
                                        HStack(spacing: 8) {
                                            Image(systemName: command.icon)
                                                .frame(width: 16)
                                                .foregroundStyle(.secondary)
                                            Text(command.name)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 12))
                                    .disabled(
                                        !aiEnabled
                                            || (!selectedAICommandIDs.contains(command.id)
                                                && availableSelectedCount >= maximumAICommands)
                                    )
                                }
                            }

                            Text("Select up to \(maximumAICommands) commands for Home.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 28)
                        .padding(.top, 2)
                    }

                    if !aiEnabled {
                        Text("Enable AI in Settings → AI to show AI Commands on Home.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 28)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func homeToggle(
        _ title: String,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
        }
    }

    private func commandBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedAICommandIDs.contains(id) },
            set: { selected in
                if selected {
                    guard !selectedAICommandIDs.contains(id),
                          availableSelectedCount < maximumAICommands
                    else { return }
                    selectedAICommandIDs.append(id)
                } else {
                    selectedAICommandIDs.removeAll { $0 == id }
                }
            }
        )
    }
}
