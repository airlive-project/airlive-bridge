// ChannelsRail.swift — LEFT zone: the channel list.
//
// Channels are CREATED, not auto-discovered (DESIGN.md): "+ Create channel"
// opens a receiver slot the iPhone connects to.  Each row shows the renameable
// name, a connection dot, a one-line spec read from the camera's last snapshot,
// and a tally hint.  The selected row is signalled by the accent-blue leading
// bar + a brighter fill (the Studio / Linear selection idiom — fill carries the
// state, not a heavy border).

import SwiftUI

struct ChannelsRail: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(spacing: 0) {
            header
            list
                .frame(maxHeight: .infinity)
            SecurityFooter(model: model)   // ONE global password for the Bridge
        }
        .frame(width: 240)
        .background(Theme.bgRail)
    }

    // MARK: - Header
    //
    // Studio's add-source idiom: the title carries a small inline `+` right
    // beside it (no big full-width "create" button under the list, no rule under
    // the header).  Pressing `+` opens a channel's receiver slot immediately.

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text("Channels")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            addButton
            Spacer()
            Text("\(model.channels.count)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(Theme.textFaint)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    /// Small inline `+` next to the title — the Studio add-source affordance.
    /// `addChannel` builds the model object, brings the receiver slot + Bonjour
    /// advert online, and applies the global auth so the iPhone can connect.
    private var addButton: some View {
        Button {
            model.addChannel()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 22, height: 22)
        }
        .bridgeButton(corner: Radius.control)
        .help("Create channel")
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if model.channels.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: Spacing.sm) {
                    ForEach(model.channels) { channel in
                        ChannelRow(
                            channel: channel,
                            selected: channel.id == model.selectedID,
                            onSelect: { model.select(channel.id) },
                            onRemove: {
                                TallyStore.shared.clear(channel.id)
                                model.removeChannel(channel.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.md)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Spacer()
            // "iphone" (not "iphone.gen3") — gen-numbered variants are SF
            // Symbols 5 / macOS 14; this app deploys to macOS 13, where the
            // numbered symbol renders blank.  Plain "iphone" exists since macOS 11.
            Image(systemName: "iphone")
                .font(.system(size: 28))
                .foregroundColor(Theme.textFaint)
            Text("No channels yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Create a channel, then connect\nan iPhone running Airlive Camera.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.textFaint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.lg)
    }
}

// MARK: - One channel row

/// A single channel row.  Observes the channel so the connection dot, spec and
/// tally hint stay live as snapshots arrive.  Double-click (or the pencil) puts
/// the name into an inline editable field.
private struct ChannelRow: View {
    @ObservedObject var channel: BridgeChannel
    @ObservedObject private var tally = TallyStore.shared
    let selected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var editing = false
    @State private var draftName = ""
    @State private var hovering = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                nameLine
                specLine
                transferLine
            }
            Spacer(minLength: 0)
            tallyHint
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                .stroke(selected ? Theme.stroke : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { beginRename() }
            Divider()
            Button("Remove Channel", role: .destructive) { onRemove() }
        }
    }

    // MARK: Name (with inline rename)

    private var nameLine: some View {
        HStack(spacing: Spacing.sm) {
            ConnectionDot(connected: channel.isConnected)
            if editing {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .focused($nameFocused)
                    .onSubmit { commitRename() }            // Enter commits
                    .onExitCommand { cancelRename() }       // Esc cancels
                    // Commit on focus loss too — clicking another row, the list,
                    // or anywhere else ends the edit and saves, not only Enter.
                    .onChange(of: nameFocused) { focused in
                        if !focused && editing { commitRename() }
                    }
            } else {
                Text(channel.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if hovering {
                    Button {
                        beginRename()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Mini spec line read from the camera snapshot, e.g. "4K · 30 · Apple Log".
    private var specLine: some View {
        Text(specText)
            .font(.system(size: 10, weight: .regular))
            .foregroundColor(Theme.textFaint)
            .lineLimit(1)
    }

    private var specText: String {
        guard let remote = channel.remote else {
            return channel.isConnected ? "Connected · waiting for state" : "Waiting for camera…"
        }
        let res = remote.resolution
        let fps = remote.fps
        return "\(res) · \(fps)fps · \(remote.colorSpace)"
    }

    /// Transfer status — WHERE this channel's video is going (the live outputs),
    /// not its camera settings. Green when publishing, dim when idle.
    private var transferLine: some View {
        let live = channel.outputs.filter { $0.isLive }
        let publishing = !live.isEmpty
        return HStack(spacing: Spacing.xs) {
            Image(systemName: publishing ? "dot.radiowaves.right" : "wifi.slash")
                .font(.system(size: 9))
            Text(publishing
                 ? "→ " + live.map { $0.kind.rawValue.uppercased() }.joined(separator: " · ")
                 : "Not publishing")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(publishing ? Color(hex: 0x37CF83) : Theme.textFaint)
    }

    /// A tiny coloured square hinting the channel's tally state, derived from
    /// the camera's reported cue if present.  (The authoritative tally lives in
    /// the center pane buttons; this is an at-a-glance mirror.)
    @ViewBuilder
    private var tallyHint: some View {
        switch channelTally {
        case .program:
            tallySquare(Theme.accentRed)
        case .preview:
            tallySquare(Theme.accentYellow)
        case .off:
            EmptyView()
        }
    }

    private func tallySquare(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var channelTally: TallyState {
        // Read from the shared, observed store so the hint and the center-pane
        // buttons (which write the same store) can never disagree.
        tally.state(for: channel.id)
    }

    private var rowFill: Color {
        if selected { return Theme.bgSelected }
        return hovering ? Theme.bgHover : Color.clear
    }

    // MARK: Rename helpers

    private func beginRename() {
        draftName = channel.name
        editing = true
        onSelect()
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        // `editing = false` first so the `onChange(of: nameFocused)` blur-commit
        // that fires as the field tears down sees `editing == false` and doesn't
        // re-enter this (a harmless second `rename`, but cleaner to guard).
        editing = false
        channel.rename(draftName)
    }

    private func cancelRename() {
        editing = false
    }
}

// MARK: - Security footer (ONE global password for the whole Bridge)

/// A compact security control pinned to the bottom of the Channels rail.  One
/// password gates EVERY channel (STREAM-AUTH-SPEC — receiver-side policy).  A
/// plain switch turns it on; the password itself is entered in a small popover
/// so the narrow rail stays uncluttered.  OFF by default; ACCESS control, not
/// encryption — the password is verified by an HMAC challenge, never sent.
private struct SecurityFooter: View {
    @ObservedObject var model: BridgeModel
    @State private var showSheet = false
    @State private var draft = ""

    private var locked: Bool { model.requireAuth && model.hasPassword }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            row
            if model.requireAuth {
                setButton
            }
        }
        .padding(Spacing.md)
        .background(Theme.bgPanel)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke), alignment: .top)
    }

    private var row: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: 12))
                .foregroundColor(locked ? Theme.accentBlue : Theme.textFaint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Security")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Text(statusText)
                    .font(.system(size: 9))
                    .foregroundColor(statusColor)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $model.requireAuth)
                .toggleStyle(.switch)
                .tint(Theme.accentBlue)
                .labelsHidden()
                .scaleEffect(0.85)
        }
    }

    private var setButton: some View {
        Button { draft = ""; showSheet = true } label: {
            Text(model.hasPassword ? "Change password…" : "Set password…")
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
        // Nudge the operator (accent fill) while auth is on but no password set.
        .bridgeButton(selected: model.requireAuth && !model.hasPassword)
        .popover(isPresented: $showSheet, arrowEdge: .trailing) { popover }
    }

    private var statusText: String {
        if !model.requireAuth { return "Open — any device on the LAN" }
        return model.hasPassword ? "Required on all channels" : "No password — still open"
    }

    private var statusColor: Color {
        if !model.requireAuth { return Theme.textFaint }
        return model.hasPassword ? Theme.textFaint : Theme.accentYellow
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Bridge password")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("One password for every channel. Cameras must enter it to connect.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, Spacing.sm)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Theme.bgApp))
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                .onSubmit { commit() }
            HStack {
                if model.hasPassword {
                    Button("Remove") { model.setPassword(""); showSheet = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accentRed)
                }
                Spacer()
                Button { commit() } label: {
                    Text("Save").font(.system(size: 12, weight: .semibold)).frame(width: 64, height: 30)
                }
                .bridgeButton(selected: !draft.isEmpty)
                .disabled(draft.isEmpty)
            }
        }
        .padding(Spacing.md)
        .frame(width: 260)
        .background(Theme.bgPanel)
    }

    private func commit() {
        let pw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty else { return }
        model.setPassword(pw)
        draft = ""
        showSheet = false
    }
}
