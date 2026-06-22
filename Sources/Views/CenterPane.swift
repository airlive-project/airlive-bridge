// CenterPane.swift — CENTER zone: the selected channel.
//
// Top to bottom, inside one ScrollView so the full control stack fits any window
// size without overflow: the 16:9 preview (tally border + ON AIR / PREVIEW badge
// + hide-preview eye), the Tally row (Off / Preview / Program — sends `setCue`),
// the Output-delay row (LatencyPreset), then the camera CONTROL panel
// (CameraControlPanel).  Everything here drives one channel; when no channel is
// selected it shows a quiet empty state.
//
// Tally and Output-delay use the kit `SegmentedBar` so their segments are EQUAL
// width and aligned (the old native `.segmented` Picker rendered crooked).
//
// Readback vs control: value labels come from `channel.remote` (the camera's
// reported StateSnapshot); every knob sends a `ControlMessage` via
// `channel.send(_:)`.  The two are deliberately separate — the operator turns a
// knob, the command goes to the iPhone, and the iPhone's next snapshot confirms
// the new value back into the labels.

import SwiftUI

struct CenterPane: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        Group {
            if let channel = model.selectedChannel {
                ChannelDetail(channel: channel)
                    // Re-create the detail subtree per channel so its local
                    // @State (preview pane sizing, slider drafts) resets cleanly
                    // when the selection changes.
                    .id(channel.id)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgApp)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundColor(Theme.textFaint)
            Text("No channel selected")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Create or select a channel on the left.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textFaint)
        }
    }
}

// MARK: - One channel's detail

private struct ChannelDetail: View {
    @ObservedObject var channel: BridgeChannel
    @ObservedObject private var tally = TallyStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                previewSection
                tallyRow
                delayRow
                SecurityCard(channel: channel)
                // Camera control commands the iPhone — pointless (and a source of
                // stale-state bugs) with no camera attached.  Dim + disable it
                // until connected; it lights up the moment the phone joins.
                CameraControlPanel(channel: channel)
                    .disabled(!channel.isConnected)
                    .opacity(channel.isConnected ? 1.0 : 0.4)
            }
            // Tight top padding; generous-but-compact around the rest.  The
            // ScrollView lets the stack grow past the window without overflow.
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xl)
        }
    }

    // MARK: Preview

    /// The camera reports a clockwise rotation hint (Option B vertical stream);
    /// 90/270 means the operator is shooting portrait, so the preview goes 9:16.
    private var isPortrait: Bool {
        let r = channel.remote?.outputRotation ?? 0
        return r == 90 || r == 270
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                SectionLabel(text: channel.name)
                Spacer()
                hidePreviewToggle
            }
            previewPane
        }
    }

    private var hidePreviewToggle: some View {
        Button {
            channel.previewEnabled.toggle()
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: channel.previewEnabled ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                Text(channel.previewEnabled ? "Hide preview" : "Show preview")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: 26)
        }
        .bridgeButton(selected: !channel.previewEnabled)
        .help("Stop rendering this preview to save GPU/CPU while it isn't being watched.")
    }

    private var previewPane: some View {
        ZStack {
            if channel.previewEnabled {
                PreviewView(channel: channel)
                if channel.latestFrame == nil {
                    noSignalOverlay
                }
            } else {
                hiddenPlaceholder
            }
            tallyBadge
        }
        // Adapt to the camera's orientation: a vertical (Option B) stream reports
        // a 90/270 rotation, so the pane itself becomes 9:16 and the portrait
        // frame fills it instead of letterboxing inside a wide 16:9 box.
        .aspectRatio(isPortrait ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .stroke(tallyBorderColor, lineWidth: tallyBorderWidth)
        )
    }

    private var noSignalOverlay: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: channel.isConnected ? "hourglass" : "wifi.slash")
                .font(.system(size: 26))
                .foregroundColor(Theme.textFaint)
            Text(channel.isConnected ? "Connected — waiting for video"
                                     : "Waiting for camera to connect")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var hiddenPlaceholder: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "eye.slash")
                .font(.system(size: 26))
                .foregroundColor(Theme.textFaint)
            Text("Preview hidden — saving GPU")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Frames are still received and published downstream.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPanel)
    }

    // MARK: Tally badge / border

    private var currentTally: TallyState { tally.state(for: channel.id) }

    @ViewBuilder
    private var tallyBadge: some View {
        if currentTally != .off {
            VStack {
                HStack {
                    HStack(spacing: Spacing.xs) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                        Text(currentTally == .program ? "ON AIR" : "PREVIEW")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.5)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(
                        Capsule(style: .continuous).fill(currentTally.accent)
                    )
                    Spacer()
                }
                Spacer()
            }
            .padding(Spacing.md)
        }
    }

    private var tallyBorderColor: Color {
        currentTally == .off ? Theme.stroke : currentTally.accent
    }

    private var tallyBorderWidth: CGFloat {
        currentTally == .off ? 1 : 3
    }

    // MARK: Tally (equal-width segmented bar)

    private var tallyRow: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel(text: "Tally")
                SegmentedBar(
                    selection: Binding(
                        get: { currentTally },
                        set: { setTally($0) }
                    ),
                    options: TallyState.allCases,
                    label: { $0.label },
                    // Program red, Preview yellow, Off neutral blue.
                    accent: { $0 == .off ? Theme.accentBlue : $0.accent }
                )
            }
        }
    }

    /// Record the cue locally (so both surfaces agree) and ship it to the iPhone.
    private func setTally(_ state: TallyState) {
        tally.set(state, for: channel.id)
        channel.send(.setCue(state.rawValue))
    }

    // MARK: Output delay (equal-width segmented bar)

    private var delayRow: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel(text: "Output delay (ms)")
                SegmentedBar(
                    selection: Binding(
                        get: { channel.delay },
                        set: { channel.delay = $0 }
                    ),
                    options: LatencyPreset.allCases,
                    // The +ms value is the point of this control — show it next to
                    // the name on each segment (the unit rides in the section label).
                    label: { delayShortLabel($0) }
                )
            }
        }
    }

    /// Compact, segment-friendly label for a latency preset (the full label is
    /// long; equal segments need a tight string).
    private func delayShortLabel(_ preset: LatencyPreset) -> String {
        switch preset {
        case .lowest: return "Lowest +0"
        case .normal: return "Normal +120"
        case .smooth: return "Smooth +200"
        case .safe:   return "Safe +400"
        }
    }
}

// MARK: - Security card (receiver-password auth)

/// Per-channel receiver-password auth (STREAM-AUTH-SPEC).  OFF by default — the
/// stream stays open until the operator turns it on AND sets a password.  This is
/// ACCESS control (keep a same-LAN prankster off the slot), not encryption: the
/// password is verified by an HMAC challenge the camera answers; it never crosses
/// the wire.  Changing the password is a revocation — it disconnects the connected
/// camera so it must re-enter the new one.
private struct SecurityCard: View {
    @ObservedObject var channel: BridgeChannel
    @State private var draftPassword = ""

    /// Auth actually engages only when enabled AND a password is stored.
    private var locked: Bool { channel.requireAuth && channel.hasPassword }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                header
                if channel.requireAuth {
                    passwordRow
                    statusRow
                }
            }
        }
    }

    // "SECURITY" + state pill + a plain on/off SWITCH on the right (not a big
    // blue slab that reads like a button) — the standard settings-row idiom.
    private var header: some View {
        HStack(spacing: Spacing.sm) {
            SectionLabel(text: "Security")
            Spacer()
            if channel.requireAuth {
                StatusPill(text: locked ? "LOCKED" : "OPEN", on: locked, accent: Theme.accentBlue)
            }
            Toggle("", isOn: $channel.requireAuth)
                .toggleStyle(.switch)
                .tint(Theme.accentBlue)
                .labelsHidden()
        }
    }

    // Password entry + a clearly-sized Set button (accent-filled once you type).
    private var passwordRow: some View {
        HStack(spacing: Spacing.sm) {
            SecureField(channel.hasPassword ? "Change password" : "Set a password",
                        text: $draftPassword)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, Spacing.sm)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .fill(Theme.bgApp)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
                .onSubmit { commitPassword() }

            Button { commitPassword() } label: {
                Text("Set")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 62, height: 32)
            }
            .bridgeButton(selected: !draftPassword.isEmpty)
            .disabled(draftPassword.isEmpty)
        }
    }

    // One status line: confirms a stored password (with Remove) or warns it's
    // still open.  Replaces the old long ASCII/OBS hint that didn't belong here.
    @ViewBuilder
    private var statusRow: some View {
        if channel.hasPassword {
            HStack(spacing: Spacing.sm) {
                Label("Password set", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button("Remove") { channel.setPassword(""); draftPassword = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.accentRed)
            }
        } else {
            Label("No password yet — the channel stays open until you set one.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(Theme.accentYellow)
        }
    }

    private func commitPassword() {
        let pw = draftPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty else { return }
        channel.setPassword(pw)        // stored in Keychain + revokes the live camera
        draftPassword = ""
    }
}
