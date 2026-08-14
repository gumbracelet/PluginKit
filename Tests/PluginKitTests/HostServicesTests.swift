import Foundation
import Testing
import PluginKitCore
@testable import PluginKitHost
import PluginKitTesting

@Suite("Configuration")
struct ConfigurationTests {

    private var identity: PluginIdentity {
        PluginIdentity(id: "com.example.wordcount", version: "1.0.0", displayName: "Word Count")
    }

    private var schema: ConfigurationSchema {
        ConfigurationSchema(keys: [
            ConfigurationKeyDescriptor(
                name: "threshold", type: .int, defaultValue: 10, title: "Threshold"
            ),
            ConfigurationKeyDescriptor(
                name: "style", type: .string, defaultValue: "plain",
                allowedValues: [.string("plain"), .string("fancy")]
            ),
        ])
    }

    @Test("A read falls back through the layers to the schema default")
    func fallsBackToDefault() async {
        let store = LayeredConfigurationStore(identity: identity, schema: schema)
        #expect(await store.value(ConfigKey("threshold", default: 0)) == 10)
        #expect(await store.resolvedLayer("threshold") == .schemaDefault)
    }

    @Test("Higher layers win, in the documented order")
    func layerPrecedence() async {
        let store = LayeredConfigurationStore(
            identity: identity,
            schema: schema,
            session: [:],
            managed: ["threshold": 99],
            user: ["threshold": 50],
            bundled: ["threshold": 20]
        )
        #expect(await store.value(ConfigKey("threshold", default: 0)) == 99)
        #expect(await store.resolvedLayer("threshold") == .managed)

        await store.replace(layer: .managed, with: [:])
        #expect(await store.value(ConfigKey("threshold", default: 0)) == 50)

        await store.replace(layer: .user, with: [:])
        #expect(await store.value(ConfigKey("threshold", default: 0)) == 20)
    }

    @Test("A session override beats even a managed profile")
    func sessionBeatsManaged() async {
        // Session exists for launch flags and tests, which have to be able to
        // reproduce a configuration regardless of what is on the machine.
        let store = LayeredConfigurationStore(
            identity: identity, schema: schema, session: ["threshold": 1], managed: ["threshold": 99]
        )
        #expect(await store.value(ConfigKey("threshold", default: 0)) == 1)
    }

    @Test("A managed key is locked and reported as such")
    func managedKeysAreLocked() async {
        let store = LayeredConfigurationStore(
            identity: identity, schema: schema, managed: ["threshold": 99]
        )
        #expect(await store.isLocked("threshold"))
        #expect(!(await store.isLocked("style")))

        await #expect(throws: (any Error).self) {
            try await store.set(ConfigKey("threshold", default: 0), to: 5)
        }
    }

    @Test("A read never throws, even with a value of the wrong type stored")
    func readsNeverThrow() async {
        // A corrupt preferences file must not be able to stop a plugin from loading.
        let store = LayeredConfigurationStore(
            identity: identity, schema: schema, user: ["threshold": "not a number"]
        )
        #expect(await store.value(ConfigKey("threshold", default: 7)) == 10)
    }

    @Test("A write outside the schema is refused")
    func schemaIsEnforcedOnWrite() async throws {
        let store = LayeredConfigurationStore(identity: identity, schema: schema)
        try await store.set(ConfigKey("style", default: "plain"), to: "fancy")
        #expect(await store.value(ConfigKey("style", default: "plain")) == "fancy")

        await #expect(throws: (any Error).self) {
            try await store.set(ConfigKey("style", default: "plain"), to: "neon")
        }
    }

    @Test("A schema whose default contradicts its own type is rejected")
    func schemaDefaultsAreTypeChecked() {
        let bad = ConfigurationSchema(keys: [
            ConfigurationKeyDescriptor(name: "threshold", type: .int, defaultValue: "ten")
        ])
        #expect(throws: PluginManifestError.self) { try bad.validateStructure() }
    }

    @Test("Changes reach an observer")
    func changesAreObservable() async throws {
        let store = LayeredConfigurationStore(identity: identity, schema: schema)
        let stream = store.changes()

        let received = Task { () -> ConfigurationChange? in
            for await change in stream { return change }
            return nil
        }
        // The stream registers on the actor a moment after `changes()` returns, so
        // give it a turn before publishing. Documented behaviour, not a flake.
        try await Task.sleep(for: .milliseconds(20))
        try await store.set(ConfigKey("style", default: "plain"), to: "fancy")

        let change = try await received.value
        #expect(change?.name == "style")
        #expect(change?.layer == .user)
    }

    @Test("The resolution order is the declared precedence")
    func resolutionOrderIsStable() {
        #expect(
            ConfigurationLayer.resolutionOrder
                == [.session, .managed, .user, .bundled, .schemaDefault]
        )
    }
}

@Suite("Plugin storage")
struct StorageTests {

    @Test("A key cannot escape its container")
    func keysAreSanitised() {
        // Without this a key of "../../other" would write into a peer's container.
        #expect(FileSystemPluginStorage.sanitise("../../escape") == "escape")
        #expect(FileSystemPluginStorage.sanitise(".hidden") == "hidden")
        #expect(FileSystemPluginStorage.sanitise("normal-key_1.2") == "normal-key_1.2")
        #expect(FileSystemPluginStorage.sanitise("/absolute/path") == "absolutepath")
    }

    @Test("Values round-trip through a real container")
    func fileStorageRoundTrips() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pluginkit-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = FileSystemPluginStorage(containerURL: root)
        try await storage.setValue(["a", "b"], forKey: "list")

        #expect(try await storage.value([String].self, forKey: "list") == ["a", "b"])
        #expect(try await storage.keys() == ["list"])

        try await storage.setData(nil, forKey: "list")
        #expect(try await storage.data(forKey: "list") == nil)
    }
}

@Suite("Event bus")
struct EventBusTests {

    @Test("A plugin can only publish to topics it was granted")
    func publishIsGated() async throws {
        let bus = BrokeredEventBus()
        let allowed = await bus.scoped(
            to: "com.example.a", publishing: ["document.*"], subscribing: ["*"]
        )
        let refused = await bus.scoped(
            to: "com.example.b", publishing: ["other.*"], subscribing: ["*"]
        )

        try await allowed.publish(DocumentSaved(path: "/tmp/a"))

        // A plugin forging `document.saved` could mislead every other plugin, so
        // publish rights are granted per topic rather than assumed.
        await #expect(throws: (any Error).self) {
            try await refused.publish(DocumentSaved(path: "/tmp/b"))
        }
    }

    @Test("A plugin cannot subscribe to a topic outside its grants")
    func subscribeIsGated() async throws {
        let bus = BrokeredEventBus()
        let scoped = await bus.scoped(
            to: "com.example.a", publishing: [], subscribing: ["document.*"]
        )

        let collected = PathCollector()
        let stream = scoped.subscribe(to: SecretHostEvent.self)
        let task = Task {
            for await event in stream { await collected.append(event.payload) }
        }
        try await Task.sleep(for: .milliseconds(20))
        await bus.publishFromHost(SecretHostEvent(payload: "internal"))
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        #expect(await collected.paths.isEmpty)
    }

    @Test("A granted subscriber receives what the host publishes")
    func hostEventsReachSubscribers() async throws {
        let bus = BrokeredEventBus()
        let scoped = await bus.scoped(
            to: "com.example.a", publishing: [], subscribing: ["document.*"]
        )

        let collected = PathCollector()
        let stream = scoped.subscribe(to: DocumentSaved.self)
        let task = Task {
            for await event in stream { await collected.append(event.path) }
        }
        try await Task.sleep(for: .milliseconds(20))
        await bus.publishFromHost(DocumentSaved(path: "/tmp/x.md"))
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        #expect(await collected.paths == ["/tmp/x.md"])
    }

    @Test("Topic patterns match a trailing wildcard and nothing broader")
    func patternMatching() {
        #expect(BrokeredEventBus.matches("document.saved", patterns: ["*"]))
        #expect(BrokeredEventBus.matches("document.saved", patterns: ["document.*"]))
        #expect(BrokeredEventBus.matches("document.saved", patterns: ["document.saved"]))
        #expect(!BrokeredEventBus.matches("document.saved", patterns: ["selection.*"]))
        #expect(!BrokeredEventBus.matches("documentary", patterns: ["document.*"]))
    }
}

@Suite("Plugin services")
struct ServiceTests {

    @Test("A consumer reaches a provider's service through the host, and it activates it")
    func serviceIsBrokered() async throws {
        let counter = InstantiationCounter()
        let provider = Fixture.wordCount(id: "com.example.provider")
        let consumer = Fixture.minimal(
            id: "com.example.consumer",
            name: "viaService",
            dependencies: [PluginDependency(id: "com.example.provider")]
        )

        let manager = Fixture.manager(plugins: [
            entry(provider, counter.tracking(provider.id) { WordCountPlugin() }),
            entry(consumer, counter.tracking(consumer.id) { ConsumerPlugin() }),
        ])
        await manager.start()

        // Nothing is loaded yet, including the provider.
        #expect(counter.total == 0)

        let handle = try #require(
            await manager.contributions(to: CommandPoint.self)
                .first { $0.contributor.id == consumer.id }
        )
        let command = try await handle.resolve()
        let result = try await CommandPoint.invoke(command, with: RunCommand(text: "a b c"))

        #expect(result.wordCount == 3)
        #expect(result.note == "via service")
        // Resolving the consumer pulled the provider up with it, on demand.
        #expect(counter.count(for: provider.id) == 1)
        #expect(await manager.plugin(provider.id)?.phase == .active)
    }

    @Test("A service nobody provides is a clear error, not a hang")
    func missingServiceFails() async throws {
        let consumer = Fixture.minimal(id: "com.example.consumer", name: "viaService")
        let manager = Fixture.manager(plugins: [entry(consumer) { ConsumerPlugin() }])
        await manager.start()

        let handle = await manager.contributions(to: CommandPoint.self)[0]
        await #expect(throws: (any Error).self) { _ = try await handle.resolve() }
        #expect(await manager.plugin(consumer.id)?.phase == .failed)
    }

    @Test("Publishing an undeclared service is refused")
    func undeclaredServiceRefused() async {
        // `WordCountPlugin` provides `text.wordCount`; this manifest does not declare it.
        let manifest = Fixture.wordCount(provides: [])
        let harness = PluginHarness(manifest: manifest)
        await harness.deny("fs.read")

        await #expect(throws: (any Error).self) {
            try await harness.activate(WordCountPlugin())
        }
    }
}

actor PathCollector {
    var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}
