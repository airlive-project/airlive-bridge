// ChannelsRail.swift — LEFT zone: the channel list.
//
// Channels are CREATED, not auto-discovered (DESIGN.md): "+ Create channel"
// opens a receiver slot the iPhone connects to.  Each row is a card matching the
// Outputs rail: a faint ORDINAL number (top-left) = the channel's position, the
// live status + connection dot (top-right), and the renameable name field below.
//
// ORDER MATTERS: the row order is the channel order — it drives the multiview tile
// layout AND the number-key shortcuts.  Drag a row (or use the ▲/▼ arrows on hover)
// and the ordinals renumber top-to-bottom, so swapping 2↔3 makes the old 3 the new 2.

import SwiftUI
import AVFoundation   // capture-device enumeration for the "+ → HDMI / USB Capture" menu

struct ChannelsRail: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(spacing: 0) {
            header
            list
                .frame(maxHeight: .infinity)
            SecurityFooter(model: model)   // ONE global password for the Bridge
        }
        .frame(width: 280)   // match the Outputs rail so the center zone is window-centered
        .background(Theme.bgRail)
        // Faint hairline separating this rail from the center zone (consistent
        // with the OutputsRail edge + the mode-bar / footer dividers).
        .overlay(Rectangle().frame(width: 1).foregroundColor(Theme.stroke),
                 alignment: .trailing)
    }

    // MARK: - Header
    //
    // Title left, "+" in its semi-transparent box on the right (mirrors the Outputs
    // rail).  No total count — the per-card ordinal carries the numbering now.

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text("Channels")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            addButton
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    /// "+" (semi-transparent box, right edge — matches the Outputs "+") opens the
    /// add-source menu.  `addChannel` builds the model object, brings the receiver
    /// slot + Bonjour advert online, and applies the global auth so the phone connects.
    private var addButton: some View {
        Menu {
            // FLAT list — no nested submenu (it dismissed on hover).  Primary sources
            // first; the HDMI/USB capture devices sit at the bottom as extras.
            Button { model.addChannel() } label: {
                Label("Airlive Camera", systemImage: "camera")
            }
            Button { model.addChannel(kind: .airplay) } label: {
                Label("Screen Mirroring", systemImage: "rectangle.on.rectangle")
            }
            let devices = CaptureDevices.discover()
            if !devices.isEmpty {
                Divider()
                ForEach(devices, id: \.uniqueID) { device in
                    Button {
                        model.addChannel(kind: .capture,
                                         captureDeviceID: device.uniqueID,
                                         name: device.localizedName)
                    } label: {
                        Label("HDMI / USB: \(device.localizedName)", systemImage: "cable.connector")
                    }
                }
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
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add source")
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if model.channels.isEmpty {
            emptyState
        } else {
            // ScrollView + VStack (not a List) for UNIFORM spacing — gap above the first
            // card == gap between cards == Spacing.sm, side margins == Spacing.lg, same
            // as the header.  Reorder via the ▲/▼ arrows (order drives multiview + shortcuts).
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.channels.enumerated()), id: \.element.id) { pair in
                        let idx = pair.offset
                        let channel = pair.element
                        ChannelRow(
                            channel: channel,
                            index: idx + 1,                          // 1-based ordinal = list position
                            isProgram: channel.id == model.effectiveProgramID,
                            isPreview: channel.id == model.previewID,
                            isFirst: idx == 0,
                            isLast: idx == model.channels.count - 1,
                            onSelect: { model.select(channel.id) },
                            onRemove: {
                                TallyStore.shared.clear(channel.id)
                                model.removeChannel(channel.id)
                            },
                            onMoveUp:   { model.moveChannel(from: IndexSet(integer: idx), to: idx - 1) },
                            onMoveDown: { model.moveChannel(from: IndexSet(integer: idx), to: idx + 2) }
                        )
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.sm)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Spacer()
            // "iphone" (not "iphone.gen3") — gen-numbered variants are SF Symbols 5 /
            // macOS 14; this app deploys to macOS 13, where the numbered symbol renders
            // blank.  Plain "iphone" exists since macOS 11.
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

// MARK: - One channel row (card: ordinal + status on top, name below)

/// A channel card mirroring the Outputs card.  Observes the channel so the status
/// and connection dot stay live as snapshots arrive.  The name is an always-editable
/// field (commit on Return / focus-loss); ▲/▼ (on hover) reorder by one.
private struct ChannelRow: View {
    @ObservedObject var channel: BridgeChannel
    let index: Int               // 1-based position = the displayed ordinal
    let isProgram: Bool          // on air → red tally number (+ delete-confirm wording)
    let isPreview: Bool          // staged → green tally number
    let isFirst: Bool
    let isLast: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var draftName = ""
    @State private var confirmingDelete = false

    var body: some View {
        Card(corner: 0, padding: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                topRow        // source kind · signal status · delete
                bottomRow     // ordinal · arrows · name
            }
        }
        // No selection outline for now (operator: remove the sticky blue until it has a
        // real function).  Click still drives the Solo preview, exactly as before.
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onAppear { draftName = channel.name }
        .contextMenu {
            Button("Remove Channel", role: .destructive) { requestRemove() }
        }
        // Active channel (ON AIR / receiving) confirms before removal; idle goes straight.
        .confirmationDialog("Remove “\(channel.name)”?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove channel", role: .destructive) { onRemove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isProgram ? "This channel is ON AIR — removing it cuts the program feed."
                           : "This channel is receiving video — removing it drops the connection.")
        }
    }

    // MARK: Top row

    // TOP: source kind (left) · signal status · delete (right).
    private var topRow: some View {
        HStack(spacing: Spacing.sm) {
            Text(channel.kind.sourceLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.xs)
            statusLine
            trashButton
        }
    }

    // BOTTOM: ordinal · reorder arrows · editable name.
    private var bottomRow: some View {
        HStack(spacing: Spacing.sm) {
            ordinalBadge
            reorderArrows
            nameField
        }
    }

    /// Position number that doubles as a TALLY light: red on PROGRAM (on air), green
    /// on PREVIEW (staged), neutral otherwise.  Renumbers on reorder.
    private var ordinalBadge: some View {
        let fill: Color = isProgram ? Theme.accentRed
                        : (isPreview ? Color(hex: 0x37CF83) : Theme.bgSelected.opacity(0.6))
        let fg: Color = (isProgram || isPreview) ? .white : Theme.textSecondary
        return Text("\(index)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundColor(fg)
            .frame(minWidth: 18, alignment: .center)   // sized for "00" — every ordinal equal width
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill)
            )
    }

    /// ▲/▼ reorder-by-one (shown on hover; the whole row also drag-reorders).
    private var reorderArrows: some View {
        HStack(spacing: 1) {
            arrowButton("chevron.up",   enabled: !isFirst, action: onMoveUp)
            arrowButton("chevron.down", enabled: !isLast,  action: onMoveDown)
        }
    }

    private func arrowButton(_ system: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(enabled ? Theme.textSecondary : Theme.textFaint.opacity(0.4))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Signal status — is this camera's stream actually arriving?  The director spots a
    /// dropped phone at a glance (green Connected → grey Disconnected).  Whether it's on
    /// air is read from the center preview, not from this list.
    private var statusLine: some View {
        let connected = channel.isConnected
        return Text(connected ? "Connected" : "Disconnected")
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .foregroundColor(connected ? Color(hex: 0x37CF83) : Theme.textFaint)
    }

    // MARK: Name (always-editable, like the Outputs card)

    private var nameField: some View {
        TextField("Channel name", text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(Theme.bgApp)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .onSubmit { commitRename() }
    }

    private var trashButton: some View {
        Button { requestRemove() } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundColor(Theme.textFaint)
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .fill(Theme.bgSelected.opacity(0.6))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove channel")
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { draftName = channel.name; return }
        channel.rename(trimmed)
    }

    private func requestRemove() {
        if channel.isConnected || isProgram { confirmingDelete = true }
        else { onRemove() }
    }
}

// MARK: - Security footer (ONE button — set / change the Bridge password)

/// A single button pinned to the bottom of the Channels rail.  Setting a password
/// IS turning auth on (it gates every channel); no password = open.  No toggle,
/// no explanatory blurb — just the button, which opens a small sheet to enter /
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
        .sheet(isPresented: $showSheet) { sheet }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(model.hasPassword ? "Change password" : "Set password")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("One password for every channel. Cameras must enter it to connect.")
                .font(.system(size: 11)).foregroundColor(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, Spacing.sm)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Theme.bgApp))
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                .onSubmit { commit() }
            HStack {
                if model.hasPassword {
                    Button("Remove") { model.setPassword(""); showSheet = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.accentRed)
                }
                Spacer()
                Button("Cancel") { showSheet = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Button { commit() } label: {
                    Text("Save").font(.system(size: 12, weight: .semibold)).frame(width: 64, height: 30)
                }
                .bridgeButton(selected: !draft.isEmpty)
                .disabled(draft.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 340)
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
