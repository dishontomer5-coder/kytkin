// P6-0k (owner 2026-11-18): Settings → Statistics. Layout only; the wording and the counts are
// `StatisticsSettingsModel`'s. Same page, card and row styles as the other tabs (`SettingsPage`, `SettingsSection`,
// `SettingsRow`). No popups, no celebrations: a quiet helper.

import SwiftUI

struct StatisticsSettingsView: View {
    let model: StatisticsSettingsModel
    @State private var confirmsReset = false

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 6) {
                Text(StatisticsSettingsModel.header)
                    .font(.system(size: SettingsMetrics.titleSize, weight: .semibold))
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
                SettingsCard {
                    VStack(spacing: 4) {
                        Text(model.totalText)
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.kytkinAccent)
                            .contentTransition(.numericText())
                        Text(StatisticsSettingsModel.subtitle)
                            .font(.system(size: SettingsMetrics.titleSize))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 12)
                    .accessibilityElement(children: .combine)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SettingsSection {
                    ForEach(model.rows) { row in
                        SettingsRow(row.title) {
                            Text(row.count)
                                .font(.system(size: SettingsMetrics.titleSize))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                HStack {
                    Spacer()
                    Button(StatisticsSettingsModel.resetButton) { confirmsReset = true }
                        .disabled(model.stats.total == 0)
                        .confirmationDialog(StatisticsSettingsModel.resetConfirmTitle, isPresented: $confirmsReset) {
                            Button(StatisticsSettingsModel.resetConfirmButton, role: .destructive) { model.reset() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(StatisticsSettingsModel.resetConfirmMessage)
                        }
                }
            }

            Label {
                Text(StatisticsSettingsModel.footer)
            } icon: {
                Image(systemName: "lock")
            }
            .font(.system(size: SettingsMetrics.secondarySize))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
        }
    }
}
