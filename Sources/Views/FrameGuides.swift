// FrameGuides.swift - the frame guide the director sees over Preview and Program.
//
// Operators often compose for a frame narrower or wider than the 16:9 the Bridge outputs (2.39
// cinema bars set on the phones or in OBS, a 9:16 cut for vertical). The guide shows that frame on
// the Bridge's own Preview and Program panes - main window and the fullscreen wall - so the
// director sees what the audience will (operator, 2026-10-05/07).
//
// MONITORING ONLY. It is a view drawn over the panes; no output frame, recording or program buffer
// ever carries it. Sized from the pane, which is always the 16:9 program frame, so it scales with
// the pane and never jumps when the window is resized.

import SwiftUI

/// The frame being composed for. No 1.85: next to 16:9 (1.78) its bars are a few pixels, so it
/// only added a button (operator, 2026-10-07).
enum FrameGuide: String, CaseIterable, Identifiable {
    case off, scope239, scope235, classic43, square11, vertical916

    /// Where the applied choice is stored (UserDefaults).
    static let storageKey = "bridge.frameGuide"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:         return "Off"
        case .scope239:    return "2.39"
        case .scope235:    return "2.35"
        case .classic43:   return "4:3"
        case .square11:    return "1:1"
        case .vertical916: return "9:16"
        }
    }

    /// Width over height of the guide frame; nil = no guide.
    var aspect: CGFloat? {
        switch self {
        case .off:         return nil
        case .scope239:    return 2.39
        case .scope235:    return 2.35
        case .classic43:   return 4.0 / 3.0
        case .square11:    return 1
        case .vertical916: return 9.0 / 16.0
        }
    }
}

/// How the area outside the guide frame is drawn.
enum FrameGuideStyle: String, CaseIterable, Identifiable {
    case solid, dimmed, lines

    /// Where the applied choice is stored (UserDefaults).
    static let storageKey = "bridge.frameGuideStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid:  return "Black"
        case .dimmed: return "Dimmed"
        case .lines:  return "Lines"
        }
    }
}

/// A guide picked in Settings but not applied yet. The panes draw it so the operator sees the
/// choice at once; Apply makes it the stored one, Cancel / closing clears it (SettingsDraft).
final class FrameGuidePreview: ObservableObject {
    static let shared = FrameGuidePreview()
    @Published var guide: FrameGuide?
    @Published var style: FrameGuideStyle?
}

/// Drawn over a Preview / Program pane. Takes no clicks, so tap-to-focus underneath still works.
struct FrameGuideOverlay: View {
    @AppStorage(FrameGuide.storageKey) private var storedGuide: FrameGuide = .off
    @AppStorage(FrameGuideStyle.storageKey) private var storedStyle: FrameGuideStyle = .solid
    @ObservedObject private var preview = FrameGuidePreview.shared

    private var guide: FrameGuide { preview.guide ?? storedGuide }
    private var style: FrameGuideStyle { preview.style ?? storedStyle }

    /// The dimmed style's black: dark enough to read as outside the frame, light enough to still
    /// see what the camera has there.
    private static let dimmedOpacity = 0.6

    var body: some View {
        if let aspect = guide.aspect {
            GeometryReader { geo in
                let frame = Self.guideRect(aspect: aspect, in: geo.size)
                switch style {
                case .lines:
                    Rectangle()
                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                case .solid, .dimmed:
                    // Everything outside the guide frame, as one shape with a hole in it.
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size))
                        p.addRect(frame)
                    }
                    .fill(Color.black.opacity(style == .solid ? 1 : Self.dimmedOpacity),
                          style: FillStyle(eoFill: true))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The largest frame of `aspect` centred in `size`: bars top and bottom when it is wider than
    /// the pane, at the sides when it is narrower.
    static func guideRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        if aspect >= size.width / size.height {
            let h = size.width / aspect
            return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
        }
        let w = size.height * aspect
        return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
    }
}
