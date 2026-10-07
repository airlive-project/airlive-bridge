// VirtualCameraRemoval.swift - the app menu's "Remove Virtual Camera…", the ONLY reliable way to
// take the virtual camera off a Mac (see the menu item in AirliveBridgeApp for why).

import AppKit

enum VirtualCameraRemoval {
    /// Unstage the camera extension.  Destructive and easy to hit by accident from a menu, so
    /// it asks first — and it says what actually happens afterwards, because macOS defers the
    /// removal to the next restart and the camera keeps being listed until then.
    static func confirmAndRemove() {
        let confirm = NSAlert()
        confirm.messageText = "Remove the virtual camera from this Mac?"
        confirm.informativeText = """
        “\(kVCamDeviceName)” disappears from every app that lists cameras. Add a Virtual \
        Camera output again to reinstall it - macOS will ask you to approve it once more.
        """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        SystemExtensionInstaller.shared.deactivate { outcome in
            let done = NSAlert()
            switch outcome {
            case .installed:
                done.messageText = "Virtual camera removed."
            case .afterRestart:
                done.messageText = "Virtual camera removed."
                done.informativeText = "macOS finishes removing it at the next restart; until then it may still appear in camera lists."
            case .needsApproval:
                done.messageText = "Confirm the removal in System Settings."
                done.informativeText = "macOS is asking you to approve it: System Settings ▸ General ▸ Login Items & Extensions."
            case .notInApplications:
                done.messageText = "Move Airlive Bridge to /Applications first."
                done.informativeText = "macOS only lets an app manage its camera extension from there."
            case .failed(let why):
                done.alertStyle = .warning
                done.messageText = "The virtual camera couldn't be removed."
                done.informativeText = why
            }
            done.runModal()
        }
    }
}
