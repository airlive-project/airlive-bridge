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

    /// ONE installer, and at most one activation request, per app session — the same
    /// placement OBS uses (its output handler's constructor). Every request that finds a
    /// different staged build triggers a replacement, and a replacement is what can leave the
    /// machine without a camera (see VirtualCameraOutput.Stage.cameraProcessMissing). Asking
    /// repeatedly — a profile opened, a card removed and undone — was rolling those dice again
    /// for nothing.
    static let shared = SystemExtensionInstaller()

    private var outcome: Outcome?
    private var waiting: [(Outcome) -> Void] = []
    private var submitted = false

    /// Submit once; everyone else is told what happened, whenever it happened.
    func activateOnce(_ completion: @escaping (Outcome) -> Void) {
        if let outcome { completion(outcome); return }
        waiting.append(completion)
        guard !submitted else { return }
        submitted = true
        activate { [weak self] result in
            guard let self else { return }
            self.outcome = result
            let pending = self.waiting
            self.waiting = []
            pending.forEach { $0(result) }
        }
    }

    enum Outcome {
        case installed
        case needsApproval
        case notInApplications
        /// macOS accepted the request and finishes it at the next restart.  It means two
        /// different things depending on which request was made — staged but not yet loaded,
        /// or unstaged but still listed — so the WORDING belongs to the caller, not here.
        /// It used to be folded into `.failed("Restart the Mac to finish INSTALLING…")`,
        /// which is the one sentence that is always wrong when the operator asked to remove.
        case afterRestart
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
        // Forget that we ever activated.  `activateOnce` answers from memory, so without this
        // a Virtual Camera output added after a removal would be told "already installed" and
        // never submit a request — the camera would stay gone until the app was relaunched.
        outcome = nil
        submitted = false
        self.completion = completion
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: bundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    /// Always replace, as every shipping camera extension does.
    ///
    /// This is not reached for an unchanged build: the system decides `alreadyActive` and
    /// never asks. It is reached only once the system has already resolved to replace — so a
    /// "cancel if the versions match" branch here is unreachable, and dangerous if it ever
    /// stopped being: it would leave a NEW binary unstaged while the app reported success.
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
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
            completion?(.afterRestart)
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
