import Foundation
import QingzhouKit

final class ClaudeSafetyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func policy(enabled: Bool = true) -> ClaudeApplicationPolicy {
        ClaudeApplicationPolicy(applications: [
            ClaudeSignedApplication(identifier: "fixture.claude", designatedRequirement: "identifier fixture.claude", owner: .protectedApplication),
            ClaudeSignedApplication(identifier: "fixture.proxy", designatedRequirement: "identifier fixture.proxy", owner: .dedicatedProxy)
        ], localProxyPort: 27891,
        upstream: ClaudeNetworkEndpoint(address: "203.0.113.10", port: 443, transport: .tcp), proxyAccessEnabled: enabled)
    }

    private func record() -> ClaudeSafetyOperationRecord {
        let previous = ClaudeSafetySession(state: AppState(), profileID: UUID(), wasConnected: true, nodeID: UUID())
        return ClaudeSafetyOperationRecord(operationID: UUID(), updatedAt: now, previous: previous,
            endpoint: policy().upstream, configurationVersion: ClaudeApplicationPolicy.currentVersion)
    }

    private func proof(_ record: ClaudeSafetyOperationRecord) -> ClaudeSafetyEvidence {
        ClaudeSafetyEvidence(operationID: record.operationID, configurationVersion: record.configurationVersion,
            verifiedAt: now, filterActive: true, applicationsCovered: true, descendantsCovered: true,
            crashBlockingVerified: true, existingConnectionsCovered: true, dnsProtected: true, ipv6Protected: true,
            proxyReachable: true, proxyEndpointOwned: true, fixedExitVerified: true)
    }

    func testProtectedApplicationsOnlyReachExactProxyEndpoints() throws {
        let policy = policy()
        try policy.validate()
        for address in ["127.0.0.1", "::1", "0:0:0:0:0:0:0:1"] {
            checkTrue(policy.permits(owner: .protectedApplication,
                destination: .init(address: address, port: 27891, transport: .tcp)))
        }
        for address in ["127.0.0.2", "localhost", "::ffff:127.0.0.1", "10.0.0.1", "192.168.1.1", "203.0.113.10", "2606:4700:4700::1111"] {
            checkFalse(policy.permits(owner: .protectedApplication,
                destination: .init(address: address, port: 27891, transport: .tcp)), address)
        }
        checkFalse(policy.permits(owner: .protectedApplication, destination: nil))
        for port: UInt16 in [0, 53, 27890, 443] {
            checkFalse(policy.permits(owner: .protectedApplication,
                destination: .init(address: "127.0.0.1", port: port, transport: .tcp)))
        }
        for transport in [ClaudeFlowTransport.udp, .unsupported] {
            checkFalse(policy.permits(owner: .protectedApplication,
                destination: .init(address: "127.0.0.1", port: 27891, transport: transport)))
        }
    }

    func testDedicatedProxyOnlyReachesPinnedTransport() {
        var policy = policy()
        checkTrue(policy.permits(owner: .dedicatedProxy, destination: policy.upstream))
        for endpoint in [ClaudeNetworkEndpoint(address: "203.0.113.11", port: 443, transport: .tcp),
                         .init(address: "203.0.113.10", port: 80, transport: .tcp),
                         .init(address: "203.0.113.10", port: 443, transport: .udp),
                         .init(address: "proxy.example", port: 443, transport: .tcp)] {
            checkFalse(policy.permits(owner: .dedicatedProxy, destination: endpoint))
        }
        checkFalse(policy.permits(owner: .dedicatedProxy, destination: nil))
        policy.upstream = .init(address: "2606:4700:4700::1111", port: 443, transport: .udp)
        checkTrue(policy.permits(owner: .dedicatedProxy,
            destination: .init(address: "2606:4700:4700:0:0:0:0:1111", port: 443, transport: .udp)))
        policy.proxyAccessEnabled = false
        checkFalse(policy.permits(owner: .dedicatedProxy, destination: policy.upstream))
    }

    func testDisablingAccessKeepsProtectedAppsBlockedAndOthersUnaffected() {
        let policy = policy(enabled: false)
        checkFalse(policy.permits(owner: .protectedApplication,
            destination: .init(address: "127.0.0.1", port: 27891, transport: .tcp)))
        checkTrue(policy.permits(owner: .unrelatedApplication, destination: nil))
        checkTrue(policy.permits(owner: .unrelatedApplication,
            destination: .init(address: "198.51.100.15", port: 443, transport: .tcp)))
        checkFalse(policy.permits(owner: .unresolved, destination: policy.upstream))
    }

    func testInvalidPoliciesNeverAllowTraffic() throws {
        var cases: [ClaudeApplicationPolicy] = []
        var value = policy()
        value.version += 1
        cases.append(value)
        value = policy(); value.localProxyPort = 0; cases.append(value)
        value = policy(); value.upstream.port = 0; cases.append(value)
        value = policy(); value.upstream.address = "10.0.0.1"; cases.append(value)
        value = policy(); value.upstream.transport = .unsupported; cases.append(value)
        value = policy(); value.applications = []; cases.append(value)
        value = policy(); value.applications.removeLast(); cases.append(value)
        value = policy(); value.applications.removeFirst(); cases.append(value)
        value = policy(); value.applications.append(value.applications[1]); cases.append(value)
        value = policy(); value.applications[0].identifier = ""; cases.append(value)
        value = policy(); value.applications[0].designatedRequirement = ""; cases.append(value)
        value = policy(); value.applications[0].owner = .unrelatedApplication; cases.append(value)
        value = policy(); value.applications[0].owner = .unresolved; cases.append(value)
        value = policy(); value.applications += (0..<129).map {
            .init(identifier: "fixture.\($0)", designatedRequirement: "identifier fixture.\($0)", owner: .protectedApplication)
        }; cases.append(value)
        for invalid in cases {
            checkThrows(try invalid.validate())
            for owner in [ClaudeFlowOwner.protectedApplication, .dedicatedProxy, .unrelatedApplication, .unresolved] {
                checkFalse(invalid.permits(owner: owner, destination: invalid.upstream))
            }
        }
        let restored = try JSONDecoder().decode(ClaudeApplicationPolicy.self, from: JSONEncoder().encode(policy()))
        try restored.validate()
    }

    func testEndpointMatchingRejectsNamesZeroPortsAndAddressFamilyAliases() {
        let endpoint = ClaudeNetworkEndpoint(address: "::1", port: 443, transport: .tcp)
        checkFalse(endpoint.matches(.init(address: "127.0.0.1", port: 443, transport: .tcp)))
        checkFalse(endpoint.matches(.init(address: "invalid", port: 443, transport: .tcp)))
        checkFalse(ClaudeNetworkEndpoint(address: "::1", port: 0, transport: .tcp).matches(endpoint))
        checkFalse(ClaudeNetworkEndpoint(address: "invalid", port: 443, transport: .tcp).matches(endpoint))
    }

    func testEveryBarrierFactMustBeFreshAndVerified() {
        let record = record()
        let keyPaths: [WritableKeyPath<ClaudeSafetyEvidence, Bool>] = [\.filterActive, \.applicationsCovered,
            \.descendantsCovered, \.crashBlockingVerified, \.existingConnectionsCovered, \.dnsProtected, \.ipv6Protected, \.proxyEndpointOwned]
        for keyPath in keyPaths {
            var evidence = proof(record)
            evidence[keyPath: keyPath] = false
            checkFalse(evidence.confirmsBarrier(now: now))
        }
        checkTrue(proof(record).confirmsBarrier(now: now))
        checkTrue(proof(record).confirmsBarrier(now: now.addingTimeInterval(14.999)))
        checkFalse(proof(record).confirmsBarrier(now: now.addingTimeInterval(15)))
        checkFalse(proof(record).confirmsBarrier(now: now.addingTimeInterval(-0.001)))
    }

    func testOldOperationCannotOverrideCurrentEvidenceAndRepeatedEnableIsRejected() throws {
        var machine = try ClaudeSafetyStateMachine()
        checkEqual(machine.phase, .off)
        let record = record()
        try machine.beginEnable(record)
        checkEqual(machine.phase, .enabling)
        checkThrows(try machine.beginEnable(record))
        checkThrows(try machine.beginDisable(now: now))
        machine.receive(proof(self.record()), now: now)
        checkEqual(machine.phase, .enabling)
        var evidence = proof(record)
        evidence.configurationVersion += 1
        machine.receive(evidence, now: now)
        checkEqual(machine.phase, .enabling)
        machine.receive(proof(record), now: now)
        checkEqual(machine.phase, .protectedConnected)
        evidence = proof(record)
        evidence.verifiedAt = now.addingTimeInterval(-1)
        evidence.filterActive = false
        machine.receive(evidence, now: now)
        checkEqual(machine.phase, .protectedConnected)
        checkThrows(try machine.beginEnable(self.record()))
        machine.expire(now: now.addingTimeInterval(14))
        checkEqual(machine.phase, .protectedConnected)
        machine.expire(now: now.addingTimeInterval(15))
        checkEqual(machine.phase, .unconfirmed)
        checkNil(machine.evidence)
    }

    func testProxyFailureRequiresBarrierEvidenceToClaimBlocking() throws {
        let record = record()
        var machine = try ClaudeSafetyStateMachine()
        try machine.beginEnable(record)
        machine.fail("代理不可达", now: now)
        checkEqual(machine.phase, .unconfirmed)
        var evidence = proof(record)
        evidence.proxyReachable = false
        machine.receive(evidence, now: now)
        checkEqual(machine.phase, .proxyBlocked)
        machine.fail("代理不可达", now: now)
        checkEqual(machine.phase, .proxyBlocked)
        evidence = proof(record)
        evidence.fixedExitVerified = false
        machine.receive(evidence, now: now)
        checkEqual(machine.phase, .proxyBlocked)
        evidence.filterActive = false
        machine.receive(evidence, now: now)
        checkEqual(machine.phase, .unconfirmed)
    }

    func testDisableNeedsPersistentBlockAndRestorationAndPreservesOriginalSnapshot() throws {
        for block in [false, true] {
            for restored in [false, true] {
                let record = record()
                var machine = try ClaudeSafetyStateMachine(restoring: record)
                machine.finishDisable(blockVerified: true, settingsRestored: true, now: now)
                checkEqual(machine.phase, .unconfirmed)
                try machine.beginDisable(now: now)
                checkEqual(machine.phase, .disabling)
                machine.receive(proof(record), now: now)
                checkEqual(machine.phase, .disabling)
                checkThrows(try machine.beginDisable(now: now))
                machine.finishDisable(blockVerified: block, settingsRestored: restored, now: now)
                checkEqual(machine.phase, block && restored ? .disabledBlocked : .unconfirmed)
                checkNotNil(machine.record)
                checkNil(machine.evidence)
                if block && restored {
                    machine.receive(proof(record), now: now)
                    checkEqual(machine.phase, .disabledBlocked)
                    let next = self.record()
                    try machine.beginEnable(next)
                    checkEqual(machine.record?.previous.nodeID, record.previous.nodeID)
                    checkEqual(machine.record?.operationID, next.operationID)
                }
            }
        }
        var empty = try ClaudeSafetyStateMachine()
        checkThrows(try empty.beginDisable(now: now))
        empty.expire(now: now)
        checkEqual(empty.phase, .off)
        empty.receive(proof(record()), now: now)
        checkEqual(empty.phase, .off)
    }

    func testRestorationNeverRestoresLiveEvidence() throws {
        for phase in [ClaudeSafetyPhase.enabling, .verifying, .protectedConnected, .proxyBlocked, .unconfirmed, .disabling, .disabledBlocked, .off] {
            var record = record()
            record.phase = phase
            let machine = try ClaudeSafetyStateMachine(restoring: record)
            checkEqual(machine.phase, .unconfirmed)
            checkNil(machine.evidence)
        }
    }

    func testInvalidRecoveryRecordsAreRejected() throws {
        var invalid = record()
        invalid.version += 1
        checkThrows(try ClaudeSafetyStateMachine(restoring: invalid))
        var machine = try ClaudeSafetyStateMachine()
        checkThrows(try machine.beginEnable(invalid))
        invalid = record(); invalid.configurationVersion += 1
        checkThrows(try invalid.validate())
        invalid = record(); invalid.endpoint.address = "localhost"
        checkThrows(try invalid.validate())
        invalid = record(); invalid.endpoint.port = 0
        checkThrows(try invalid.validate())
        invalid = record(); invalid.endpoint.transport = .unsupported
        checkThrows(try invalid.validate())
    }

    func testRecoveryStoreUsesPrivatePermissionsAndRejectsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claude-filter-session.json")
        checkNil(try ClaudeSafetyOperationStore.load(from: url))
        let record = record()
        try ClaudeSafetyOperationStore.save(record, to: url)
        checkEqual(try ClaudeSafetyOperationStore.load(from: url)?.operationID, record.operationID)
        let content = try String(contentsOf: url, encoding: .utf8)
        checkFalse(content.contains("filterActive"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        checkThrows(try ClaudeSafetyOperationStore.load(from: url))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Data("{broken".utf8).write(to: url)
        checkThrows(try ClaudeSafetyOperationStore.load(from: url))
        try Data(repeating: 32, count: 65_537).write(to: url)
        checkThrows(try ClaudeSafetyOperationStore.load(from: url))
        var invalid = record
        invalid.version += 1
        checkThrows(try ClaudeSafetyOperationStore.save(invalid, to: url))
    }

    func testPreflightDoesNotTreatMissingOrAdHocBundlesAsReady() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/ClaudeSafetyFixture.app")
        let result = ClaudeNetworkFilterClient.inspect(bundleURL: missing)
        checkEqual(result.deploymentBlockers.count, 6)
        checkThrows(try ClaudeNetworkFilterClient.requireProductionReady(bundleURL: missing))
        let installed = ClaudeNetworkFilterClient.inspect(bundleURL: URL(fileURLWithPath: "/Applications/汐航.app"))
        checkThrows(try ClaudeNetworkFilterClient.requireProductionReady())
        checkFalse(ClaudeNetworkFilterClient.runtimeBlockers.isEmpty)
        if !installed.embeddedExtensionPresent { checkFalse(installed.extensionSignedBySameTeam) }
        var ready = result
        ready.developerIDSigned = true
        ready.embeddedExtensionPresent = true
        ready.extensionSignedBySameTeam = true
        ready.provisioningProfilesPresent = true
        ready.extensionEntitlementPresent = true
        ready.hostInstallEntitlementPresent = true
        checkTrue(ready.deploymentBlockers.isEmpty)
    }
}
