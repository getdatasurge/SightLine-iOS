import XCTest
@testable import SightLineField

final class StubBiometricEvaluator: BiometricEvaluator, @unchecked Sendable {
    var isAvailable: Bool
    var evaluateResult: Bool
    private(set) var evaluateCallCount = 0
    private(set) var lastReason: String?

    init(isAvailable: Bool, evaluateResult: Bool) {
        self.isAvailable = isAvailable
        self.evaluateResult = evaluateResult
    }

    func evaluate(reason: String) async -> Bool {
        evaluateCallCount += 1
        lastReason = reason
        return evaluateResult
    }
}

@MainActor
final class BiometricGateTests: XCTestCase {
    func testAvailableAndSuccessUnlocks() async {
        let evaluator = StubBiometricEvaluator(isAvailable: true, evaluateResult: true)
        let gate = BiometricGate(evaluator: evaluator)
        await gate.requireUnlock()
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(evaluator.evaluateCallCount, 1)
    }

    func testAvailableAndFailureStaysLocked() async {
        let evaluator = StubBiometricEvaluator(isAvailable: true, evaluateResult: false)
        let gate = BiometricGate(evaluator: evaluator)
        await gate.requireUnlock()
        XCTAssertFalse(gate.isUnlocked)
        XCTAssertEqual(evaluator.evaluateCallCount, 1)
    }

    func testUnavailableUnlocksImmediatelyNonBlocking() async {
        let evaluator = StubBiometricEvaluator(isAvailable: false, evaluateResult: false)
        let gate = BiometricGate(evaluator: evaluator)
        await gate.requireUnlock()
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(evaluator.evaluateCallCount, 0, "evaluator must not be invoked when unavailable")
    }

    func testDisabledUnlocksImmediatelyWithoutEvaluator() async {
        let evaluator = StubBiometricEvaluator(isAvailable: true, evaluateResult: false)
        let gate = BiometricGate(evaluator: evaluator, enabled: false)
        await gate.requireUnlock()
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(evaluator.evaluateCallCount, 0, "evaluator must not be invoked when the gate is disabled")
    }

    func testLockReLocksAfterUnlock() async {
        let evaluator = StubBiometricEvaluator(isAvailable: true, evaluateResult: true)
        let gate = BiometricGate(evaluator: evaluator)
        await gate.requireUnlock()
        XCTAssertTrue(gate.isUnlocked)
        gate.lock()
        XCTAssertFalse(gate.isUnlocked)
    }
}
