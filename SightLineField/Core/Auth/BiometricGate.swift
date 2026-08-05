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
    private(set) var isUnlocked: Bool = false

    private let evaluator: BiometricEvaluator
    private let enabled: Bool

    /// - Parameter enabled: `false` disables the gate entirely (`requireUnlock()` unlocks
    ///   immediately without touching the evaluator) — set by UITest/`-uitest-reset` launches
    ///   so automated flows never block on a biometric prompt.
    init(evaluator: BiometricEvaluator = LABiometricEvaluator(), enabled: Bool = true) {
        self.evaluator = evaluator
        self.enabled = enabled
    }

    func requireUnlock() async {
        guard enabled, evaluator.isAvailable else {
            isUnlocked = true
            return
        }
        isUnlocked = await evaluator.evaluate(reason: "Unlock SightLine Field")
    }

    /// Called on `scenePhase`/resign-active transitions so the next foreground re-gates.
    func lock() {
        isUnlocked = false
    }
}
