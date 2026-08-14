import Foundation
import Testing
import PluginKitCore
import PluginKitHost
import PluginKitSDK
import PluginKitTesting

@Suite("Plugin author harness")
struct HarnessTests {

    @Test("A plugin can be driven end to end without a host app")
    func activateAndInvoke() async throws {
        let harness = PluginHarness(manifest: Fixture.wordCount())
        await harness.grant(FileReading.self) { scope, _ in
            FileReading(grantedRoots: scope.roots) { _ in "one two three" }
        }

        try await harness.activate(WordCountPlugin())
        let result = try await harness.invoke(
            CommandPoint.self, name: "count", RunCommand(text: "alpha beta gamma delta")
        )

        #expect(result.wordCount == 4)
        #expect(result.note?.contains("/tmp") == true)
    }

    @Test("Denying an optional capability degrades the plugin rather than failing it")
    func optionalDenialDegrades() async throws {
        let harness = PluginHarness(manifest: Fixture.wordCount())
        await harness.deny("fs.read")

        try await harness.activate(WordCountPlugin())
        let result = try await harness.invoke(
            CommandPoint.self, name: "count", RunCommand(text: "a b")
        )

        #expect(result.wordCount == 2)
        #expect(result.note == "no file access")
    }

    @Test("Denying a required capability fails activation")
    func requiredDenialFails() async {
        let manifest = Fixture.minimal(
            id: "com.example.strict",
            name: "strict",
            capabilities: [
                CapabilityRequest(
                    id: "fs.read",
                    scope: ["roots": ["/tmp"]],
                    required: true,
                    reason: "Cannot work without file access."
                )
            ]
        )
        let harness = PluginHarness(manifest: manifest)
        await harness.deny("fs.read")

        await #expect(throws: (any Error).self) {
            try await harness.activate(StrictPlugin())
        }
    }

    @Test("A narrowed scope is visible to the plugin, not discovered as failures")
    func attenuationVisibleToPlugin() async throws {
        let harness = PluginHarness(manifest: Fixture.wordCount())
        await harness.limit("fs.read", to: ["roots": ["/tmp"]])
        await harness.grant(FileReading.self) { scope, _ in
            FileReading(grantedRoots: scope.roots) { _ in "" }
        }

        try await harness.activate(WordCountPlugin())
        let result = try await harness.invoke(
            CommandPoint.self, name: "count", RunCommand(text: "a")
        )

        // The manifest asked for /tmp and /etc; only /tmp survived.
        #expect(result.note == "roots: /tmp")
    }

    @Test("The serializing transport agrees with direct for a sound contract")
    func serializingMatchesDirectWhenSound() async throws {
        for transport in PluginHarness.Transport.allCases {
            let harness = PluginHarness(manifest: Fixture.wordCount(), transport: transport)
            await harness.deny("fs.read")
            try await harness.activate(WordCountPlugin())

            let result = try await harness.invoke(
                CommandPoint.self, name: "count", RunCommand(text: "one two three")
            )
            #expect(result.wordCount == 3, "transport: \(transport)")
        }
    }

    @Test("The serializing transport catches a response that does not survive encoding")
    func serializingCatchesLossyContract() async throws {
        let manifest = Fixture.minimal(
            id: "com.example.lossy",
            name: "lossy",
            point: LossyPoint.extensionPointID,
            contractVersion: LossyPoint.contractVersion,
            metadata: .object([:])
        )

        let direct = PluginHarness(manifest: manifest, transport: .direct)
        try await direct.activate(LossyPlugin())
        let inProcess = try await direct.invoke(
            LossyPoint.self, name: "lossy", RunCommand(text: "abc")
        )
        // In-process, nothing is wrong: the note is right there in memory.
        #expect(inProcess.note != nil)

        let serializing = PluginHarness(manifest: manifest, transport: .serializing)
        try await serializing.activate(LossyPlugin())
        let overWire = try await serializing.invoke(
            LossyPoint.self, name: "lossy", RunCommand(text: "abc")
        )

        // Over a boundary the field vanishes. This is the whole reason the mode
        // exists: the bug is invisible until the day the plugin moves to XPC.
        #expect(overWire.note == nil)
        #expect(overWire.count == inProcess.count)
    }

    @Test("Drift reports a contribution declared but never registered")
    func driftDetectsUnregistered() async throws {
        var manifest = Fixture.wordCount()
        manifest.contributions.append(
            Contribution(
                extensionPoint: CommandPoint.extensionPointID,
                name: "ghost",
                contractVersion: CommandPoint.contractVersion,
                metadata: ["title": "Ghost"]
            )
        )

        let harness = PluginHarness(manifest: manifest)
        await harness.deny("fs.read")
        try await harness.activate(WordCountPlugin())

        let drift = await harness.drift()
        #expect(drift.contains(
            .declaredButNotRegistered(point: CommandPoint.extensionPointID, name: "ghost")
        ))
        // Not fatal: a declared-but-absent contribution is dead weight, not a refusal.
        #expect(drift.allSatisfy { !$0.isFatal })
    }

    @Test("Drift reports a capability declared and never used")
    func driftDetectsUnusedCapability() async throws {
        var manifest = Fixture.minimal(id: "com.example.tidy", name: "count")
        manifest.capabilities = [
            CapabilityRequest(id: "net.http", required: false, reason: "Fetches updates.")
        ]

        let harness = PluginHarness(manifest: manifest)
        await harness.grant(NetworkAccess.self, NetworkAccess())
        try await harness.activate(BareCountPlugin())

        // Harmless in itself, but it inflates the permission list a user is asked to
        // approve, which makes every other line in it mean less.
        #expect(await harness.drift().contains(.capabilityDeclaredButUnused("net.http")))
    }

    @Test("A sound plugin has no drift at all")
    func soundPluginHasNoDrift() async throws {
        let harness = PluginHarness(manifest: Fixture.wordCount())
        await harness.grant(FileReading.self) { scope, _ in
            FileReading(grantedRoots: scope.roots) { _ in "" }
        }
        try await harness.activate(WordCountPlugin())

        #expect(await harness.drift().isEmpty)
    }

    @Test("The conformance suite passes the reference plugin")
    func conformancePasses() async {
        let findings = await PluginConformance(
            manifest: Fixture.wordCount(),
            makePlugin: { WordCountPlugin() }
        )
        .granting { harness in
            await harness.grant(FileReading.self) { scope, _ in
                FileReading(grantedRoots: scope.roots) { _ in "" }
            }
        }
        .run()

        #expect(findings.isEmpty, "\(findings)")
    }

    @Test("The conformance suite catches a plugin that ignores its own required flag")
    func conformanceCatchesMislabelledRequirement() async {
        // The manifest says required, but the plugin degrades instead of throwing.
        // Either the flag is wrong or a failure is being deferred to somewhere with
        // no context attached — both worth catching before shipping.
        var manifest = Fixture.wordCount()
        manifest.capabilities = [
            CapabilityRequest(
                id: "fs.read",
                scope: ["roots": ["/tmp"]],
                required: true,
                reason: "Reads the open file."
            )
        ]

        let findings = await PluginConformance(
            manifest: manifest,
            makePlugin: { WordCountPlugin() }
        )
        .granting { harness in
            await harness.grant(FileReading.self) { scope, _ in
                FileReading(grantedRoots: scope.roots) { _ in "" }
            }
        }
        .run()

        #expect(findings.contains { $0.check == "required-capability-denied" }, "\(findings)")
    }

    @Test("The conformance suite catches an undeclared registration")
    func conformanceCatchesUndeclaredRegistration() async {
        let findings = await PluginConformance(
            manifest: Fixture.minimal(id: "com.example.sneaky", name: "count"),
            makePlugin: { SneakyPlugin() }
        ).run()

        #expect(!findings.isEmpty)
    }

    @Test("The harness records what a plugin logged and published")
    func harnessObservesSideEffects() async throws {
        let manifest = Fixture.minimal(id: "com.example.publisher", name: "publish")
        let harness = PluginHarness(manifest: manifest)
        try await harness.activate(PublisherPlugin())

        let saved = await harness.published(DocumentSaved.self)
        #expect(saved.map(\.path) == ["/tmp/a.md"])
    }

    @Test("Deactivation is counted, so idempotence can be asserted")
    func deactivationIsIdempotent() async throws {
        let manifest = Fixture.wordCount()
        let plugin = WordCountPlugin()
        let harness = PluginHarness(manifest: manifest)
        await harness.deny("fs.read")
        try await harness.activate(plugin)

        await harness.deactivate()
        await harness.deactivate()

        #expect(await harness.timesDeactivated == 2)
        #expect(await plugin.deactivations == 2)
    }
}

/// Registers one contribution and asks for nothing, for the unused-capability case.
actor BareCountPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        try await context.register(CommandPoint.self, name: "count") {
            CountCommand(files: nil)
        }
    }

    func deactivate() async {}
}
