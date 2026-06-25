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

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(width: 280)
        .background(Theme.bgRail)
        // Faint hairline separating this rail from the center zone (matches the
        // ChannelsRail edge + the mode-bar / footer dividers).
        .overlay(Rectangle().frame(width: 1).foregroundColor(Theme.stroke),
                 alignment: .leading)
    }

    // "Outputs" + inline "+".  These are the PROGRAM's outputs — whatever is on
    // program (the on-air camera) is what they publish; they aren't tied to one
    // channel.
    private var header: some View {
        HStack(spacing: Spacing.sm) {
            // Title reflects the current mode so it's clear what the program (and
            // thus these outputs) is fed from: the solo channel vs the multiview CUT.
            Text(model.mode == .multiview ? "Multiview outputs" : "Solo outputs")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            // "+" (semi-transparent box, right edge — replaces the old count) opens a
            // menu of output TYPES: NDI adds a real output; SRT / RTSP / Virtual
            // Camera show as "soon" (disabled).
            Menu {
                ForEach(OutputKind.allCases) { kind in
                    Button {
                        if kind.isImplemented { addProgramOutput(kind, to: model) }
                    } label: {
                        Label(kind.isImplemented ? kind.displayName : "\(kind.displayName) — soon",
                              systemImage: kind.symbolName)
                    }
                    .disabled(!kind.isImplemented)
                }
            } label: {
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
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a program output")
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

    @State private var draftLabel: String = ""
    @State private var draftConfig: String = ""
    @State private var refresh = 0
    @State private var confirmingDelete = false
    @State private var editingName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        _ = refresh // re-evaluate after a start/stop/rename bump
        return Card(padding: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                controlRow    // badge · arrows · on/off
                nameRow       // name field + delete (right of it)
                secondRow     // SRT destination / RTSP URL — only where it carries info
            }
        }
        .onAppear { draftLabel = output.label; draftConfig = output.config }
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

    // TOP line: kind badge on the left, controls (delete + on/off) on the right.
    // The name moved to its own full-width row below — inline it was cramped (a wide
    // badge like "OBS AIRLIVE BRIDGE" squeezed the field out).
    private var controlRow: some View {
        HStack(spacing: Spacing.sm) {
            kindBadge
            reorderArrows           // ▲/▼ right of the protocol tag
            Spacer(minLength: Spacing.xs)
            onOffToggle
        }
    }

    /// Name + delete on one row — the trash sits to the right of the name field.
    private var nameRow: some View {
        HStack(spacing: Spacing.sm) {
            nameField
            trashButton
        }
    }

    /// ▲/▼ reorder-by-one — one chip the same height as every other control.
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

    /// The kind tag IS the live indicator: red fill + white text when publishing,
    /// neutral otherwise.  Same 28pt height + 6pt radius as every other control.
    private var kindBadge: some View {
        let live = output.isLive
        return HStack(spacing: Spacing.xxs) {
            Image(systemName: output.kind.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 13)                      // uniform icon column
            Text(output.kind.badgeLabel)               // short code, never the long name
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .frame(minWidth: 30, alignment: .leading)   // pad every tag to the widest (RTSP)
        }
        .foregroundColor(live ? .white : Theme.textSecondary)
        .padding(.horizontal, Spacing.sm)
        .frame(height: ControlMetrics.pillHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(live ? Theme.accentRed : Theme.bgSelected)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Inline, flexible source-name field (the real NDI source name; a display label
    /// for the others). Takes the row's slack width between the badge and the trash.
    // Read-only label in a field-styled box; double-click to edit, Return or focus-loss
    // commits — never auto-focused / stuck (the bug the always-editable field had).
    @ViewBuilder
    private var nameField: some View {
        Group {
            if editingName {
                TextField(output.kind.displayName, text: $draftLabel)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit { commitLabel() }
                    .onExitCommand { editingName = false }
                    .onChange(of: nameFocused) { focused in if !focused && editingName { commitLabel() } }
            } else {
                Text(output.label.isEmpty ? output.kind.displayName : output.label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditName() }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(Theme.textPrimary)
        .padding(.horizontal, Spacing.sm)
        .frame(height: ControlMetrics.pillHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Theme.bgApp)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .stroke(editingName ? Theme.accentBlue : Theme.stroke, lineWidth: 1)
        )
    }

    private func beginEditName() {
        draftLabel = output.label
        editingName = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private var trashButton: some View {
        Button { requestDelete() } label: {
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
        .help("Remove output")
    }

    private var onOffToggle: some View {
        Toggle("", isOn: Binding(
            get: { output.isLive },
            set: { newValue in
                if newValue { output.start() } else { output.stop() }
                refresh += 1
                // isLive changed but the array didn't — nudge the model so observers
                // (the badge colour, channel rows) re-read.
                model.objectWillChange.send()
            }
        ))
        .toggleStyle(.switch)
        .tint(Theme.accentBlue)   // native blue switch (the live status is the red badge)
        .labelsHidden()
        .fixedSize()
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

    private var srtDestinationField: some View {
        TextField(output.kind.configFieldExample, text: $draftConfig)
            .textFieldStyle(.plain)
            .font(.system(size: 11).monospaced())
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .frame(height: ControlMetrics.pillHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Theme.bgApp)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .onSubmit { output.config = draftConfig.trimmingCharacters(in: .whitespaces); refresh += 1 }
    }

    /// The actual address a client connects to: rtsp://<this-mac>:<port>/program.
    /// Read-only (the path/port are fixed by the server) with a copy button.
    private var rtspURLLine: some View {
        let port = (output as? RTSPOutput)?.port ?? 8554
        let url = "rtsp://\(ProcessInfo.processInfo.hostName):\(port)/program"
        return HStack(spacing: Spacing.xs) {
            Image(systemName: "link").font(.system(size: 10)).foregroundColor(Theme.textFaint)
            Text(url)
                .font(.system(size: 11).monospaced())
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Theme.textFaint)
            }
            .buttonStyle(.plain)
            .help("Copy RTSP URL")
        }
        .padding(.horizontal, Spacing.sm)
        .frame(height: ControlMetrics.pillHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Theme.bgApp)
        )
    }

    /// Live outputs confirm before removal; idle ones delete immediately.
    private func requestDelete() {
        if output.isLive { confirmingDelete = true }
        else { model.removeProgramOutput(output) }
    }

    private func commitLabel() {
        editingName = false
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { output.label = trimmed; refresh += 1 }
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
        case .srt:  return "srt://host:port"
        case .rtsp: return "rtsp://0.0.0.0:8554/live/cam"
        case .vcam: return "Airlive Camera"
        }
    }
}
