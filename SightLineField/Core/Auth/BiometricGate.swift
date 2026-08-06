import Foundation
import LocalAuthentication
import Observation

/// Seam over `LAContext` so `BiometricGate` can be exercised with a stub in tests —
/// the real evaluator is unavailable in any CI/simulator context without an enrolled
/// biometric, and `LAContext` itself is not mockable.
protocol BiometricEvaluator: Sendable {
    var isAvailable: Bool { get }
    func evaluate(reason: String) async -> Bool
}

/// Wraps `LAContext`, biometrics only (no passcode fallback) — a device without Face
/// ID/Touch ID enrolled, or one where the user declined biometric use, falls through
/// to `isAvailable == false` rather than prompting for a device passcode.
struct LABiometricEvaluator: BiometricEvaluator {
    func evaluate(reason: String) async -> Bool {
        let context = LAContext()
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
}

/// Gates a restored session behind Face ID/Touch ID on cold launch. Per spec this is
/// non-blocking on devices/simulators without biometrics enrolled — `requireUnlock()`
/// unlocks immediately rather than stranding the user with no way to authenticate.
@MainActor
@Observable
final class BiometricGate {
    private(set) var isUnlocked: Bool

    private let evaluator: BiometricEvaluator
    private let enabled: Bool

    /// True only when a real biometric prompt can actually run. Gated off (`-uitest-reset`) or
    /// no enrolled biometric (simulator / non-biometric device) means there is nothing to
    /// unlock, so the gate never engages and no lock overlay is ever shown.
    private var gateApplies: Bool { enabled && evaluator.isAvailable }

    /// - Parameter enabled: `false` disables the gate entirely — set by UITest/`-uitest-reset`
    ///   launches so automated flows never block on (or flash) a biometric prompt.
    init(evaluator: BiometricEvaluator = LABiometricEvaluator(), enabled: Bool = true) {
        self.evaluator = evaluator
        self.enabled = enabled
        // Start unlocked unless a real gate applies, so disabled and no-biometric contexts
        // never flash a lock overlay on `.signedIn`.
        self.isUnlocked = !(enabled && evaluator.isAvailable)
    }

    func requireUnlock() async {
        guard gateApplies else {
            isUnlocked = true
            return
        }
        isUnlocked = await evaluator.evaluate(reason: "Unlock SightLine Field")
    }

    /// Called on `scenePhase`/resign-active transitions so the next foreground re-gates. No-op
    /// when no gate applies, so a background→foreground cycle never flashes an overlay either.
    func lock() {
        guard gateApplies else { return }
        isUnlocked = false
    }
}
