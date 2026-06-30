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
    /// Focus mode: collapse to a minimal strip (just the ordinal badges) so the
    /// centre gets maximum room for the multiview.
    var collapsed: Bool = false
    /// Toggle this rail's collapsed state — the chevron lives on the rail (header when open,
    /// strip top when collapsed); state itself lives in ContentView (drives the width).
    var onToggleCollapse: () -> Void = {}

    /// Collapsed-strip width — just wide enough for the ordinal badge + margins.
    private let collapsedWidth: CGFloat = 64

    var body: some View {
        Group {
            if collapsed { collapsedStrip } else { fullRail }
        }
        .frame(width: collapsed ? collapsedWidth : 280)   // 280 matches the Outputs rail (window-centered)
        .background(Theme.bgRail)
        // Faint hairline separating this rail from the center zone (consistent
        // with the OutputsRail edge + the mode-bar / footer dividers).
        .overlay(Rectangle().frame(width: 1).foregroundColor(Theme.stroke),
                 alignment: .trailing)
        // Click anywhere that isn't a row or control → leave any in-progress inline edit.
        .contentShape(Rectangle())
        .onTapGesture { resignInlineEditing() }
    }

    private var fullRail: some View {
        VStack(spacing: 0) {
            header
            list
                .frame(maxHeight: .infinity)
            SecurityFooter(model: model)   // ONE global password for the Bridge
        }
    }

    /// Focus mode strip: ONLY the ordinal badges, same tally colours as the full
    /// rail (red on air / green staged / neutral).  Tap one to select it.
    private var collapsedStrip: some View {
        VStack(spacing: 0) {
            collapseChevron("chevron.right")   // expand this column back
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.md)
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(Array(model.channels.enumerated()), id: \.element.id) { pair in
                        let idx = pair.offset
                        let channel = pair.element
                        Button { model.select(channel.id) } label: {
                            OrdinalBadge(index: idx + 1,
                                         isProgram: channel.id == model.effectiveProgramID,
                                         isPreview: channel.id == model.previewID)
                        }
                        .buttonStyle(.plain)
                        .help(channel.name)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
            }
        }
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
            collapseChevron("chevron.left")   // collapse this column
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    /// Bare chevron that toggles this rail's collapsed state (no label — pure control).
    private func collapseChevron(_ system: String) -> some View {
        Button(action: onToggleCollapse) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.textFaint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            // One channel, two transports for the same phone: AirPlay video + Airlive
            // control-only (no second encode — cool phone).
            Button { model.addChannel(kind: .screenMirroringPlusControl) } label: {
                Label("Screen Mirroring + Remote Control", systemImage: "plus.rectangle.on.rectangle")
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
                VStack(spacing: Spacing.sm) {
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
                            onSelect: { model.select(channel.id); resignInlineEditing() },
                            onRemove: {
                                TallyStore.shared.clear(channel.id)
                                model.removeChannel(channel.id)
                            },
                            onMoveUp:   { model.moveChannel(from: IndexSet(integer: idx), to: idx - 1) },
                            onMoveDown: { model.moveChannel(from: IndexSet(integer: idx), to: idx + 2) }
                        )
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.lg)
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

    @State private var confirmingDelete = false
    @State private var showSettings = false

    var body: some View {
        Card(padding: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                topRow        // connection · source kind · gear · delete
                bottomRow     // ordinal · arrows · name
                // Settings expand INLINE here (in the rail) — never a floating popover over
                // the multiview.  Full card width, so the description sits cleanly below.
                if showSettings {
                    Divider().overlay(Theme.stroke)
                    ChannelSettingsView(channel: channel)
                }
            }
        }
        // Click the row (anywhere but the name field) drives the Solo preview.
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
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
            statusLine                       // connection icon — now on the LEFT
            Text(channel.kind.sourceLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.xs)
            gearButton                       // per-source delay (combined channels have video too)
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

    /// Position number that doubles as a subtle TALLY hint: the DIGIT tints red on
    /// PROGRAM (on air) / green on PREVIEW (staged); the box stays a quiet dark chip so
    /// it stays auxiliary and doesn't grab attention.  Renumbers on reorder.
    private var ordinalBadge: some View {
        OrdinalBadge(index: index, isProgram: isProgram, isPreview: isPreview)
    }

    /// ▲/▼ reorder-by-one — one chip the same height as the number / name / trash.
    private var reorderArrows: some View {
        HStack(spacing: 0) {
            arrowButton("chevron.up",   enabled: !isFirst, action: onMoveUp)
            arrowButton("chevron.down", enabled: !isLast,  action: onMoveDown)
        }
        .frame(height: ControlMetrics.pillHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Theme.bgSelected.opacity(0.6))
        )
    }

    private func arrowButton(_ system: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(enabled ? Theme.textSecondary : Theme.textFaint.opacity(0.4))
                .frame(width: 22, height: ControlMetrics.pillHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Signal status — is this camera's stream actually arriving?  The director spots a
    /// dropped phone at a glance (green Connected → grey Disconnected).  Whether it's on
    /// air is read from the center preview, not from this list.
    private var statusLine: some View {
        let connected = channel.anyConnected   // combined channel: control link counts too
        return Image(systemName: connected ? "wifi" : "wifi.slash")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(connected ? Theme.previewGreen : Theme.textFaint)
            .help(connected ? "Connected" : "Disconnected")
    }

    // MARK: Name — the shared inline-editable element (single click to rename).
    private var nameField: some View {
        InlineEditable(placeholder: "Channel",
                       value: channel.name,
                       font: .system(size: 13, weight: .semibold)) { channel.rename($0) }
    }

    /// Per-channel settings (the gear, where the connection icon used to sit) — opens a
    /// popover.  For now it holds the precise "Additional delay (ms)"; more lands here later.
    private var gearButton: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundColor(Theme.textFaint)
                .frame(width: 36, height: ControlMetrics.pillHeight)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Theme.bgSelected.opacity(0.6))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Channel settings")
    }

    private var trashButton: some View {
        Button { requestRemove() } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundColor(Theme.textFaint)
                .frame(width: 36, height: ControlMetrics.pillHeight)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Theme.bgSelected.opacity(0.6))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove channel")
    }

    private func requestRemove() {
        if channel.anyConnected || isProgram { confirmingDelete = true }   // control-only link counts
        else { onRemove() }
    }
}

// MARK: - Ordinal badge (the channel number — shared by the full row + the collapsed strip)

/// The channel's position number, coloured by tally: bright digit on a SOLID DARK
/// tally fill — deep red on air, deep green staged, neutral chip otherwise.  Same
/// element in the full rail and the focus-mode strip, so they always match.
struct OrdinalBadge: View {
    let index: Int
    let isProgram: Bool
    let isPreview: Bool

    var body: some View {
        let digit: Color = isProgram ? Theme.accentRed
                         : (isPreview ? Theme.previewGreen : Theme.textSecondary)
        let fill: Color = isProgram ? Color(hex: 0x4A1E1E)                    // deep red
                        : (isPreview ? Color(hex: 0x18421F)                   // deep green
                        : Theme.bgSelected.opacity(0.6))                      // neutral chip
        return Text("\(index)")
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundColor(digit)
            .frame(minWidth: ControlMetrics.pillHeight, alignment: .center)   // ≥ square, fits "00"
            .frame(height: ControlMetrics.pillHeight)                         // same height as every chip
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(fill)
            )
    }
}

// MARK: - Per-channel settings (inline, expands inside the card below the row)

/// Opened by the gear, INLINE in the rail.  A precise additional-delay field (type it) +
/// ±10 stepper + Reset — no vague tiers.  Holds this source on the Mac to line it up with
/// slower cameras (added on top of the preset).
private struct ChannelSettingsView: View {
    @ObservedObject var channel: BridgeChannel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(text: "Additional delay (ms)")
            HStack(spacing: Spacing.sm) {
                TextField("0", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity)             // stretch to fill — no empty gutter
                    .frame(height: ControlMetrics.pillHeight)
                    .padding(.horizontal, Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Theme.bgApp))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .stroke(focused ? Theme.accentBlue : Theme.stroke, lineWidth: 1))
                    .onSubmit { commit() }
                    .onChange(of: focused) { if !$0 { commit() } }
                resetButton                                 // Reset, left of the arrows
                Stepper("", value: Binding(
                    get: { channel.extraDelayMs },
                    set: { channel.extraDelayMs = max(0, $0); draft = String(channel.extraDelayMs) }
                ), step: 10)
                .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { draft = String(channel.extraDelayMs) }
    }

    /// Reset the additional delay to 0 (chip, left of the arrows).  Greyed + disabled when
    /// already 0 so it reads as "nothing to clear".
    private var resetButton: some View {
        Button {
            channel.extraDelayMs = 0
            draft = "0"
            focused = false
        } label: {
            Text("Reset")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(channel.extraDelayMs == 0 ? Theme.textFaint.opacity(0.5) : Theme.textSecondary)
                .frame(height: ControlMetrics.pillHeight)
                .padding(.horizontal, Spacing.sm)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Theme.bgSelected.opacity(0.6)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(channel.extraDelayMs == 0)
        .help("Reset additional delay to 0")
    }

    private func commit() {
        let v = max(0, Int(draft.trimmingCharacters(in: .whitespaces)) ?? channel.extraDelayMs)
        channel.extraDelayMs = v
        draft = String(v)
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
                Text(model.hasPassword ? "Airlive password set" : "Set Airlive password")
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
            Text("Protects your Airlive Camera channels — the iPhone enters it to connect. Screen Mirroring and HDMI / USB sources aren’t gated by it.")
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
