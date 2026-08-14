import Foundation
import Testing
import PluginKitCore
import PluginKitHost
import PluginKitTesting

@Suite("Discovery, registry, and laziness")
struct RegistryTests {

    @Test("Listing contributions loads no plugin code at all")
    func listingIsLazy() async throws {
        let counter = InstantiationCounter()
        let manifest = Fixture.wordCount()
        let manager = Fixture.manager(
            plugins: [entry(manifest, counter.tracking(manifest.id) { WordCountPlugin() })]
        )

        await manager.start()

        let handles = await manager.contributions(to: CommandPoint.self)
        #expect(handles.count == 1)
        #expect(handles[0].metadata.title == "Count Words")
        // The whole point of the manifest: a host builds its menus from metadata and
        // pays for a plugin only when someone uses it.
        #expect(counter.total == 0)
        #expect(await manager.plugin(manifest.id)?.phase == .resolved)

        _ = try await handles[0].resolve()

        #expect(counter.count(for: manifest.id) == 1)
        #expect(await manager.plugin(manifest.id)?.phase == .active)
    }

    @Test("Resolving twice reuses the same contract instance")
    func resolutionIsMemoised() async throws {
        let counter = InstantiationCounter()
        let manifest = Fixture.wordCount()
        let manager = Fixture.manager(
            plugins: [entry(manifest, counter.tracking(manifest.id) { WordCountPlugin() })]
        )
        await manager.start()

        let handles = await manager.contributions(to: CommandPoint.self)
        let first = try await handles[0].resolve()
        let second = try await handles[0].resolve()

        // Memoisation is a semantic guarantee: a contract holding per-contribution
        // state must not be silently rebuilt on every menu click.
        #expect(counter.count(for: manifest.id) == 1)
        let a = try await CommandPoint.invoke(first, with: RunCommand(text: "one two"))
        let b = try await CommandPoint.invoke(second, with: RunCommand(text: "one two"))
        #expect(a == b)
    }

    @Test("Contributions come back in priority order, deterministically")
    func priorityOrdering() async {
        let low = Fixture.minimal(id: "com.example.low", name: "a", priority: 1)
        let high = Fixture.minimal(id: "com.example.high", name: "b", priority: 100)
        let mid = Fixture.minimal(id: "com.example.mid", name: "c", priority: 50)

        let manager = Fixture.manager(plugins: [
            entry(low) { WordCountPlugin() },
            entry(high) { WordCountPlugin() },
            entry(mid) { WordCountPlugin() },
        ])
        await manager.start()

        let handles = await manager.contributions(to: CommandPoint.self)
        #expect(handles.map { $0.contributor.id } == ["com.example.high", "com.example.mid", "com.example.low"])
    }

    @Test("A single-arity point yields at most one contribution")
    func singleArity() async {
        let first = Fixture.minimal(
            id: "com.example.one",
            name: "panel",
            point: InspectorPoint.extensionPointID,
            contractVersion: InspectorPoint.contractVersion,
            priority: 1,
            metadata: .object([:])
        )
        let second = Fixture.minimal(
            id: "com.example.two",
            name: "panel",
            point: InspectorPoint.extensionPointID,
            contractVersion: InspectorPoint.contractVersion,
            priority: 99,
            metadata: .object([:])
        )

        let manager = Fixture.manager(plugins: [
            entry(first) { InspectorPlugin() },
            entry(second) { InspectorPlugin() },
        ])
        await manager.start()

        let handles = await manager.contributions(to: InspectorPoint.self)
        #expect(handles.count == 1)
        #expect(handles[0].contributor.id == "com.example.two")
    }

    @Test("One plugin's bad metadata does not empty another plugin's menu")
    func badMetadataIsIsolated() async {
        // Metadata is validated at discovery, so the offender is already unsatisfied.
        // This asserts the *other* plugin is unaffected — the failure is contained.
        let broken = Fixture.minimal(
            id: "com.example.broken", name: "a", metadata: ["category": "Text"]
        )
        let good = Fixture.minimal(id: "com.example.good", name: "b", metadata: ["title": "Fine"])

        let manager = Fixture.manager(plugins: [
            entry(broken) { WordCountPlugin() },
            entry(good) { WordCountPlugin() },
        ])
        await manager.start()

        #expect(await manager.plugin("com.example.broken")?.phase == .unsatisfied)
        #expect(await manager.plugin("com.example.good")?.phase == .resolved)
        let handles = await manager.contributions(to: CommandPoint.self)
        #expect(handles.map { $0.contributor.id } == ["com.example.good"])
    }

    @Test("A blocked plugin is rejected with a readable reason and never loaded")
    func blockedPluginIsRejected() async {
        let counter = InstantiationCounter()
        let manifest = Fixture.wordCount()
        let manager = HostHarness.manager(
            plugins: [entry(manifest, counter.tracking(manifest.id) { WordCountPlugin() })]
        ) { configuration in
            configuration.extensionPoints = Fixture.catalog()
            configuration.capabilities = Fixture.capabilities()
            configuration.trustPolicy = BlockingTrustPolicy(reason: .unsigned)
        }
        await manager.start()

        let record = await manager.plugin(manifest.id)
        #expect(record?.phase == .rejected)
        #expect(record?.lastError?.contains("not code signed") == true)
        #expect(await manager.contributions(to: CommandPoint.self).isEmpty)
        #expect(counter.total == 0)
    }

    @Test("A local-only contribution makes a sandboxed-only plugin unsatisfied")
    func localityRefusesLowTrust() async {
        let manifest = Fixture.minimal(
            id: "com.example.inspector",
            name: "panel",
            point: InspectorPoint.extensionPointID,
            contractVersion: InspectorPoint.contractVersion,
            metadata: .object([:])
        )
        let manager = Fixture.manager(
            plugins: [entry(manifest) { InspectorPlugin() }],
            trust: .sandboxedOnly
        )
        await manager.start()

        let record = await manager.plugin(manifest.id)
        #expect(record?.phase == .unsatisfied)
        guard case .extensionPoint(.localityViolation)? = record?.unsatisfied else {
            Issue.record("Expected a locality violation, got \(String(describing: record?.unsatisfied))")
            return
        }
    }

    @Test("A sandboxed-only plugin is unsatisfied when no isolating runtime exists")
    func failsClosedWithoutIsolation() async {
        // The honest outcome for v0.1: rather than quietly granting full authority
        // to untrusted code, the plugin is listed with a reason.
        let manifest = Fixture.minimal(id: "com.example.third", name: "a")
        let manager = Fixture.manager(
            plugins: [entry(manifest) { WordCountPlugin() }],
            trust: .sandboxedOnly
        )
        await manager.start()

        let record = await manager.plugin(manifest.id)
        #expect(record?.phase == .unsatisfied)
        guard case .noRuntimeAvailable? = record?.unsatisfied else {
            Issue.record("Expected noRuntimeAvailable, got \(String(describing: record?.unsatisfied))")
            return
        }
        #expect(record?.unsatisfied?.description.contains("sandboxedOnly") == true)
    }

    @Test("A host can opt into unisolated hosting, and the plugin is flagged for it")
    func unisolatedFallbackIsWarned() async {
        let manifest = Fixture.minimal(id: "com.example.third", name: "a")
        let manager = HostHarness.manager(
            plugins: [entry(manifest) { WordCountPlugin() }],
            trust: .sandboxedOnly
        ) { configuration in
            configuration.extensionPoints = Fixture.catalog(includeInspector: false)
            configuration.capabilities = Fixture.capabilities()
            configuration.runtimeSelector = DefaultRuntimeSelector(
                minimumTrustForInProcess: .sandboxedOnly,
                allowsUnisolatedFallback: true
            )
        }
        await manager.start()

        let record = await manager.plugin(manifest.id)
        #expect(record?.phase == .resolved)
        #expect(record?.warnings.contains { $0.kind == PluginWarning.Kind.unisolated } == true)
        // The UI text must not imply containment that does not exist.
        #expect(record?.trustSummary.contains("sandboxed") == true)
    }

    @Test("A plugin built against an incompatible PluginKit is rejected up front")
    func incompatibleSDKRejected() async {
        var manifest = Fixture.minimal(id: "com.example.future", name: "a")
        manifest.sdkVersion = VersionRange(string: ">=99.0.0")!

        let manager = Fixture.manager(plugins: [entry(manifest) { WordCountPlugin() }])
        await manager.start()

        #expect(await manager.plugin(manifest.id)?.phase == .rejected)
    }

    @Test("A vocabulary mismatch reports the vocabulary, not a cascade of points")
    func vocabularyMismatchReportedOnce() async {
        var manifest = Fixture.minimal(id: "com.example.old", name: "a")
        manifest.contracts = [
            ContractDependency(
                vocabulary: CommandPoint.vocabulary,
                builtAgainst: "1.0.0",
                compatibleWith: VersionRange(string: ">=0.1.0 <1.0.0")!
            )
        ]

        let manager = Fixture.manager(
            plugins: [entry(manifest) { WordCountPlugin() }],
            vocabularies: [
                VocabularyDescriptor(id: CommandPoint.vocabulary, version: "1.2.0")
            ]
        )
        await manager.start()

        let record = await manager.plugin(manifest.id)
        guard case .vocabularyUnsupported(let id, _, let hostProvides)? = record?.unsatisfied else {
            Issue.record("Expected vocabularyUnsupported, got \(String(describing: record?.unsatisfied))")
            return
        }
        #expect(id == CommandPoint.vocabulary)
        #expect(hostProvides == SemanticVersion(1, 2, 0))
    }

    @Test("A required capability the host does not implement is a static refusal")
    func requiredCapabilityMissingFromHost() async {
        let manifest = Fixture.minimal(
            id: "com.example.needy",
            name: "a",
            capabilities: [
                CapabilityRequest(
                    id: ContactsAccess.capabilityID,
                    required: true,
                    reason: "Needs your contacts."
                )
            ]
        )
        let manager = Fixture.manager(plugins: [entry(manifest) { WordCountPlugin() }])
        await manager.start()

        // Checkable without prompting, so it is reported at discovery rather than
        // asking the user about a plugin that can never work.
        guard case .requiredCapabilityDenied(let id, _)? =
            await manager.plugin(manifest.id)?.unsatisfied
        else {
            Issue.record("Expected requiredCapabilityDenied.")
            return
        }
        #expect(id == ContactsAccess.capabilityID)
    }

    @Test("Safe mode discovers everything and loads nothing")
    func safeModeLoadsNothing() async {
        let counter = InstantiationCounter()
        let manifest = Fixture.wordCount(activation: .eager(reason: "Needed at launch."))
        let manager = Fixture.manager(
            plugins: [entry(manifest, counter.tracking(manifest.id) { WordCountPlugin() })],
            safeMode: true
        )
        await manager.start()

        #expect(await manager.plugins().count == 1)
        #expect(counter.total == 0)
        guard case .disabledByPolicy? = await manager.plugin(manifest.id)?.unsatisfied else {
            Issue.record("Expected disabledByPolicy in safe mode.")
            return
        }
    }

    @Test("Eager activation happens during start, unlike everything else")
    func eagerActivation() async {
        let counter = InstantiationCounter()
        let eager = Fixture.wordCount(
            id: "com.example.eager", activation: .eager(reason: "Registers a URL handler.")
        )
        let lazy = Fixture.wordCount(id: "com.example.lazy")

        let manager = Fixture.manager(plugins: [
            entry(eager, counter.tracking(eager.id) { WordCountPlugin() }),
            entry(lazy, counter.tracking(lazy.id) { WordCountPlugin() }),
        ])
        await manager.start()

        #expect(counter.count(for: eager.id) == 1)
        #expect(counter.count(for: lazy.id) == 0)
    }

    @Test("A missing required dependency is a visible steady state")
    func missingDependency() async {
        let manifest = Fixture.minimal(
            id: "com.example.dependent",
            name: "a",
            dependencies: [PluginDependency(id: "com.example.absent")]
        )
        let manager = Fixture.manager(plugins: [entry(manifest) { WordCountPlugin() }])
        await manager.start()

        guard case .missingDependency(let id)? = await manager.plugin(manifest.id)?.unsatisfied else {
            Issue.record("Expected missingDependency.")
            return
        }
        #expect(id == "com.example.absent")
    }

    @Test("A missing optional dependency degrades rather than blocking")
    func optionalDependencyMissing() async {
        let manifest = Fixture.minimal(
            id: "com.example.dependent",
            name: "a",
            dependencies: [PluginDependency(id: "com.example.absent", required: false)]
        )
        let manager = Fixture.manager(plugins: [entry(manifest) { WordCountPlugin() }])
        await manager.start()

        let record = await manager.plugin(manifest.id)
        #expect(record?.phase == .resolved)
        #expect(record?.warnings.contains { $0.kind == PluginWarning.Kind.optionalDependencyMissing } == true)
    }

    @Test("A dependency version mismatch names both versions")
    func dependencyVersionMismatch() async {
        let provider = Fixture.minimal(id: "com.example.provider", name: "p", version: "1.0.0")
        let consumer = Fixture.minimal(
            id: "com.example.consumer",
            name: "c",
            dependencies: [
                PluginDependency(id: "com.example.provider", versions: VersionRange(string: ">=2.0.0")!)
            ]
        )
        let manager = Fixture.manager(plugins: [
            entry(provider) { WordCountPlugin() },
            entry(consumer) { WordCountPlugin() },
        ])
        await manager.start()

        guard case .dependencyVersionMismatch(_, _, let found)? =
            await manager.plugin(consumer.id)?.unsatisfied
        else {
            Issue.record("Expected dependencyVersionMismatch.")
            return
        }
        #expect(found == SemanticVersion(1, 0, 0))
    }

    @Test("A dependency cycle is refused rather than ordered arbitrarily")
    func dependencyCycle() async {
        let a = Fixture.minimal(
            id: "com.example.a", name: "a",
            dependencies: [PluginDependency(id: "com.example.b")]
        )
        let b = Fixture.minimal(
            id: "com.example.b", name: "b",
            dependencies: [PluginDependency(id: "com.example.a")]
        )
        let manager = Fixture.manager(plugins: [
            entry(a) { WordCountPlugin() },
            entry(b) { WordCountPlugin() },
        ])
        await manager.start()

        // Choosing an order for a cycle means choosing which plugin sees a
        // half-initialised peer. There is no right answer, so both are refused.
        guard case .dependencyCycle? = await manager.plugin(a.id)?.unsatisfied else {
            Issue.record("Expected a dependency cycle for a.")
            return
        }
        guard case .dependencyCycle? = await manager.plugin(b.id)?.unsatisfied else {
            Issue.record("Expected a dependency cycle for b.")
            return
        }
    }

    @Test("Discovery records which copy of a shadowed plugin won")
    func shadowingIsRecorded() async {
        // Same identity from two sources. Precedence decides, and the loss is logged
        // rather than silent: a user-dropped plugin overriding a managed one is a
        // support incident waiting to happen.
        let manifest = Fixture.minimal(id: "com.example.dup", name: "a")
        var configuration = HostConfiguration.inMemory(appIdentifier: Fixture.host)
        configuration.extensionPoints = Fixture.catalog()
        configuration.capabilities = Fixture.capabilities()
        configuration.trustPolicy = FixedTrustPolicy(level: .firstParty)
        configuration.sources = [
            RegisteredPluginSource(sourceID: .machine, trustHint: .managed, manifests: [manifest]),
            RegisteredPluginSource(sourceID: .user, trustHint: .userInstalled, manifests: [manifest]),
        ]
        configuration.runtimes = [
            InProcessRuntimeStub(factories: [manifest.id: { @Sendable in WordCountPlugin() }])
        ]

        let manager = PluginManager(configuration: configuration)
        await manager.start()

        #expect(await manager.plugins().count == 1)
        #expect(await manager.plugin(manifest.id)?.source == .machine)
        let shadowed = await manager.diagnostics.events(of: .shadowed)
        #expect(shadowed.count == 1)
        #expect(shadowed[0].detail.contains("machine"))
    }
}

/// A runtime that hosts registered plugins, used where a test needs to build a
/// `HostConfiguration` by hand rather than through ``HostHarness``.
struct InProcessRuntimeStub: PluginRuntime {
    let runtimeID: RuntimeID = .inProcess
    let factories: [PluginID: @Sendable () -> any Plugin]

    func canHost(_ manifest: PluginManifest, at location: PluginLocation) -> Bool {
        factories[manifest.id] != nil
    }

    func load(
        _ plugin: ResolvedPlugin,
        context: any PluginContext
    ) async throws -> any PluginInstance {
        guard let factory = factories[plugin.manifest.id] else {
            throw PluginKitError.runtime(
                .instantiationFailed(plugin.manifest.id, reason: "No factory.")
            )
        }
        return StubInstance(identity: plugin.identity, plugin: factory(), context: context)
    }
}

struct StubInstance: PluginInstance {
    let identity: PluginIdentity
    let plugin: any Plugin
    let context: any PluginContext

    func activate() async throws { try await plugin.activate(context) }
    func deactivate() async { await plugin.deactivate() }

    func contract(for point: ExtensionPointID, contribution name: String) async throws -> any Sendable {
        guard let resolving = context as? any ContributionResolving else {
            throw PluginKitError.misconfigured(reason: "Not resolvable.")
        }
        return try await resolving.resolveContribution(point: point, name: name)
    }

    func service(_ id: ServiceID) async throws -> any Sendable {
        guard let resolving = context as? any ContributionResolving else {
            throw PluginKitError.misconfigured(reason: "Not resolvable.")
        }
        return try await resolving.resolveProvidedService(id)
    }
}
