// SystemExtensionInstaller.swift — asks macOS to load the bundled camera extension.
//
// macOS, not us, owns this flow: the app submits a request, the OS validates the
// signature, and the FIRST time it asks the operator to approve the extension in
// System Settings.  Approval is remembered, so this is a one-time interruption; on
// every later launch the same request returns "already installed" immediately.
//
// Two refusals are configuration, not failure, and are reported as guidance:
//   • the app is not in /Applications — macOS refuses to load an extension from
//     anywhere else, by design;
//   • the operator has not approved it yet.

import Foundation
import SystemExtensions

final class SystemExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {

    enum Outcome {
        case installed
        case needsApproval
        case notInApplications
        case failed(String)
    }

    /// Overwritten by each request.  Only one activation is ever in flight in practice
    /// (the operator toggles one card), and a stale callback losing its turn is preferable
    /// to a queue of them firing at once.
    private var completion: ((Outcome) -> Void)?
    private let bundleID = "studio.airlive.bridge.AirliveBridge.vcam"

    /// Submit the activation request.  Safe to call on every start: macOS treats a
    /// repeat request for an already-active extension as a no-op.
    func activate(_ completion: @escaping (Outcome) -> Void) {
        self.completion = completion

        // Checked BEFORE submitting: the request would fail with an opaque code, and
        // "move the app" is far more useful than an error number.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            completion(.notInApplications)
            return
        }

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: bundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Ask macOS to unstage the extension.
    ///
    /// macOS keeps a camera extension in /Library/SystemExtensions, independent of the app
    /// bundle — deleting the app leaves the camera behind, still listed in every conferencing
    /// app, still launching on demand, with nothing left that could ever feed it.  Only this
    /// request removes it, and only the app that installed it may ask.
    func deactivate(_ completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: bundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    /// Replace ONLY when the staged extension is genuinely a different build.
    ///
    /// This used to answer `.replace` to everything, including "the identical version you
    /// already have". Every replace tears down the extension's process and relaunches it,
    /// which unpublishes the camera for a moment and, on macOS, defers the outgoing copy's
    /// removal until the next restart. Answering it to an unchanged extension meant an app
    /// that asked the operator to reboot and re-approve in exchange for nothing at all.
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        if existing.bundleVersion == ext.bundleVersion,
           existing.bundleShortVersion == ext.bundleShortVersion {
            return .cancel
        }
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        completion?(.needsApproval)
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            completion?(.installed)
        case .willCompleteAfterReboot:
            completion?(.failed("Restart the Mac to finish installing the virtual camera."))
        @unknown default:
            completion?(.installed)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        // Translate ONLY errors that really come from SystemExtensions: these code numbers
        // are meaningless in any other domain, and mapping them blindly produces a
        // confident, wrong diagnosis (an early build claimed the extension was missing
        // from the bundle when it was sitting right there).
        // Cancelling our own replacement of an identical build is the SUCCESS path above,
        // not a failure: the extension the app wants is already the one that is installed.
        if ns.domain == OSSystemExtensionErrorDomain,
           ns.code == OSSystemExtensionError.requestCanceled.rawValue {
            completion?(.installed)
            return
        }
        guard ns.domain == OSSystemExtensionErrorDomain else {
            completion?(.failed("Couldn't install the virtual camera: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"))
            return
        }
        let message: String
        switch OSSystemExtensionError.Code(rawValue: ns.code) {
        case .authorizationRequired:
            message = "Approve “\(kVCamDeviceName)” in System Settings → General → Login Items & Extensions."
        case .extensionNotFound:
            // Also what macOS reports for an extension it can see but refuses to LOAD —
            // notably a build signed for development rather than Developer ID.
            message = "macOS wouldn't load the virtual camera extension. Use a Developer ID-signed build of Airlive Bridge, installed in /Applications."
        case .validationFailed, .codeSignatureInvalid:
            message = "macOS rejected the extension's signature — reinstall Airlive Bridge from the official download."
        case .unsupportedParentBundleLocation:
            message = "Move Airlive Bridge to /Applications — macOS only loads a camera extension from there."
        case .missingEntitlement:
            message = "This build isn't signed with the system-extension entitlement — reinstall Airlive Bridge."
        default:
            message = "Couldn't install the virtual camera: \(ns.localizedDescription)"
        }
        completion?(.failed(message))
    }
}
