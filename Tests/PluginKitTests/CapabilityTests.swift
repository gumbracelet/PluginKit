import Foundation
import Testing
import PluginKitCore
import PluginKitHost
import PluginKitTesting

@Suite("Capability brokering")
struct CapabilityTests {

    private func broker(
        policy: CapabilityPolicy,
        consent: any ConsentStore = AllowingConsentStore(),
        files: [String: String] = [:]
    ) -> PolicyCapabilityBroker {
        PolicyCapabilityBroker(
            registry: Fixture.capabilities(files: files),
            policy: policy,
            consent: consent
        )
    }

    private var identity: PluginIdentity {
        PluginIdentity(id: "com.example.wordcount", version: "1.0.0", displayName: "Word Count")
    }

    @Test("An allowed request produces a working handle")
    func allowedRequestGrants() async throws {
        let decision = await broker(policy: .allowAll, files: ["/tmp/a.md": "one two three"])
            .vend(
                CapabilityRequest(
                    id: "fs.read", scope: ["roots": ["/tmp"]], reason: "Reads the document."
                ),
                to: identity,
                trust: .firstParty
            )

        let capability = try #require(decision.capability as? FileReading)
        #expect(capability.grantedRoots == ["/tmp"])
        #expect(try await capability.contents(of: "/tmp/a.md") == "one two three")
    }

    @Test("Policy narrows a scope and the plugin is told it was narrowed")
    func attenuationIsReported() async throws {
        // A plugin asks for /tmp and /etc; policy permits only /tmp.
        let decision = await broker(
            policy: CapabilityPolicy(byCapability: ["fs.read": .allow(limit: ["roots": ["/tmp"]])])
        ).vend(
            CapabilityRequest(
                id: "fs.read",
                scope: ["roots": ["/tmp", "/etc"]],
                reason: "Reads documents."
            ),
            to: identity,
            trust: .firstParty
        )

        guard case .attenuated(let capability, let requested, let granted) = decision else {
            Issue.record("Expected an attenuated grant, got \(decision).")
            return
        }
        #expect((capability as? FileReading)?.grantedRoots == ["/tmp"])
        #expect(requested["roots"] == .array([.string("/tmp"), .string("/etc")]))
        #expect(granted["roots"] == .array([.string("/tmp")]))
    }

    @Test("Attenuation that leaves nothing is a denial, not an empty grant")
    func emptyAttenuationDenies() async {
        let decision = await broker(
            policy: CapabilityPolicy(byCapability: ["fs.read": .allow(limit: ["roots": ["/var"]])])
        ).vend(
            CapabilityRequest(id: "fs.read", scope: ["roots": ["/tmp"]], reason: "Reads."),
            to: identity,
            trust: .firstParty
        )

        // A capability that fails on every call would be worse than an honest refusal.
        guard case .denied(.scopeEmpty) = decision else {
            Issue.record("Expected scopeEmpty, got \(decision).")
            return
        }
    }

    @Test("A capability the host never registered is unavailable, not denied")
    func unregisteredIsUnavailable() async {
        let decision = await broker(policy: .allowAll).vend(
            CapabilityRequest(id: "contacts.read", reason: "Needs contacts."),
            to: identity,
            trust: .firstParty
        )
        guard case .denied(.unavailable) = decision else {
            Issue.record("Expected unavailable, got \(decision).")
            return
        }
    }

    @Test("Managed policy cannot be overridden by a per-plugin allowance")
    func managedPolicyWins() async {
        // The property that makes a fleet deployment enforceable rather than advisory.
        let policy = CapabilityPolicy(
            managed: ["fs.read": .deny(reason: "Blocked by your administrator.")],
            byPlugin: ["com.example.wordcount": ["fs.read": .allow]],
            byCapability: ["fs.read": .allow],
            fallback: .allow
        )
        let decision = await broker(policy: policy).vend(
            CapabilityRequest(id: "fs.read", reason: "Reads."),
            to: identity,
            trust: .firstParty
        )

        guard case .denied(.deniedByManagedPolicy(_, let reason)) = decision else {
            Issue.record("Expected deniedByManagedPolicy, got \(decision).")
            return
        }
        #expect(reason == "Blocked by your administrator.")
    }

    @Test("Per-plugin policy outranks the per-capability default")
    func perPluginOverridesPerCapability() async {
        let policy = CapabilityPolicy(
            byPlugin: ["com.example.wordcount": ["fs.read": .allow]],
            byCapability: ["fs.read": .deny(reason: "Off by default.")]
        )
        let decision = await broker(policy: policy).vend(
            CapabilityRequest(id: "fs.read", reason: "Reads."),
            to: identity,
            trust: .firstParty
        )
        #expect(decision.capability != nil)
    }

    @Test("Sensitivity-based policy prompts only for what warrants it")
    func sensitivityPolicy() async {
        let consent = InMemoryConsentStore(fallback: .denyOnce)
        let decision = await broker(policy: .promptForSensitive, consent: consent).vend(
            CapabilityRequest(id: "fs.read", reason: "Reads your documents."),
            to: identity,
            trust: .firstParty
        )

        guard case .denied(.deniedByUser) = decision else {
            Issue.record("Expected deniedByUser, got \(decision).")
            return
        }
        let prompts = await consent.prompts
        #expect(prompts.count == 1)
        // The prompt names the plugin and quotes its own reason, or the user cannot
        // tell who is asking or why.
        #expect(prompts[0].plugin.id == identity.id)
        #expect(prompts[0].reason == "Reads your documents.")
        #expect(prompts[0].sensitivity == .sensitive)
    }

    @Test("The user is asked about the narrowed scope, not the opening bid")
    func promptShowsNarrowedScope() async {
        let consent = InMemoryConsentStore(fallback: .allowAlways)
        _ = await broker(
            policy: CapabilityPolicy(
                byCapability: ["fs.read": .requireConsent(limit: ["roots": ["/tmp"]])]
            ),
            consent: consent
        ).vend(
            CapabilityRequest(
                id: "fs.read", scope: ["roots": ["/tmp", "/etc"]], reason: "Reads."
            ),
            to: identity,
            trust: .firstParty
        )

        let prompts = await consent.prompts
        #expect(prompts.first?.scope["roots"] == .array([.string("/tmp")]))
    }

    @Test("A remembered decision is honoured without asking again")
    func persistedConsentSkipsPrompt() async {
        let consent = InMemoryConsentStore(fallback: .denyOnce)
        await consent.seed(.allowAlways, for: identity.id, capability: "fs.read")

        let decision = await broker(policy: .promptForSensitive, consent: consent).vend(
            CapabilityRequest(id: "fs.read", reason: "Reads."),
            to: identity,
            trust: .firstParty
        )

        #expect(decision.capability != nil)
        #expect(await consent.prompts.isEmpty)
    }
}

@Suite("Manifest authority")
struct ManifestAuthorityTests {

    @Test("A capability the manifest never declared is refused before policy runs")
    func undeclaredCapabilityRefused() async throws {
        // `GreedyPlugin` asks for net.http in code without declaring it. The host
        // registers net.http and policy allows everything — so if the manifest were
        // merely advisory, this would succeed.
        let manifest = Fixture.minimal(id: "com.example.greedy", name: "greedy")
        let harness = PluginHarness(manifest: manifest)
        await harness.grant(NetworkAccess.self, NetworkAccess())

        await #expect(throws: CapabilityError.undeclared("net.http")) {
            try await harness.activate(GreedyPlugin())
        }
    }

    @Test("A contribution the manifest never declared is refused")
    func undeclaredContributionRefused() async {
        // `SneakyPlugin` registers "undeclared"; the manifest declares only "count".
        let manifest = Fixture.minimal(id: "com.example.sneaky", name: "count")
        let harness = PluginHarness(manifest: manifest)

        await #expect(throws: (any Error).self) {
            try await harness.activate(SneakyPlugin())
        }
    }

    @Test("Declaring a capability is necessary but not sufficient")
    func declaredStillSubjectToPolicy() async throws {
        let manifest = Fixture.wordCount()
        let harness = PluginHarness(manifest: manifest)
        await harness.grant(FileReading.self) { scope, _ in
            FileReading(grantedRoots: scope.roots) { _ in "" }
        }
        await harness.deny("fs.read", reason: "Not on this machine.")

        // Declared, registered, and still refused — the manifest is a disclosure,
        // not an entitlement.
        try await harness.activate(WordCountPlugin())
        let command = try await harness.contract(CommandPoint.self, name: "count")
        let result = try await CommandPoint.invoke(command, with: RunCommand(text: "a b"))
        #expect(result.note == "no file access")
    }
}
