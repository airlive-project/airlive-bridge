// OutputsRail.swift — RIGHT zone: "Outputs".
//
// Mirrors the Channels rail idiom for a consistent UI: a header that is just
// "Outputs" + a small inline "+", no rule underneath.
//
// Two states (UX-friendly first step — no wall of empty cards):
//   • ZERO outputs → a quick-pick CHOOSER: one tappable card per protocol so the
//     operator picks what to publish to. NDI adds a real output; SRT / RTSP /
//     Virtual Camera are shown as "Soon" (disabled) so the roadmap is visible.
//   • ≥1 output → the real `OutputCard` list only (the chooser disappears). The
//     header "+" stays, to add more.
//
// Only NDI is functional today; the other kinds are visual placeholders driven by
// `OutputKind` (displayName / symbolName / isImplemented), so a future transport
// auto-promotes from a "Soon" chooser tile to a real card with no edits here.
//
// Output model note: `VideoOutput` (NDIOutput) is a plain reference type, not an
// ObservableObject. The channel's `outputs` array IS `@Published`, so add/remove
// re-renders the list; for a card's live-toggle / rename we bump a local refresh
// token so the pill and field reflect the new value immediately.

import SwiftUI

struct OutputsRail: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(spacing: 0) {
            header
            content(for: model.selectedChannel)
        }
        .frame(width: 280)
        .background(Theme.bgRail)
    }

    // "Outputs" + inline "+" (mirrors the Channels rail). No divider under it.
    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text("Outputs")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            if let channel = model.selectedChannel {
                // "+" opens a menu of output TYPES — NDI adds a real output;
                // SRT / RTSP / Virtual Camera show as "soon" (disabled) so the
                // roadmap is visible and the button isn't hardcoded to NDI.
                Menu {
                    ForEach(OutputKind.allCases) { kind in
                        Button {
                            if kind.isImplemented {
                                channel.addOutput(NDIOutput(label: defaultNDIName(for: channel)))
                            }
                        } label: {
                            Label(kind.isImplemented ? kind.displayName : "\(kind.displayName) — soon",
                                  systemImage: kind.symbolName)
                        }
                        .disabled(!kind.isImplemented)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(Theme.bgSelected.opacity(0.6))
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add an output")
            }
            Spacer()
            if let channel = model.selectedChannel, !channel.outputs.isEmpty {
                Text("\(channel.outputs.count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(Theme.textFaint)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
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

/// "<Channel> NDI N" using the lowest free index so the LAN source names stay
/// stable and readable. File-scope so both the header "+" and the chooser use it.
private func defaultNDIName(for channel: BridgeChannel) -> String {
    let used = Set(channel.outputs.map(\.label))
    var n = 1
    while used.contains("\(channel.name) NDI \(n)") { n += 1 }
    return "\(channel.name) NDI \(n)"
}

// MARK: - Outputs for one channel (chooser when empty, cards when not)

private struct ChannelOutputs: View {
    @ObservedObject var channel: BridgeChannel

    var body: some View {
        if channel.outputs.isEmpty {
            chooser
        } else {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    ForEach(channel.outputs, id: \.id) { output in
                        OutputCard(channel: channel, output: output)
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.lg)
            }
        }
    }

    /// First-step quick-pick — pick a protocol to publish to. Cuts the wall of
    /// empty cards: the operator has to create something anyway, so offer the
    /// choices up front. The header "+" still works.
    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Publish this channel to…")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textFaint)
                    .padding(.horizontal, Spacing.xs)
                ForEach(OutputKind.allCases) { kind in
                    ChooserCard(kind: kind) {
                        channel.addOutput(NDIOutput(label: defaultNDIName(for: channel)))
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.lg)
        }
    }
}

// MARK: - Chooser card (quick-pick a protocol to add)

/// A tappable "add this protocol" tile shown only in the zero-output state.
/// NDI is pickable (adds a real output); SRT / RTSP / Virtual Camera show a
/// "Soon" pill and are disabled. Drives off `OutputKind`.
private struct ChooserCard: View {
    let kind: OutputKind
    let onPick: () -> Void

    var body: some View {
        Button {
            if kind.isImplemented { onPick() }
        } label: {
            Card {
                HStack(spacing: Spacing.md) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 16))
                        .foregroundColor(kind.isImplemented ? Theme.accentBlue : Theme.textFaint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text(kind.configFieldExample)
                            .font(.system(size: 10).monospaced())
                            .foregroundColor(Theme.textFaint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if kind.isImplemented {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Theme.accentBlue)
                    } else {
                        SoonPill()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!kind.isImplemented)
        .opacity(kind.isImplemented ? 1.0 : 0.55)
    }
}

// MARK: - "Soon" pill

/// A small "Soon" badge for not-yet-shipped protocols. Yellow fill with DARK
/// text (yellow + white is the worst contrast), matching `PillToggle.onText`.
private struct SoonPill: View {
    var body: some View {
        Text("SOON")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundColor(Theme.bgApp)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(Theme.accentYellow))
    }
}

// MARK: - One output card (real, functional — NDI today)

/// A single output card. Because `VideoOutput` is not observable, we keep a local
/// `refresh` token bumped on every mutation so the pill / field re-read the
/// output's current `isLive` / `label` immediately after a toggle or rename.
private struct OutputCard: View {
    @ObservedObject var channel: BridgeChannel
    let output: VideoOutput

    @State private var draftLabel: String = ""
    @State private var config: String = ""
    @State private var refresh = 0

    var body: some View {
        _ = refresh // re-evaluate body after a start/stop/rename bump
        return Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                headerRow
                labelField
                configField
                footerRow
            }
        }
        .onAppear { draftLabel = output.label }
    }

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
        HStack(spacing: Spacing.xs) {
            Image(systemName: output.kind.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(output.kind.displayName.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
        }
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
                // `output.isLive` changed but the `outputs` array didn't, so the
                // channel row's "→ NDI / Not publishing" line won't refresh on its
                // own — nudge the channel so its observers re-read live outputs.
                channel.objectWillChange.send()
            }
        ))
        .toggleStyle(.switch)
        .tint(Theme.accentRed)
        .labelsHidden()
    }

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
        output.label = trimmed
        refresh += 1
    }

    private var configField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(text: output.kind.configFieldLabel)
            TextField(output.kind.configFieldExample, text: $config)
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

// MARK: - Per-kind config field copy

/// The config field's caption and example value, per transport. ONE source of
/// truth shared by the real `OutputCard` and the chooser tiles.
private extension OutputKind {
    var configFieldLabel: String {
        switch self {
        case .ndi:  return "NDI group (optional)"
        case .srt:  return "SRT destination"
        case .rtsp: return "RTSP mount point"
        case .vcam: return "Virtual Camera name"
        }
    }

    var configFieldExample: String {
        switch self {
        case .ndi:  return "public"
        case .srt:  return "srt://host:port"
        case .rtsp: return "rtsp://0.0.0.0:8554/live/cam"
        case .vcam: return "Airlive Camera"
        }
    }
}
