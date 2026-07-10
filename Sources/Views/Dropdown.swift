import SwiftUI
import AppKit   // NSEvent local monitor for dropdown keyboard navigation

/// Metrics live at file scope — a generic type can't hold `static let` stored properties, and these
/// are shared by the triggers + the overlay anyway.
private enum DropdownMetric {
    static let triggerHeight: CGFloat = 34   // matches the Look rows
    static let itemHeight: CGFloat = 30
    static let separatorHeight: CGFloat = 9
    static let listPad: CGFloat = 5          // uniform inner padding → even margins on all sides
    static let maxListHeight: CGFloat = 340  // then the list scrolls (LUT / screen lists)
    static let minWidth: CGFloat = 180
    static let gap: CGFloat = 4              // trigger ↔ list
    static let edgeMargin: CGFloat = 8       // keep the list this far inside the window on every side
}

// MARK: - Row model

/// One row of the floating list — a value option, an action, or a separator.  ONE model serves both
/// flavours (value-picker `Dropdown` + command `MenuButton`) so there is a SINGLE styled list in the
/// app, not a value list here and a native `Menu` there.
struct DropdownRow: Identifiable {
    let id: String
    var label: String = ""
    var icon: String? = nil          // SF Symbol, leading (command menus)
    var isSeparator: Bool = false
    var isDisabled: Bool = false
    var isSelected: Bool = false     // trailing check (value pickers)
    var action: () -> Void = {}

    static func separator(_ id: String) -> DropdownRow { DropdownRow(id: id, isSeparator: true) }
}

// MARK: - Presenter

/// Exactly one list is open at a time; `DropdownOverlay` (mounted once at the window root) draws it in
/// OUR palette + corner radius — NOT a system `.popover`/`NSMenu`, whose chrome we can't restyle.  The
/// trigger reports its `.global` frame so the list lands right under it (flipping above near an edge).
final class DropdownPresenter: ObservableObject {
    static let shared = DropdownPresenter()

    struct Active {
        let id: UUID
        var anchor: CGRect          // trigger frame in `.global` space
        var rows: [DropdownRow]
        var fitContent: Bool        // value picker → match the trigger width; command menu → fit content
    }

    @Published var active: Active? {
        didSet {
            // Only react to a list OPENING/CLOSING/SWITCHING — not to `updateAnchor`'s in-place
            // anchor tweaks (same id).  A keyDown monitor lives exactly as long as a list is open, so
            // arrow/return/type-ahead work WITHOUT SwiftUI focus (which would fight the rename fields).
            guard active?.id != oldValue?.id else { return }
            keyFocusID = active.flatMap { a -> String? in
                a.rows.first(where: { $0.isSelected })?.id ?? Self.firstSelectable(a.rows)
            }
            if oldValue == nil, active != nil { installKeyMonitor() }
            if active == nil, oldValue != nil { removeKeyMonitor() }
        }
    }
    /// The row the KEYBOARD is highlighting (arrow-key / type-ahead), distinct from mouse hover.
    @Published var keyFocusID: String?

    private var keyMonitor: Any?

    func toggle(_ a: Active) { active = (active?.id == a.id) ? nil : a }
    func updateAnchor(id: UUID, _ rect: CGRect) { if active?.id == id { active?.anchor = rect } }
    func close() { active = nil }

    // MARK: Keyboard navigation — self-contained NSEvent monitor, no SwiftUI focus stealing

    private static func firstSelectable(_ rows: [DropdownRow]) -> String? {
        rows.first { !$0.isSeparator && !$0.isDisabled }?.id
    }

    /// Move the highlight by `delta`, skipping separators + disabled rows, clamped at the ends.
    private func moveFocus(_ delta: Int) {
        guard let rows = active?.rows else { return }
        let pickable = rows.filter { !$0.isSeparator && !$0.isDisabled }
        guard !pickable.isEmpty else { return }
        let idx = pickable.firstIndex { $0.id == keyFocusID } ?? (delta > 0 ? -1 : pickable.count)
        keyFocusID = pickable[min(max(idx + delta, 0), pickable.count - 1)].id
    }

    /// Run the highlighted row's action + close (Return / Enter).
    private func activateFocused() {
        guard let row = active?.rows.first(where: { $0.id == keyFocusID }),
              !row.isSeparator, !row.isDisabled else { return }
        row.action()
        close()
    }

    /// Jump the highlight to the first selectable row whose label starts with `ch` (type-ahead).
    private func typeAhead(_ ch: Character) {
        let want = String(ch).lowercased()
        if let hit = active?.rows.first(where: {
            !$0.isSeparator && !$0.isDisabled && $0.label.lowercased().hasPrefix(want)
        }) { keyFocusID = hit.id }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.active != nil else { return event }
            // Only intercept BARE keys (no ⌘/⌃/⌥).  A Bridge shortcut rebound onto the same key —
            // ⌘↓, ⌘Return, ⌘Q, ⌘Z — must pass straight through, never be eaten by an open list.
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 125: self.moveFocus(1);  return nil            // ↓
            case 126: self.moveFocus(-1); return nil            // ↑
            case 36, 76: self.activateFocused(); return nil     // Return / Enter
            case 53: self.close(); return nil                   // Esc
            default:
                // Bare printable char → type-ahead; swallow so it can't leak into a field behind.
                if let ch = event.charactersIgnoringModifiers?.first, ch.isLetter || ch.isNumber {
                    self.typeAhead(ch)
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Value picker

/// Shared design-system dropdown: a full-width boxed trigger + our floating value list.
struct Dropdown: View {
    let items: [String]
    /// The active value — gets the check and is scrolled into view when the list opens.
    let selection: String?
    /// Text shown in the closed trigger (the selected title, or a placeholder like "—").
    var displayText: String
    var isPlaceholder: Bool = false
    var isEnabled: Bool = true
    /// Items shown greyed + non-selectable (e.g. an HDMI screen already claimed by another output).
    var disabledItems: Set<String> = []
    /// Trigger height — 34 fits the Look rows; pass 28 to sit flush with the Outputs-rail pills.
    var triggerHeight: CGFloat = 34
    let onSelect: (String) -> Void

    @ObservedObject private var presenter = DropdownPresenter.shared
    @State private var id = UUID()
    @State private var anchor: CGRect = .zero
    private var isOpen: Bool { presenter.active?.id == id }

    private var rows: [DropdownRow] {
        items.map { item in
            DropdownRow(id: item, label: item,
                        isDisabled: disabledItems.contains(item),
                        isSelected: item == selection,
                        action: { onSelect(item) })
        }
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            presenter.toggle(.init(id: id, anchor: anchor, rows: rows, fitContent: false))
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(displayText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isPlaceholder ? Theme.textFaint : Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, Spacing.sm)
            .frame(maxWidth: .infinity)
            .frame(height: triggerHeight)
            .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .fill(isOpen ? Theme.bgHover : Theme.bgSelected))
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .stroke(isOpen ? Theme.accentBlue.opacity(0.7) : Theme.strokeDivider, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .background(anchorReader($anchor, id: id))
        .onDisappear { if presenter.active?.id == id { presenter.close() } }
    }
}

// MARK: - Command menu

/// A trigger (any label) that opens our floating ACTION list — icons, separators, tap-to-run.  The
/// same styled overlay as `Dropdown`, so a "+" add-menu looks identical to a value picker.
struct MenuButton<Label: View>: View {
    /// Built lazily on click, so e.g. device discovery only runs when the menu opens — not per render.
    let rows: () -> [DropdownRow]
    @ViewBuilder var label: () -> Label

    @ObservedObject private var presenter = DropdownPresenter.shared
    @State private var id = UUID()
    @State private var anchor: CGRect = .zero

    var body: some View {
        Button { presenter.toggle(.init(id: id, anchor: anchor, rows: rows(), fitContent: true)) } label: {
            label()
        }
        .buttonStyle(.plain)
        .background(anchorReader($anchor, id: id))
        .onDisappear { if presenter.active?.id == id { presenter.close() } }
    }
}

/// Tracks a trigger's on-screen rect so the overlay can anchor to it.
private func anchorReader(_ anchor: Binding<CGRect>, id: UUID) -> some View {
    GeometryReader { g in
        Color.clear
            .onAppear { anchor.wrappedValue = g.frame(in: .global) }
            .onChange(of: g.frame(in: .global)) { newRect in
                // Ignore sub-pixel jitter so geometry feedback doesn't rewrite state every frame
                // (SwiftUI's "onChange tried to update multiple times per frame" warning).
                let old = anchor.wrappedValue
                guard abs(newRect.minX - old.minX) > 0.5 || abs(newRect.minY - old.minY) > 0.5
                        || abs(newRect.width - old.width) > 0.5 || abs(newRect.height - old.height) > 0.5
                else { return }
                anchor.wrappedValue = newRect
                DropdownPresenter.shared.updateAnchor(id: id, newRect)
            }
    }
}

// MARK: - Overlay  (mount ONCE at the window root: `.overlay(DropdownOverlay())`)

struct DropdownOverlay: View {
    @ObservedObject private var presenter = DropdownPresenter.shared
    @State private var hovered: String?
    @State private var listW: CGFloat = 0    // measured list width — command menus size to content

    var body: some View {
        GeometryReader { geo in
            if let a = presenter.active {
                let origin = geo.frame(in: .global).origin
                let local = CGRect(x: a.anchor.minX - origin.x, y: a.anchor.minY - origin.y,
                                   width: a.anchor.width, height: a.anchor.height)
                let contentH = a.rows.reduce(CGFloat(0)) {
                    $0 + ($1.isSeparator ? DropdownMetric.separatorHeight : DropdownMetric.itemHeight)
                }
                let listH = min(contentH + DropdownMetric.listPad * 2 + CGFloat(max(a.rows.count - 1, 0)),
                                DropdownMetric.maxListHeight)     // capped → the list scrolls past it
                let w = max(a.fitContent ? listW : local.width, DropdownMetric.minWidth)
                let m = DropdownMetric.edgeMargin

                // Clamp INSIDE the window on BOTH axes so the list never runs off an edge (was only
                // vertical → the Outputs "+" near the right edge overflowed).  Prefer left-aligned to
                // the trigger + opening downward; shift left / flip up only when it wouldn't fit.
                let x = min(max(local.minX, m), max(m, geo.size.width - w - m))
                let yBelow = local.maxY + DropdownMetric.gap
                let yUp = local.minY - DropdownMetric.gap - listH
                let y = (yBelow + listH > geo.size.height - m && yUp >= m)
                        ? yUp
                        : min(max(yBelow, m), max(m, geo.size.height - listH - m))

                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { presenter.close() }
                    Button("", action: presenter.close)          // Esc closes
                        .keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
                    sizedList(a, local: local)
                        .frame(height: listH)
                        .background(GeometryReader { g in Color.clear
                            .onAppear { listW = g.size.width }
                            .onChange(of: g.size.width) { w in if abs(w - listW) > 0.5 { listW = w } } })
                        .offset(x: x, y: y)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(presenter.active != nil)
    }

    /// Value pickers match the trigger width; command menus size to their content (with a floor).
    @ViewBuilder private func sizedList(_ a: DropdownPresenter.Active, local: CGRect) -> some View {
        if a.fitContent {
            list(a).fixedSize(horizontal: true, vertical: false).frame(minWidth: DropdownMetric.minWidth, alignment: .leading)
        } else {
            list(a).frame(width: max(local.width, DropdownMetric.minWidth))
        }
    }

    private func list(_ a: DropdownPresenter.Active) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(a.rows) { rowView($0) }
                }
                .padding(DropdownMetric.listPad)          // uniform on ALL sides
            }
            .scrollIndicators(.hidden)                    // kill the macOS scrollbar gutter
            .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Theme.bgPanel))
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).stroke(Theme.strokeDivider, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .onAppear { if let s = a.rows.first(where: { $0.isSelected })?.id { proxy.scrollTo(s, anchor: .center) } }
            // Keep the keyboard-highlighted row visible while arrowing / type-ahead through a long list.
            .onChange(of: presenter.keyFocusID) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    @ViewBuilder private func rowView(_ r: DropdownRow) -> some View {
        if r.isSeparator {
            Divider().overlay(Theme.strokeDivider)
                .padding(.horizontal, 6)
                .frame(height: DropdownMetric.separatorHeight)
        } else {
            let isHov = (hovered == r.id || presenter.keyFocusID == r.id) && !r.isDisabled
            HStack(spacing: 8) {
                if let icon = r.icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(r.isDisabled ? Theme.textFaint : Theme.textSecondary)
                        .frame(width: 16)
                }
                Text(r.label)
                    .font(.system(size: 12, weight: r.isSelected ? .semibold : .regular))
                    .foregroundColor(r.isDisabled ? Theme.textFaint
                                     : (r.isSelected ? Theme.accentBlue : Theme.textPrimary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if r.isSelected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.accentBlue)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: DropdownMetric.itemHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(isHov ? Theme.bgSelected : Color.clear))
            .contentShape(Rectangle())
            .onHover { inside in if !r.isDisabled { hovered = inside ? r.id : (hovered == r.id ? nil : hovered) } }
            .onTapGesture { if !r.isDisabled { r.action(); presenter.close() } }
            .id(r.id)
        }
    }
}
