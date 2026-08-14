import Foundation
import Testing
import PluginKitCore
import PluginKitHost
import PluginKitTesting

@Suite("Lifecycle")
struct LifecycleTests {

    @Test("An activation failure is contained and the other plugins keep working")
    func failureIsContained() async throws {
        let broken = Fixture.minimal(id: "com.example.broken", name: "a")
        let good = Fixture.wordCount(id: "com.example.good")

        let manager = Fixture.manager(plugins: [
            entry(broken) { BrokenPlugin() },
            entry(good) { WordCountPlugin() },
        ])
        await manager.start()

        let handles = await manager.contributions(to: CommandPoint.self)
        #expect(handles.count == 2)

        var failures = 0
        var successes = 0
        for handle in handles {
            do {
                _ = try await handle.resolve()
                successes += 1
            } catch {
                failures += 1
            }
        }
        #expect(failures == 1)
        #expect(successes == 1)
        #expect(await manager.plugin(broken.id)?.phase == .failed)
        #expect(await manager.plugin(good.id)?.phase == .active)
    }

    @Test("Repeated failures quarantine a plugin instead of retrying forever")
    func crashBudgetQuarantines() async {
        let manifest = Fixture.minimal(id: "com.example.broken", name: "a")
        let manager = Fixture.manager(
            plugins: [entry(manifest) { BrokenPlugin() }],
            crashBudget: CrashBudget(maximumFailures: 2, quarantines: true)
        )
        await manager.start()

        let handle = await manager.contributions(to: CommandPoint.self)[0]
        _ = try? await handle.resolve()
        #expect(await manager.plugin(manifest.id)?.phase == .failed)

        _ = try? await handle.resolve()

        // One plugin failing on every launch must not be able to make the app feel
        // permanently broken.
        let record = await manager.plugin(manifest.id)
        #expect(record?.phase == .quarantined)
        #expect(record?.failureCount == 2)

        // A quarantined plugin is not retried.
        await #expect(throws: (any Error).self) { _ = try await handle.resolve() }
    }

    @Test("Deactivation returns a plugin to inactive, and it can be resolved again")
    func deactivateThenReactivate() async throws {
        let counter = InstantiationCounter()
        let manifest = Fixture.wordCount()
        let manager = Fixture.manager(
            plugins: [entry(manifest, counter.tracking(manifest.id) { WordCountPlugin() })]
        )
        await manager.start()

        let handle = await manager.contributions(to: CommandPoint.self)[0]
        _ = try await handle.resolve()
        #expect(await manager.plugin(manifest.id)?.phase == .active)

        await manager.deactivate(manifest.id)
        #expect(await manager.plugin(manifest.id)?.phase == .inactive)

        _ = try await handle.resolve()
        #expect(await manager.plugin(manifest.id)?.phase == .active)
        // A fresh instance, because the registrar was reset — a re-activated plugin
        // must not inherit the previous run's resolved contracts.
        #expect(counter.count(for: manifest.id) == 2)
    }

    @Test("Disabling a plugin deactivates it and hides its contributions")
    func disableRemovesFromRegistry() async throws {
        let manifest = Fixture.wordCount()
        let manager = Fixture.manager(plugins: [entry(manifest) { WordCountPlugin() }])
        await manager.start()

        _ = try await manager.contributions(to: CommandPoint.self)[0].resolve()
        try await manager.setEnabled(manifest.id, false)

        #expect(await manager.contributions(to: CommandPoint.self).isEmpty)
        let record = await manager.plugin(manifest.id)
        #expect(record?.phase == .unsatisfied)
        #expect(record?.unsatisfied == .disabledByUser)

        try await manager.setEnabled(manifest.id, true)
        #expect(await manager.contributions(to: CommandPoint.self).count == 1)
    }

    @Test("A disabled plugin stays disabled across a restart")
    func disablementPersists() async throws {
        let manifest = Fixture.wordCount()
        let enablement = InMemoryEnablementStore()
        await enablement.setEnabled(manifest.id, false)

        let manager = HostHarness.manager(
            plugins: [entry(manifest) { WordCountPlugin() }]
        ) { configuration in
            configuration.extensionPoints = Fixture.catalog()
            configuration.capabilities = Fixture.capabilities()
            configuration.enablement = enablement
        }
        await manager.start()

        #expect(await manager.plugin(manifest.id)?.unsatisfied == .disabledByUser)
    }

    @Test("Concurrent resolutions activate the plugin exactly once")
    func concurrentActivationIsDeduplicated() async throws {
        let counter = InstantiationCounter()
        let manifest = Fixture.wordCount()
        let manager = Fixture.manager(
            plugins: [entry(manifest, counter.tracking(manifest.id) { WordCountPlugin() })]
        )
        await manager.start()

        let handle = await manager.contributions(to: CommandPoint.self)[0]
        // Two menu clicks in the same frame must not produce two activations.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try? await handle.resolve() }
            }
        }
        #expect(counter.count(for: manifest.id) == 1)
    }

    @Test("Shutdown deactivates everything that was loaded")
    func shutdownDeactivates() async throws {
        let manifest = Fixture.wordCount()
        let plugin = WordCountPlugin()
        let manager = Fixture.manager(plugins: [entry(manifest) { plugin }])
        await manager.start()

        _ = try await manager.contributions(to: CommandPoint.self)[0].resolve()
        await manager.shutdown()

        #expect(await plugin.deactivations == 1)
        #expect(await manager.plugin(manifest.id)?.phase == .inactive)
    }

    @Test("A plugin reports degraded health when an optional capability was denied")
    func degradedHealthIsVisible() async throws {
        let manifest = Fixture.wordCount()
        let plugin = WordCountPlugin()
        let manager = Fixture.manager(
            plugins: [entry(manifest) { plugin }],
            capabilityPolicy: CapabilityPolicy(
                byCapability: ["fs.read": .deny(reason: "Not permitted here.")],
                fallback: .allow
            )
        )
        await manager.start()

        _ = try await manager.contributions(to: CommandPoint.self)[0].resolve()

        // The user should learn about reduced behaviour from the UI, not by noticing
        // a missing feature.
        guard case .degraded = await plugin.healthCheck() else {
            Issue.record("Expected degraded health.")
            return
        }
    }

    @Test("Activation cost is measured, so a slow plugin is visible not suspected")
    func activationIsTimed() async throws {
        let manifest = Fixture.wordCount()
        let manager = Fixture.manager(plugins: [entry(manifest) { WordCountPlugin() }])
        await manager.start()

        _ = try await manager.contributions(to: CommandPoint.self)[0].resolve()

        #expect(await manager.plugin(manifest.id)?.activationDuration != nil)
        let costs = await manager.diagnostics.activationCosts()
        #expect(costs.contains { $0.plugin == manifest.id })
    }

    @Test("Diagnostics record every phase change with a reason")
    func diagnosticsAreRecorded() async throws {
        let good = Fixture.wordCount(id: "com.example.good")
        let broken = Fixture.minimal(id: "com.example.broken", name: "a")
        let manager = Fixture.manager(plugins: [
            entry(good) { WordCountPlugin() },
            entry(broken) { BrokenPlugin() },
        ])
        await manager.start()

        for handle in await manager.contributions(to: CommandPoint.self) {
            _ = try? await handle.resolve()
        }

        let diagnostics = await manager.diagnostics
        #expect(await diagnostics.count(of: .resolved) == 2)
        #expect(await diagnostics.count(of: .activated) == 1)
        #expect(await diagnostics.count(of: .failed) == 1)
        #expect(await diagnostics.events(for: broken.id).contains { $0.kind == .failed })
    }

    @Test("A wrong contract type names both types rather than trapping")
    func contractTypeMismatchIsDiagnostic() async throws {
        // The plugin registers a Command factory under a point whose contract is an
        // InspectorProviding. Only detectable at resolution, so the error has to carry
        // enough for an author who cannot see the host's stack.
        let manifest = Fixture.minimal(
            id: "com.example.confused",
            name: "panel",
            point: InspectorPoint.extensionPointID,
            contractVersion: InspectorPoint.contractVersion,
            metadata: .object([:])
        )
        let manager = Fixture.manager(plugins: [entry(manifest) { MismatchedPlugin() }])
        await manager.start()

        let handle = await manager.contributions(to: InspectorPoint.self)[0]
        do {
            _ = try await handle.resolve()
            Issue.record("Expected a contract type mismatch.")
        } catch let error as PluginKitError {
            guard case .extensionPoint(.contractTypeMismatch(_, let expected, let found)) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(expected.contains("InspectorProviding"))
            #expect(found.contains("CountCommand"))
        }
    }

    @Test("Manager events describe what happened, for a UI to observe")
    func managerEventsAreObservable() async throws {
        let manifest = Fixture.wordCount()
        let manager = Fixture.manager(plugins: [entry(manifest) { WordCountPlugin() }])

        let collected = EventCollector()
        let stream = await manager.events()
        let task = Task {
            for await event in stream { await collected.append(event) }
        }

        await manager.start()
        _ = try await manager.contributions(to: CommandPoint.self)[0].resolve()
        await manager.shutdown()
        task.cancel()

        let events = await collected.events
        #expect(events.contains { if case .finishedDiscovery = $0 { return true } else { return false } })
        #expect(events.contains { if case .phaseChanged(_, _, .active) = $0 { return true } else { return false } })
    }
}

/// Registers a `Command` factory under a point whose contract is not `Command`.
actor MismatchedPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        // Deliberately wrong: the point's contract is `any InspectorProviding`.
        try await context.register(WrongContractPoint.self, name: "panel") {
            CountCommand(files: nil)
        }
    }

    func deactivate() async {}
}

/// Shares `InspectorPoint`'s identifier but declares a different contract, which is
/// how the mismatch is provoked without writing an intentionally broken plugin API.
enum WrongContractPoint: LocalExtensionPoint {
    typealias Contract = any Command
    static let extensionPointID: ExtensionPointID = InspectorPoint.extensionPointID
    static let vocabulary: VocabularyID = InspectorPoint.vocabulary
    static let contractVersion: SemanticVersion = InspectorPoint.contractVersion
    static let localityReason = "Test double."
    static let arity: ExtensionPointArity = .single
}

actor EventCollector {
    var events: [PluginManagerEvent] = []
    func append(_ event: PluginManagerEvent) { events.append(event) }
}
