// TopBarLayout.swift - the multiview top bar's layout: CUT pinned to the PVW/PGM seam, AUTO on its
// right, and a side cluster that runs out of room moving down a row instead of under that pair.
//
// CUT's place is set by the picture, not by its neighbours: it sits on the seam between PREVIEW and
// PROGRAM whatever is on either side. The bar used to get that from a ZStack, which centres
// perfectly and keeps nothing apart - the side clusters were drawn UNDER the centre layer, so at the
// default window width AUTO covered Full-Screen, and a camera with five or six lenses slid its row
// under CUT (that half predates AUTO). Stacks can centre or avoid, not both at once. A Layout can:
// measure everything, put the pair on the centre line, and move the side clusters down a row when
// they would come closer than `clearance` to the pair.
//
// WHEN it wraps is decided by the window buttons alone, and that is the point. Their width never
// changes, so the bar's shape depends on the window and nothing else. Deciding by the lens row
// instead would reflow the bar every time the operator staged a camera with a different number of
// lenses - the lens buttons hopping between rows, the whole multiview jumping under the cursor,
// mid-show. So once the bar is two rows, the lens row always lives on the second one.

import SwiftUI

/// Which job a child of the bar does. Named rather than positional, so the call site says what each
/// view is and reordering the children cannot quietly swap two of them.
enum TopBarRole { case leading, cut, auto, trailing }

extension View {
    func topBarRole(_ role: TopBarRole) -> some View { layoutValue(key: TopBarRoleKey.self, value: role) }
}

private struct TopBarRoleKey: LayoutValueKey {
    static let defaultValue: TopBarRole? = nil
}

struct TopBarLayout: Layout {
    /// Between CUT and AUTO.
    var pairSpacing: CGFloat = Spacing.xs
    /// The least air between two clusters sharing a row - the same minimum the bar always kept.
    var clearance: CGFloat = Spacing.sm
    /// Between rows, once the bar has wrapped.
    var rowSpacing: CGFloat = Spacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for slot in arrange(subviews, width: bounds.width).slots {
            slot.view.place(at: CGPoint(x: bounds.minX + slot.frame.minX, y: bounds.minY + slot.frame.minY),
                            proposal: ProposedViewSize(slot.frame.size))
        }
    }

    private struct Slot {
        let view: LayoutSubview
        var frame: CGRect
        let row: Int
    }

    /// Every child's frame for a bar `width` wide. No usable width (an ideal-size query) means the
    /// narrowest bar that still holds everything on one row.
    private func arrange(_ subviews: Subviews, width proposed: CGFloat?) -> (size: CGSize, slots: [Slot]) {
        func child(_ role: TopBarRole) -> (view: LayoutSubview, size: CGSize)? {
            subviews.first { $0[TopBarRoleKey.self] == role }.map { ($0, $0.sizeThatFits(.unspecified)) }
        }
        let cut = child(.cut), auto = child(.auto), leading = child(.leading), trailing = child(.trailing)

        // How far the pair reaches either side of the centre line: CUT straddles it, AUTO hangs off
        // its right.
        let cutHalf = (cut?.size.width ?? 0) / 2
        let reachRight = cutHalf + (auto.map { pairSpacing + $0.size.width } ?? 0)
        let leadWidth = leading?.size.width ?? 0
        let trailWidth = trailing?.size.width ?? 0

        let oneRow = 2 * max(leadWidth + clearance + cutHalf, reachRight + clearance + trailWidth)
        let width: CGFloat
        if let proposed, proposed.isFinite { width = proposed } else { width = oneRow }
        let mid = width / 2

        // Row 0 belongs to the pair. The window buttons decide the shape (see the header): while
        // they fit beside the pair the bar is one row, and the lens row joins it if it has room.
        // Once they do not, both side clusters share row 1 - and only the narrowest window with the
        // longest lens row pushes the buttons on to a row 2 of their own.
        let leadRow: Int, trailRow: Int
        if mid + reachRight + clearance <= width - trailWidth {
            trailRow = 0
            leadRow = leadWidth + clearance <= mid - cutHalf ? 0 : 1
        } else {
            leadRow = 1
            trailRow = leadWidth + clearance + trailWidth <= width ? 1 : 2
        }

        var slots: [Slot] = []
        func add(_ c: (view: LayoutSubview, size: CGSize)?, x: CGFloat, row: Int) {
            guard let c else { return }
            slots.append(Slot(view: c.view, frame: CGRect(origin: CGPoint(x: x, y: 0), size: c.size), row: row))
        }
        add(cut, x: mid - cutHalf, row: 0)
        add(auto, x: mid + cutHalf + pairSpacing, row: 0)
        add(leading, x: 0, row: leadRow)
        add(trailing, x: width - trailWidth, row: trailRow)
        let height = stackRows(&slots)
        return (CGSize(width: width, height: height), slots)
    }

    /// Rows stack top-down, each as tall as its tallest child, with a child centred in its row.
    /// Sets every slot's y and returns the bar's height.
    private func stackRows(_ slots: inout [Slot]) -> CGFloat {
        let rows = (slots.map(\.row).max() ?? -1) + 1
        var rowHeight = [CGFloat](repeating: 0, count: rows)
        for slot in slots { rowHeight[slot.row] = max(rowHeight[slot.row], slot.frame.height) }
        var rowTop = [CGFloat](repeating: 0, count: rows)
        var bottom: CGFloat = 0
        for row in 0..<rows where rowHeight[row] > 0 {
            rowTop[row] = bottom > 0 ? bottom + rowSpacing : 0
            bottom = rowTop[row] + rowHeight[row]
        }
        for i in slots.indices {
            let row = slots[i].row
            slots[i].frame.origin.y = rowTop[row] + (rowHeight[row] - slots[i].frame.height) / 2
        }
        return bottom
    }
}
