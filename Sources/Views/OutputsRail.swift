// OutputsRail.swift — RIGHT zone: "Publish to".
//
// One card per downstream output on the selected channel (NDI for now; SRT /
// RTSP land in later phases).  Each card: an on/off control, a RENAMEABLE output
// label ("what it sends" — the NDI source name), a config field, and a LIVE/OFF
// status pill.  A footer button adds a new NDI output.
//
// Output model note: `VideoOutput` (NDIOutput) is a plain reference type, not an
// ObservableObject — its `label`/`isLive` are stored properties.  The channel's
// `outputs` array IS `@Published`, so add/remove re-renders the list; for an
// individual card's live-toggle / rename we bump a local refresh token so the
// pill and field reflect the new value immediately.

import SwiftUI

struct OutputsRail: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.strokeDivider)
            content(for: model.selectedChannel)
        }
        .frame(width: 280)
        .background(Theme.bgRail)
    }

    private var header: some View {
        HStack {
            Text("Publish to")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(Spacing.lg)
    }

    @ViewBuilder
    private func content(for channel: BridgeChannel?) -> some View {
        if let channel {
            ChannelOutputs(channel: channel)
        } else {
            VStack {
                Spacer()
                Text("Select a channel to manage\nits outputs.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.textFaint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(Spacing.lg)
        }
    }
}

// MARK: - Outputs for one channel

private struct ChannelOutputs: View {
    @ObservedObject var channel: BridgeChannel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    if channel.outputs.isEmpty {
                        emptyState
                    } else {
                        ForEach(channel.outputs, id: \.id) { output in
                            OutputCard(channel: channel, output: output)
                        }
                    }
                }
                .padding(Spacing.lg)
            }
            Divider().background(Theme.strokeDivider)
            addButton
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 24))
                .foregroundColor(Theme.textFaint)
            Text("No outputs yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Add an NDI output to re-publish\nthis channel on your LAN.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    private var addButton: some View {
        Button {
            let name = defaultOutputName()
            channel.addOutput(NDIOutput(label: name))
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("Add NDI output")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .bridgeButton(selected: false)
        .padding(Spacing.lg)
    }

    /// "<Channel> NDI N" using the lowest free index so the LAN source names
    /// stay stable and readable.
    private func defaultOutputName() -> String {
        let used = Set(channel.outputs.map(\.label))
        var n = 1
        while used.contains("\(channel.name) NDI \(n)") { n += 1 }
        return "\(channel.name) NDI \(n)"
    }
}

// MARK: - One output card

/// A single output card.  Because `VideoOutput` is not observable, we keep a
/// local `refresh` token bumped on every mutation so the pill / field re-read
/// the output's current `isLive` / `label` immediately after a toggle or rename.
private struct OutputCard: View {
    @ObservedObject var channel: BridgeChannel
    let output: VideoOutput

    @State private var draftLabel: String = ""
    @State private var config: String = ""
    @State private var refresh = 0

    var body: some View {
        // `refresh` is read so a bump re-evaluates the card body without
        // recreating it (which would wipe the config field's @State).  After a
        // start/stop/rename we increment `refresh`; the pill + field below then
        // re-read the output's fresh `isLive` / `label`.
        // Forces body re-evaluation when `refresh` increments (VideoOutput is
        // not an ObservableObject, so SwiftUI has no other dependency on it).
        let _ = refresh
        return VStack(alignment: .leading, spacing: Spacing.md) {
            headerRow
            labelField
            configField
            footerRow
        }
        .padding(Spacing.md)
        .panelSurface()
        .onAppear { draftLabel = output.label }
    }

    // MARK: Header — kind badge + on/off + status

    private var headerRow: some View {
        HStack(spacing: Spacing.sm) {
            kindBadge
            Spacer()
            StatusPill(text: output.isLive ? "LIVE" : "OFF",
                       on: output.isLive,
                       accent: Theme.accentRed)
            onOffToggle
        }
    }

    private var kindBadge: some View {
        Text(output.kind.rawValue.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.0)
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.bgSelected)
            )
    }

    private var onOffToggle: some View {
        Toggle("", isOn: Binding(
            get: { output.isLive },
            set: { newValue in
                if newValue { output.start() } else { output.stop() }
                refresh += 1
            }
        ))
        .toggleStyle(.switch)
        .tint(Theme.accentRed)
        .labelsHidden()
    }

    // MARK: Renameable label — "what it sends"

    private var labelField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(text: "Source name")
            TextField("NDI source name", text: $draftLabel)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, Spacing.sm)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .fill(Theme.bgApp)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
                .onSubmit { commitLabel() }
        }
    }

    private func commitLabel() {
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { draftLabel = output.label; return }
        // NDIOutput's label setter recreates a live sender under the new name.
        output.label = trimmed
        refresh += 1
    }

    // MARK: Config field — transport-specific, advisory for NDI

    private var configField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(text: configLabel)
            TextField(configPlaceholder, text: $config)
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospaced())
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .fill(Theme.bgApp)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
        }
    }

    private var configLabel: String {
        switch output.kind {
        case .ndi:  return "NDI group (optional)"
        case .srt:  return "SRT destination"
        case .rtsp: return "RTSP mount point"
        }
    }

    private var configPlaceholder: String {
        switch output.kind {
        case .ndi:  return "public"
        case .srt:  return "srt://host:port"
        case .rtsp: return "/live/cam"
        }
    }

    // MARK: Footer — remove

    private var footerRow: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                channel.removeOutput(output)
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                    Text("Remove")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Theme.accentRed)
            }
            .buttonStyle(.plain)
        }
    }
}
