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
import AppKit   // NSPasteboard — copy the RTSP URL

struct OutputsRail: View {
    @ObservedObject var model: BridgeModel
    /// Focus mode: collapse to a minimal strip (just active-output tags) so the
    /// centre gets maximum room for the multiview.
    var collapsed: Bool = false
    /// Toggle this rail's collapsed state (chevron lives on the rail; state in ContentView).
    var onToggleCollapse: () -> Void = {}

    /// Collapsed-strip width — matches the Channels strip so the centre stays centred.
    private let collapsedWidth: CGFloat = 64

    var body: some View {
        Group {
            if collapsed { collapsedStrip } else { fullRail }
        }
        .frame(width: collapsed ? collapsedWidth : 280)
        .background(Theme.bgRail)
        // Faint hairline separating this rail from the center zone (matches the
        // ChannelsRail edge + the mode-bar / footer dividers).
        .overlay(Rectangle().frame(width: 1).foregroundColor(Theme.stroke),
                 alignment: .leading)
        // Click anywhere that isn't a field/control → leave any in-progress inline edit
        // (name or SRT destination), so nothing can get stuck focused.
        .contentShape(Rectangle())
        .onTapGesture { resignInlineEditing() }
    }

    private var fullRail: some View {
        VStack(spacing: 0) {
            header
            content
        }
    }

    /// Focus mode strip: compact tags for the program outputs — LIVE ones red
    /// ("active") with white text, idle ones neutral + dimmed.  Mirrors the kind
    /// badge so the strip reads at a glance.
    private var collapsedStrip: some View {
        VStack(spacing: 0) {
            collapseChevron("chevron.left")   // expand this column back
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.md)
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(Array(model.programOutputs.enumerated()), id: \.element.id) { pair in
                        CollapsedOutputTag(output: pair.element)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
            }
        }
    }

    /// Bare chevron that toggles this rail's collapsed state (no label — pure control).
    private func collapseChevron(_ system: String) -> some View {
        Button(action: onToggleCollapse) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // "Outputs" + inline "+".  These are the PROGRAM's outputs — whatever is on
    // program (the on-air camera) is what they publish; they aren't tied to one
    // channel.
    private var header: some View {
        HStack(spacing: Spacing.sm) {
            // These publish the PROGRAM bus (the CUT result) — plural, there can be
            // several (NDI + OBS + RTSP + SRT…).
            Text("Program Outputs")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            // "+" (semi-transparent box, right edge — replaces the old count) opens a
            // menu of output TYPES: NDI adds a real output; SRT / RTSP / Virtual
            // Camera show as "soon" (disabled).
            MenuButton(rows: {
                // OBS is offered only while absent — one local plugin to feed (single loopback slot).
                let hasOBS = model.programOutputs.contains { $0.kind == .obs }
                return OutputKind.allCases.filter { $0 != .obs || !hasOBS }.map { kind in
                    DropdownRow(id: kind.displayName,
                                label: kind.isImplemented ? kind.displayName : "\(kind.displayName) — soon",
                                icon: kind.symbolName,
                                isDisabled: !kind.isImplemented,
                                action: { if kind.isImplemented { addProgramOutput(kind, to: model) } })
                }
            }) {
                // Match the Channels "+" exactly (boxed: fill + 1pt stroke).
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
            .help("Add a program output")
            collapseChevron("chevron.right")   // collapse this column
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if model.programOutputs.isEmpty {
            chooser
        } else {
            // ScrollView + VStack (not a List) for UNIFORM spacing: the gap above the
            // first card == the gap between cards == Spacing.sm, and the side margins ==
            // Spacing.lg, matching the header.  Reorder is via the ▲/▼ arrows.
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(Array(model.programOutputs.enumerated()), id: \.element.id) { pair in
                        let idx = pair.offset
                        let output = pair.element
                        OutputCard(model: model,
                                   output: output,
                                   isFirst: idx == 0,
                                   isLast: idx == model.programOutputs.count - 1,
                                   onMoveUp:   { model.moveProgramOutput(from: IndexSet(integer: idx), to: idx - 1) },
                                   onMoveDown: { model.moveProgramOutput(from: IndexSet(integer: idx), to: idx + 2) })
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.lg)
            }
        }
    }

    /// First-step quick-pick — what protocol the PROGRAM publishes to.
    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Publish the program to…")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textFaint)
                    .padding(.horizontal, Spacing.xs)
                ForEach(OutputKind.allCases) { kind in
                    ChooserCard(kind: kind) {
                        addProgramOutput(kind, to: model)
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.lg)
        }
    }
}

/// Create the right output for `kind` (NDI sender or OBS passthrough relay) with
/// an auto-numbered name, and add it to the program bus.
private func addProgramOutput(_ kind: OutputKind, to model: BridgeModel) {
    let name = defaultName(kind, model)
    switch kind {
    case .ndi:  model.addProgramOutput(NDIOutput(label: name))
    case .obs:  model.addProgramOutput(AirliveRelayOutput(label: name))
    case .hdmi: model.addProgramOutput(HDMIOutput(label: name))
    case .rtsp: model.addProgramOutput(RTSPOutput(label: name, port: nextRTSPPort(model)))
    case .srt:  model.addProgramOutput(SRTOutput(label: name))
    case .vcam: break   // Virtual Camera is "soon"
    }
}

/// Lowest free RTSP port from 8554 up, so multiple RTSP outputs don't collide.
private func nextRTSPPort(_ model: BridgeModel) -> UInt16 {
    let used = Set(model.programOutputs.compactMap { ($0 as? RTSPOutput)?.port })
    var p: UInt16 = 8554
    while used.contains(p) { p += 1 }
    return p
}

/// Auto-numbered default name per kind, lowest free index, so LAN source names
/// stay stable and readable.
private func defaultName(_ kind: OutputKind, _ model: BridgeModel) -> String {
    let base = kind.displayName                       // "NDI", "RTSP", "SRT", "OBS Airlive Bridge"
    let used = Set(model.programOutputs.map(\.label))
    if !used.contains(base) { return base }           // bare name (the default card)
    var n = 2                                          // extras: "NDI 2", "NDI 3"…
    while used.contains("\(base) \(n)") { n += 1 }
    return "\(base) \(n)"
}

// MARK: - Collapsed output tag (focus-mode strip)

/// A compact program-output tag for the collapsed Outputs strip.  LIVE = red
/// ("active") with white text; idle = neutral + dimmed.  Reads `output.isLive` at
/// render — the rail re-renders when a toggle nudges the model's objectWillChange.
private struct CollapsedOutputTag: View {
    let output: VideoOutput
    var body: some View {
        // The always-on OBS relay reads "live" only while actually CONNECTED to OBS —
        // its isLive is permanently true by design (no toggle).
        let live = (output as? AirliveRelayOutput).map(\.isConnected) ?? output.isLive
        return VStack(spacing: 2) {
            Image(systemName: output.kind.symbolName)
                .font(.system(size: 11, weight: .semibold))
            Text(output.kind.badgeLabel)                   // short code (NDI / RTSP / OBS…)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
        }
        // Same tally treatment as the channels strip's OrdinalBadge: bright text on a
        // SOLID DARK fill (deep green when live), never a bright filled chip.
        .foregroundColor(live ? Theme.previewGreen : Theme.textSecondary)
        .frame(width: 48, height: 40)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(live ? Theme.tallyPreviewBg : Theme.bgSelected.opacity(0.6))
        )
        .opacity(live ? 1.0 : 0.55)
        .help(output.label + (live ? " — live" : " — idle"))
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
    @ObservedObject var model: BridgeModel
    let output: VideoOutput
    let isFirst: Bool
    let isLast: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var refresh = 0
    @State private var confirmingDelete = false
    /// Flashes the SRT destination field red for ~2 s when the operator tries to
    /// turn SRT on with no destination — otherwise the click just does nothing.
    @State private var flashConfigError = false
    /// Persisted: once the operator ✕-dismisses the "Get Plugin for OBS" line it
    /// stays hidden (there's exactly one OBS card, so a global flag is correct).
    @AppStorage("bridge.obsPluginLinkDismissed") private var pluginLinkDismissed = false

    /// Same template as the channel cards: TOP = On/Off chip · protocol tag ··· trash;
    /// BOTTOM = ▲/▼ chip · editable name.  The On/Off chip and the ▲/▼ chip share one
    /// width (`ControlMetrics.chipWidth`) so the left column stacks exactly.
    /// OBS is a SINGLE row (▲/▼ · tag · status ··· trash) — no power (always on),
    /// no name (it lives in OBS), so there is nothing to put on a second row.
    var body: some View {
        _ = refresh // re-evaluate after a start/stop/rename bump
        let live = isLiveNow
        return Card(padding: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if output.kind == .obs {
                    obsRow(live: live)
                    // Not connected → a dismissable "Get Plugin for OBS ↗" line under a
                    // divider (the operator who forgot the plugin has a way forward; the ✕
                    // hides it for good once they've got it).  Connected → nothing extra.
                    if !live && !pluginLinkDismissed {
                        Divider().overlay(Theme.stroke)
                        pluginLinkRow
                    }
                } else if output.kind == .hdmi {
                    // HDMI Out: toggle · tag ··· trash on top; ▲/▼ · display picker below
                    // (no editable name — the "name" is which screen it fills).
                    topRow(live: live)
                    HStack(spacing: Spacing.sm) {
                        reorderArrows
                        displayPicker
                    }
                    // "Connect a second display…" / "display disconnected" in red on the card.
                    if let error = output.lastError { errorRow(error) }
                } else {
                    topRow(live: live)
                    bottomRow
                    secondRow
                    // Transport failure, in red ON THE CARD — a failed toggle must
                    // never look identical to a never-clicked one (the reason used
                    // to live only in Console).  Cleared by the next success.
                    if let error = output.lastError { errorRow(error) }
                }
            }
        }
        // Removing a LIVE output cuts the stream — confirm first (an idle one deletes
        // straight away).
        .confirmationDialog("Remove “\(output.label)” while it’s live?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove output", role: .destructive) { model.removeProgramOutput(output) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(output.kind.displayName) is publishing right now — removing it stops the stream.")
        }
    }

    /// "Live" for the dot/outline: the OBS relay is live only while ACTUALLY connected
    /// (its isLive is just the toggle); the others publish the moment they're on.
    private var isLiveNow: Bool {
        (output as? AirliveRelayOutput).map(\.isConnected) ?? output.isLive
    }

    // TOP: On/Off chip (same size as the ▲/▼ chip below — the two stack in one
    // column) · protocol tag ··· trash.
    private func topRow(live: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            onOffToggle
            Text(output.kind.badgeLabel)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: Spacing.xs)
            trashButton
        }
    }

    // BOTTOM: ▲/▼ chip · editable name.
    private var bottomRow: some View {
        HStack(spacing: Spacing.sm) {
            reorderArrows
            nameField
        }
    }

    /// The whole OBS card in ONE row: ▲/▼ · tag · connection status ··· trash.
    private func obsRow(live: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            reorderArrows
            Text(output.kind.badgeLabel)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(Theme.textSecondary)
            Text(live ? "Connected" : "Add Plugin in OBS")
                .font(.system(size: 10, weight: live ? .semibold : .regular))
                .foregroundColor(live ? Theme.previewGreen : Theme.textFaint)
                .lineLimit(1)
                .help(live ? "Program is feeding the OBS \"Airlive Bridge\" source"
                           : "Launch OBS and add the \"OBS Airlive Bridge\" source — connects automatically")
            Spacer(minLength: Spacing.xs)
            trashButton
        }
    }

    /// HDMI Out display chooser — a flat dropdown (styled like the name field) that
    /// lists the connected screens; picking one moves the projector there live.
    private var displayPicker: some View {
        let screens = NSScreen.screens
        // resolveScreen returns nil when there's no external display (config empty/stale)
        // — show "No display" then, honestly.
        let current: NSScreen? = (output as? HDMIOutput).flatMap { HDMIOutput.resolveScreen($0.config) }
        // Screens ALREADY claimed by ANOTHER HDMI output — greyed out so two HDMI outputs
        // can't stack on one display (a rare setup, but a confusing one).
        let claimed = Set(model.programOutputs
            .compactMap { $0 as? HDMIOutput }
            .filter { $0.id != output.id }
            .compactMap { HDMIOutput.resolveScreen($0.config)?.displayID })
        // Our Dropdown keys by the label STRING, so labels must be 1:1 with screens — two identical
        // monitors share `localizedName` and would collide (the 2nd row un-selectable, its check
        // ambiguous).  Build unique labels keyed by the stable CGDirectDisplayID (which the MODEL
        // already uses via setDisplay/resolveScreen); a name collision gets a " (2)" suffix.
        let labelByID = Self.uniqueScreenLabels(screens)
        let named = screens.map { (label: labelByID[$0.displayID] ?? "Display", screen: $0) }
        let currentLabel = current.flatMap { labelByID[$0.displayID] }
        return Dropdown(items: named.map(\.label),
                        selection: currentLabel,
                        displayText: currentLabel ?? "No display",
                        isPlaceholder: currentLabel == nil,
                        disabledItems: Set(named.filter { claimed.contains($0.screen.displayID) }.map(\.label)),
                        triggerHeight: ControlMetrics.pillHeight) { picked in
            guard let screen = named.first(where: { $0.label == picked })?.screen else { return }
            (output as? HDMIOutput)?.setDisplay(String(screen.displayID))
            refresh += 1
            model.objectWillChange.send()
        }
    }

    /// A DISTINCT label for every screen, keyed by CGDirectDisplayID.  `screenName` alone collides
    /// for two identical-model monitors (same `localizedName`); a collision gets a " (2)", " (3)" …
    /// suffix so the Dropdown's string keys stay 1:1 with screens.  The model still keys by the
    /// stable displayID, so a label reshuffle across renders never corrupts the stored selection.
    private static func uniqueScreenLabels(_ screens: [NSScreen]) -> [CGDirectDisplayID: String] {
        var counts: [String: Int] = [:]
        var result: [CGDirectDisplayID: String] = [:]
        for (i, screen) in screens.enumerated() {
            let base = screenName(screen, index: i)
            let n = (counts[base] ?? 0) + 1
            counts[base] = n
            result[screen.displayID] = n == 1 ? base : "\(base) (\(n))"
        }
        return result
    }

    /// A friendly screen label.  `localizedName` is macOS 14+; on 13 fall back to
    /// "Main display" / "Display N (WxH)" so the picker never shows a blank.
    private static func screenName(_ screen: NSScreen, index: Int) -> String {
        if #available(macOS 14.0, *) {
            let name = screen.localizedName
            if !name.isEmpty { return name }
        }
        if screen == NSScreen.main { return "Main display" }
        let w = Int(screen.frame.width), h = Int(screen.frame.height)
        return "Display \(index + 1) (\(w)×\(h))"
    }

    /// Second line on the OBS card when not connected: link (left) + ✕ dismiss (right).
    private static let pluginDownloadURL = URL(string: "https://airlive.vercel.app/downloads")!
    private var pluginLinkRow: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                NSWorkspace.shared.open(Self.pluginDownloadURL)
            } label: {
                HStack(spacing: 4) {
                    Text("Get Plugin for OBS")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(Theme.accentBlue)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { NSCursor.pointingHand.set(); if !$0 { NSCursor.arrow.set() } }
            .help("Opens the download page for the OBS plugin")
            Spacer(minLength: Spacing.xs)
            Button { pluginLinkDismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide this")
        }
    }

    /// A card-visible transport error with a ✕ to dismiss it — so a message doesn't hang forever (e.g.
    /// HDMI "connect a second display").  A NEW failure re-sets `lastError`, so dismissing hides the
    /// current line without silencing future ones.
    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Text(error)
                .font(.system(size: 10))
                .foregroundColor(Theme.accentRed)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { output.clearError(); refresh += 1 } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    /// ▲/▼ reorder-by-one, boxed in a chip the exact size of the On/Off chip, so the
    /// two stack in a clean column.  The inapplicable direction stays visible but
    /// semi-transparent and inert.
    private var reorderArrows: some View {
        HStack(spacing: Spacing.xxs) {
            arrowButton("chevron.up",   enabled: !isFirst, action: onMoveUp)
            arrowButton("chevron.down", enabled: !isLast,  action: onMoveDown)
        }
        .frame(width: ControlMetrics.chipWidth, height: ControlMetrics.pillHeight)
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
                // Inactive = the SAME arrow ghosted to ~1/3 opacity (matches ChannelsRail).
                .foregroundColor(Theme.textSecondary.opacity(enabled ? 1 : 0.35))
                .frame(width: 16, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Source-name field (the real NDI source name; a display label for the others) — the
    /// shared inline-editable element: single click to rename, commits on blur/Return.
    private var nameField: some View {
        InlineEditable(placeholder: output.kind.displayName,
                       value: output.label,
                       font: .system(size: 12, weight: .medium)) {   // same as the channel name
            // Through the model: registers an undo record + nudges objectWillChange
            // (VideoOutput isn't observable) so the session autosave hears it too.
            model.renameOutput(output, to: $0); refresh += 1
        }
    }

    private var trashButton: some View {
        Button { requestDelete() } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove output")
    }

    /// The card's power state: off / connecting (on, no peer yet) / on.  Only the two
    /// CALLER-style outputs have a real connecting phase (OBS relay, SRT); NDI/RTSP are
    /// servers — flipping them on IS being live.
    private var powerState: PowerToggle.PowerState {
        if let relay = output as? AirliveRelayOutput {
            return !relay.isLive ? .off : (relay.isConnected ? .on : .connecting)
        }
        if let srt = output as? SRTOutput {
            return !srt.isLive ? .off : (srt.isConnected ? .on : .connecting)
        }
        return output.isLive ? .on : .off
    }

    private var onOffToggle: some View {
        PowerToggle(state: powerState) { toggle() }
    }

    /// Turn the output on/off.  Refuses to start an SRT output with no destination —
    /// instead of the click silently doing nothing, flash the destination field red
    /// so the operator sees WHERE the missing input is.
    private func toggle() {
        if output.isLive { output.stop() }
        else {
            if output.kind == .srt,
               output.config.trimmingCharacters(in: .whitespaces).isEmpty {
                flashConfigError = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { flashConfigError = false }
                return
            }
            output.start()
        }
        refresh += 1
        // isLive changed but the array didn't — nudge the model so observers re-read.
        model.objectWillChange.send()
    }

    /// A second line ONLY where it carries real information: SRT's destination (the
    /// one editable transport field) and RTSP's live serving URL (read-only + copy).
    /// NDI and OBS need no extra field — the dead "NDI group" / OBS-instruction
    /// fields were removed.
    @ViewBuilder
    private var secondRow: some View {
        switch output.kind {
        case .srt:  srtDestinationField
        case .rtsp: rtspURLLine
        default:    EmptyView()
        }
    }

    /// SRT destination — the shared inline-editable element (monospaced; may be cleared).
    /// Flashes red when the operator toggles SRT on while it's empty (see `toggle()`).
    private var srtDestinationField: some View {
        InlineEditable(placeholder: output.kind.configFieldExample,
                       value: output.config,
                       font: .system(size: 11).monospaced(),
                       allowEmpty: true,
                       errorFlash: flashConfigError) {
            model.setOutputConfig(output, to: $0); refresh += 1   // undo + autosave (see nameField)
        }
    }

    /// The actual address a client connects to: rtsp://<this-mac>:<port>/program.
    /// Read-only (the path/port are fixed by the server) with a copy button.
    private var rtspURLLine: some View {
        let port = (output as? RTSPOutput)?.port ?? 8554
        let url = "rtsp://\(ProcessInfo.processInfo.hostName):\(port)/program"
        return HStack(spacing: Spacing.xs) {
            Text(url)
                .font(.system(size: 10).monospaced())
                .foregroundColor(Theme.textFaint)
                .lineLimit(1).truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Copy RTSP URL")
            Spacer(minLength: 0)
        }
    }

    /// Live outputs confirm before removal; idle ones delete immediately.
    /// `isLiveNow`, NOT `isLive`: the OBS relay's isLive is permanently true (it's
    /// always listening for the plugin) — only an ACTUAL connection means removing
    /// it cuts a stream.  Nothing connected → nothing to warn about.
    private func requestDelete() {
        if isLiveNow { confirmingDelete = true }
        else { model.removeProgramOutput(output) }
    }
}

// MARK: - Power chip (the card's custom on/off control)

/// Custom on/off switch (our own, NOT the system Toggle — AppKit chrome renders
/// differently across macOS versions and breaks the flat look).  Sized exactly
/// like the card's ▲/▼ chip so the two stack in a clean column.  Track = accent
/// blue when on, quiet dark chip when off; white knob slides left↔right; the
/// connecting phase shows a spinner in place of the knob.
struct PowerToggle: View {
    enum PowerState { case off, connecting, on }
    let state: PowerState
    let action: () -> Void

    /// Gap between the track edge and the knob.
    private let inset: CGFloat = 3

    var body: some View {
        let knobSide = ControlMetrics.pillHeight - inset * 2   // square knob, 22 pt
        Button(action: action) {
            ZStack(alignment: state == .off ? .leading : .trailing) {
                // Track — button-radius per the corner scale (the knob gets the
                // smaller control radius, keeping the two curvatures concentric).
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(state == .on ? Theme.accentBlue : Theme.bgSelected)
                if state != .on {
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                }
                switch state {
                case .connecting:
                    ProgressView()
                        .controlSize(.mini)
                        .frame(maxWidth: .infinity)   // centered on the track
                case .on, .off:
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.white)
                        .frame(width: knobSide, height: knobSide)
                        .padding(inset)
                }
            }
            .frame(width: ControlMetrics.chipWidth, height: ControlMetrics.pillHeight)
            .animation(.easeInOut(duration: 0.15), value: state == .on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state == .connecting ? "Connecting…" : (state == .on ? "On — click to stop" : "Off — click to start"))
    }
}

// MARK: - Per-kind config field copy

/// The config field's caption and example value, per transport. ONE source of
/// truth shared by the real `OutputCard` and the chooser tiles.
private extension OutputKind {
    var configFieldExample: String {
        switch self {
        case .ndi:  return "public"
        case .obs:  return "Add the OBS Airlive Bridge source in OBS"
        case .hdmi: return "Second screen"
        case .srt:  return "srt://host:port"
        case .rtsp: return "rtsp://0.0.0.0:8554/live/cam"
        case .vcam: return "Airlive Camera"
        }
    }
}
