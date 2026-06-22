// OutputsRail.swift — RIGHT zone: "Publish to".
//
// One card per downstream output on the selected channel.  NDI is FUNCTIONAL:
// real `VideoOutput`s from `channel.outputs`, each with an on/off control, a
// renameable source name, a config field and a LIVE/OFF pill.  Below them sit
// PLACEHOLDER cards for the not-yet-shipped transports (SRT, RTSP, Virtual
// Camera) so the operator can see the full protocol surface — they match the
// kit's Card styling, carry a "Soon" pill, a representative (disabled) config
// field and a disabled toggle.  A footer "Add output" menu lists all four kinds,
// with NDI enabled and the rest marked "Soon".
//
// WHY the placeholders are NOT in `channel.outputs`: that array is the real
// frame fan-out (the channel calls `send(_:timeNs:)` on every entry).  A
// bûtaphoric SRT/RTSP/VCam card has no `VideoOutput` to fan frames to, so it is
// a pure presentational view driven by `OutputKind` alone — adding a fake entry
// to the model would mean a no-op sink in the live path and a broken add/remove
// contract.  The placeholder kinds are derived from `OutputKind.allCases` minus
// the implemented ones, so adding a real transport later automatically promotes
// it from placeholder to a real card with zero edits here.
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
            content(for: model.selectedChannel)
        }
        .frame(width: 280)
        .background(Theme.bgRail)
    }

    // No rule under the header — section grouping is carried by spacing and the
    // output cards' own edges, matching the Channels rail and Studio's panels.
    private var header: some View {
        HStack {
            Text("Publish to")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
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

// MARK: - Outputs for one channel

private struct ChannelOutputs: View {
    @ObservedObject var channel: BridgeChannel

    /// The not-yet-shipped transports, shown as placeholder cards under the real
    /// NDI outputs.  Derived from the enum so it tracks `OutputKind` automatically.
    private var placeholderKinds: [OutputKind] {
        OutputKind.allCases.filter { !$0.isImplemented }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    // Real, functional NDI outputs first.
                    if channel.outputs.isEmpty {
                        emptyNDIState
                    } else {
                        ForEach(channel.outputs, id: \.id) { output in
                            OutputCard(channel: channel, output: output)
                        }
                    }

                    // A quiet caption separating the live outputs from the
                    // coming-soon protocols, so the placeholders never read as
                    // broken real outputs.
                    comingSoonHeader

                    // Bûtaphoric placeholder cards — visually complete, inert.
                    ForEach(placeholderKinds) { kind in
                        PlaceholderOutputCard(kind: kind)
                    }
                }
                // Top padding stays small so the first card sits just under the
                // header (which already adds an 8 pt bottom gap); horizontal /
                // bottom keep the rail's normal inset.
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.lg)
            }
            Divider().background(Theme.strokeDivider)
            addButton
        }
    }

    /// Empty-state shown when the channel has no NDI outputs yet.  (The
    /// placeholder cards still appear below it so the rail is never empty.)
    private var emptyNDIState: some View {
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

    /// Caption above the placeholder block.
    private var comingSoonHeader: some View {
        HStack {
            SectionLabel(text: "More protocols")
            Spacer()
            SoonPill()
        }
        .padding(.top, Spacing.xs)
    }

    /// "Add output" menu: NDI is enabled and adds a real output; SRT / RTSP /
    /// Virtual Camera are listed but disabled ("Soon") so the operator sees the
    /// full roadmap of where a channel will be publishable.
    private var addButton: some View {
        Menu {
            ForEach(OutputKind.allCases) { kind in
                Button {
                    guard kind.isImplemented else { return }
                    channel.addOutput(NDIOutput(label: defaultOutputName()))
                } label: {
                    if kind.isImplemented {
                        Label("Add \(kind.displayName) output", systemImage: kind.symbolName)
                    } else {
                        Label("\(kind.displayName) — Soon", systemImage: kind.symbolName)
                    }
                }
                .disabled(!kind.isImplemented)
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("Add output")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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

// MARK: - "Soon" pill

/// A small "Soon" badge for not-yet-shipped protocols.  Yellow (caution/staged)
/// fill with DARK text — yellow + white would be the worst contrast in the kit,
/// so the on-yellow text is the app canvas colour, matching `PillToggle`'s
/// `onText` discipline for light accents.
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

// MARK: - Placeholder (non-functional) output card

/// A visually-complete but INERT card for a transport that isn't implemented
/// yet.  Same `Card` surface and layout as a real `OutputCard` — kind badge +
/// "Soon" pill, a representative config field, and a disabled toggle — but every
/// control is non-interactive and the whole card is dimmed so the operator reads
/// it as "coming soon", not "broken".  Drives entirely off `OutputKind`; it owns
/// no `VideoOutput` and never touches the channel.
private struct PlaceholderOutputCard: View {
    let kind: OutputKind

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                headerRow
                configField
            }
        }
        // Dim the whole card so it reads as inactive, and block all hit-testing
        // so nothing inside is tappable / editable — bûtaphoric by construction.
        .opacity(0.6)
        .allowsHitTesting(false)
    }

    // MARK: Header — kind badge + "Soon" + disabled toggle

    private var headerRow: some View {
        HStack(spacing: Spacing.sm) {
            kindBadge
            Spacer()
            SoonPill()
            // A real-looking but disabled switch, locked off.
            Toggle("", isOn: .constant(false))
                .toggleStyle(.switch)
                .tint(Theme.accentRed)
                .labelsHidden()
                .disabled(true)
        }
    }

    private var kindBadge: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(kind.displayName.uppercased())
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

    // MARK: Representative (disabled) config field

    private var configField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(text: kind.configFieldLabel)
            // Static text styled like the real TextField, never editable.
            HStack {
                Text(kind.configFieldExample)
                    .font(.system(size: 12).monospaced())
                    .foregroundColor(Theme.textFaint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
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
}

// MARK: - One output card (real, functional — NDI today)

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
        _ = refresh
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

// MARK: - Per-kind config field copy

/// The config field's caption and example value, per transport.  ONE source of
/// truth shared by the real `OutputCard` (label + text-field placeholder) and the
/// placeholder cards (label + static example), so the SRT/RTSP/VCam wording can
/// never drift between the two.
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
