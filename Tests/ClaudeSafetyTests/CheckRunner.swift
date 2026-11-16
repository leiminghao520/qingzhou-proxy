import Foundation
import Darwin

// 仅依赖 Command Line Tools，避免要求用户安装完整 Xcode 才能执行离线策略测试。
private var assertions = 0
private var failures = 0

private func check(_ operation: () throws -> Bool, file: StaticString, line: UInt) {
    assertions += 1
    do {
        if try !operation() { failures += 1; print("FAIL \(file):\(line)") }
    } catch {
        failures += 1
        print("FAIL \(file):\(line) \(error)")
    }
}

func checkTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check(value, file: file, line: line)
}

func checkFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ try !value() }, file: file, line: line)
}

func checkEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    check({ try left() == right() }, file: file, line: line)
}

func checkNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    check({ try value() == nil }, file: file, line: line)
}

func checkNotNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    check({ try value() != nil }, file: file, line: line)
}

func checkThrows<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    check({
        do { _ = try operation(); return false }
        catch { return true }
    }, file: file, line: line)
}

@main struct ClaudeSafetyPolicyCheckRunner {
    static func main() {
        let tests = ClaudeSafetyTests()
        let cases: [(String, () throws -> Void)] = [
            ("protected-endpoints", tests.testProtectedApplicationsOnlyReachExactProxyEndpoints),
            ("fixed-upstream", tests.testDedicatedProxyOnlyReachesPinnedTransport),
            ("disable-and-coexistence", tests.testDisablingAccessKeepsProtectedAppsBlockedAndOthersUnaffected),
            ("invalid-policies", tests.testInvalidPoliciesNeverAllowTraffic),
            ("endpoint-normalization", tests.testEndpointMatchingRejectsNamesZeroPortsAndAddressFamilyAliases),
            ("barrier-evidence", tests.testEveryBarrierFactMustBeFreshAndVerified),
            ("operation-serialization", tests.testOldOperationCannotOverrideCurrentEvidenceAndRepeatedEnableIsRejected),
            ("proxy-failure", tests.testProxyFailureRequiresBarrierEvidenceToClaimBlocking),
            ("disable-preserves-block", tests.testDisableNeedsPersistentBlockAndRestorationAndPreservesOriginalSnapshot),
            ("restart-drops-evidence", tests.testRestorationNeverRestoresLiveEvidence),
            ("invalid-recovery", tests.testInvalidRecoveryRecordsAreRejected),
            ("private-storage", tests.testRecoveryStoreUsesPrivatePermissionsAndRejectsCorruption),
            ("deployment-preflight", tests.testPreflightDoesNotTreatMissingOrAdHocBundlesAsReady)
        ]
        for (name, run) in cases {
            let before = failures
            do { try run() }
            catch { failures += 1; print("FAIL \(name): \(error)") }
            print("\(before == failures ? "PASS" : "FAIL") \(name)")
        }
        print("RESULT claude_filter_scenarios=\(cases.count) assertions=\(assertions) failures=\(failures) kernelWrites=0")
        exit(failures == 0 ? 0 : 1)
    }
}
