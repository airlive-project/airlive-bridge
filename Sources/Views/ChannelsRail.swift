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
        // Faint hairline separating this rail from the center zone (consistent
        // with the OutputsRail edge + the mode-bar / footer dividers).
        .overlay(Rectangle().frame(width: 1).foregroundColor(Theme.stroke),
                 alignment: .trailing)
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

// MARK: - Security footer (ONE button — set / change the Bridge password)

/// A single button pinned to the bottom of the Channels rail.  Setting a password
/// IS turning auth on (it gates every channel); no password = open.  No toggle,
/// no explanatory blurb — just the button, which opens a small popover to enter /
/// remove the password.  ACCESS control, not encryption (HMAC challenge; the
/// password is never sent).
private struct SecurityFooter: View {
    @ObservedObject var model: BridgeModel
    @State private var showSheet = false
    @State private var draft = ""

    var body: some View {
        Button { draft = ""; showSheet = true } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: model.hasPassword ? "lock.fill" : "lock")
                    .font(.system(size: 12))
                    .foregroundColor(model.hasPassword ? Theme.accentBlue : Theme.textFaint)
                    .frame(width: 16)
                Text(model.hasPassword ? "Password set" : "Set password")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                if model.hasPassword {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.accentBlue)
                }
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.bgPanel)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke), alignment: .top)
        .popover(isPresented: $showSheet, arrowEdge: .trailing) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(model.hasPassword ? "Change password" : "Set password")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            SecureField("Password", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, Spacing.sm)
                .frame(width: 220, height: 30)
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
        .frame(width: 252)
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
