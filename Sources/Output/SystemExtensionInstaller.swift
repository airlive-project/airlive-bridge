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
import os

/// Every request and every answer from macOS, in the system log next to the camera's own lines
/// (`log show --predicate 'subsystem == "studio.airlive.vcam"'`): without it a field report
/// cannot tell "never approved" from "approved, never launched" from "refused".
private let installLog = Logger(subsystem: "studio.airlive.vcam", category: "install")

final class SystemExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {

    /// ONE installer, and at most one activation request, per app session — the same
    /// placement OBS uses (its output handler's constructor). Every request that finds a
    /// different staged build triggers a replacement, and a replacement is what can leave the
    /// machine without a camera (see VirtualCameraOutput.Stage.cameraProcessMissing). Asking
    /// repeatedly — a profile opened, a card removed and undone — was rolling those dice again
    /// for nothing.
    static let shared = SystemExtensionInstaller()

    /// A FINAL answer for this session - installed, or installed after a restart. Asked for
    /// again it is answered from here, never by a new request.
    private var settled: Outcome?
    /// "Waiting for approval": the request is still open and its final answer is still to come.
    private var interim: Outcome?
    private var waiting: [(Outcome) -> Void] = []
    private var inFlight = false

    /// Submit once; everyone waiting hears EVERY answer until the final one.
    ///
    /// On a Mac that never had the camera the first answer is "needs approval" and the real one,
    /// "installed", comes later, when the operator approves. Treating the first as final dropped
    /// the second: on exactly the first-install path, nothing ever reacted to the installation.
    /// A refusal is not kept either: switching the output on again asks again, rather than
    /// replaying a failure for the rest of the session.
    func activateOnce(_ completion: @escaping (Outcome) -> Void) {
        if let settled { completion(settled); return }
        waiting.append(completion)
        if let interim { completion(interim) }
        guard !inFlight else { return }
        inFlight = true
        activate { [weak self] result in self?.deliver(result) }
    }

    private func deliver(_ result: Outcome) {
        switch result {
        case .needsApproval:
            interim = result
            waiting.forEach { $0(result) }        // keep listening: the final answer follows
        case .installed, .afterRestart:
            settled = result
            finish(result)
        case .notInApplications, .failed:
            finish(result)                         // not kept: the next switch-on asks again
        }
    }

    private func finish(_ result: Outcome) {
        interim = nil
        inFlight = false
        let pending = waiting
        waiting = []
        pending.forEach { $0(result) }
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

    /// Who hears each request's answers, keyed by the request itself. An activation and a removal
    /// can both be open (the operator removes the camera while its approval is still pending), and
    /// a single shared slot sent one request's answer to the other's caller. Main thread only, like
    /// every delegate callback (requests are submitted with `queue: .main`).
    private var handlers: [ObjectIdentifier: (Outcome) -> Void] = [:]
    private let bundleID = "studio.airlive.bridge.AirliveBridge.vcam"

    /// Submit the activation request.  Safe to call on every start: macOS treats a
    /// repeat request for an already-active extension as a no-op.
    func activate(_ completion: @escaping (Outcome) -> Void) {
        // Checked BEFORE submitting: the request would fail with an opaque code, and
        // "move the app" is far more useful than an error number.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            installLog.error("not asking macOS: the app runs from \(Bundle.main.bundlePath, privacy: .public), not /Applications")
            completion(.notInApplications)
            return
        }

        installLog.notice("asking macOS to activate the camera extension")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: bundleID, queue: .main)
        request.delegate = self
        handlers[ObjectIdentifier(request)] = completion
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Answer `request`'s caller; `final` answers end the request (approval does not).
    private func answer(_ request: OSSystemExtensionRequest, _ outcome: Outcome, final: Bool) {
        let key = ObjectIdentifier(request)
        let handler = handlers[key]
        if final { handlers[key] = nil }
        handler?(outcome)
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
        // An activation still waiting for approval keeps its own listeners and answers.
        settled = nil
        installLog.notice("asking macOS to remove the camera extension")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: bundleID, queue: .main)
        request.delegate = self
        handlers[ObjectIdentifier(request)] = completion
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
        installLog.notice("replacing camera extension \(existing.bundleShortVersion, privacy: .public) (\(existing.bundleVersion, privacy: .public)) with \(ext.bundleShortVersion, privacy: .public) (\(ext.bundleVersion, privacy: .public))")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        installLog.notice("macOS needs the operator to approve the camera extension")
        answer(request, .needsApproval, final: false)
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            installLog.notice("camera extension request completed")
            answer(request, .installed, final: true)
        case .willCompleteAfterReboot:
            installLog.notice("camera extension request completes after a restart")
            answer(request, .afterRestart, final: true)
        @unknown default:
            installLog.notice("camera extension request finished with an unknown result \(result.rawValue)")
            answer(request, .installed, final: true)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        installLog.error("camera extension request failed: \(ns.domain, privacy: .public) \(ns.code) - \(ns.localizedDescription, privacy: .public)")
        // Translate ONLY errors that really come from SystemExtensions: these code numbers
        // are meaningless in any other domain, and mapping them blindly produces a
        // confident, wrong diagnosis (an early build claimed the extension was missing
        // from the bundle when it was sitting right there).
        guard ns.domain == OSSystemExtensionErrorDomain else {
            answer(request, .failed("Couldn't install the virtual camera: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"), final: true)
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
            message = "macOS rejected the extension's signature - reinstall Airlive Bridge from the official download."
        case .unsupportedParentBundleLocation:
            message = "Move Airlive Bridge to /Applications - macOS only loads a camera extension from there."
        case .missingEntitlement:
            message = "This build isn't signed with the system-extension entitlement - reinstall Airlive Bridge."
        default:
            message = "Couldn't install the virtual camera: \(ns.localizedDescription)"
        }
        answer(request, .failed(message), final: true)
    }
}
