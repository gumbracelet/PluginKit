import Foundation
import PluginKitCore
import PluginKitHost
import PluginKitInProcess
import PluginKitSDK
import PluginKitTesting

// A complete example host vocabulary, in the shape a real one would take: its own
// package, depending on PluginKitCore and nothing else. Every test builds its world
// from these rather than from ad-hoc types, so the suite exercises the same
// declaration path an actual host would write.

// MARK: - The host's vocabulary

struct RunCommand: Codable, Sendable, Equatable {
    var text: String
}

struct CommandResult: Codable, Sendable, Equatable {
    var wordCount: Int
    var note: String?
}

/// The contract shape recommended for a remotable point: one `handle`, both sides
/// `Codable`. Pinning `Request`/`Response` in the `where` clause is what lets
/// `any Command` be called directly.
protocol Command: RemotableContract where Request == RunCommand, Response == CommandResult {}

enum CommandPoint: RemotableExtensionPoint {
    typealias Contract = any Command
    typealias Request = RunCommand
    typealias Response = CommandResult

    struct Metadata: Codable, Sendable, Equatable {
        let title: String
        var category: String?
    }

    static let extensionPointID: ExtensionPointID = "com.example.editor.command"
    static let vocabulary: VocabularyID = "com.example.editor.api"
    static let contractVersion: SemanticVersion = "1.2.0"

    static func invoke(_ contract: Contract, with request: RunCommand) async throws -> CommandResult {
        try await contract.handle(request)
    }
}

/// A point that genuinely cannot be remoted, to exercise the locality rules.
final class InspectorView: Sendable {
    let title: String
    init(title: String) { self.title = title }
}

protocol InspectorProviding: Sendable {
    func makeView() -> InspectorView
}

enum InspectorPoint: LocalExtensionPoint {
    typealias Contract = any InspectorProviding

    static let extensionPointID: ExtensionPointID = "com.example.editor.inspector"
    static let vocabulary: VocabularyID = "com.example.editor.api"
    static let contractVersion: SemanticVersion = "1.0.0"
    static let localityReason = "Vends live view objects into the host's view hierarchy."
    static let arity: ExtensionPointArity = .single
}

/// A response that loses a field when it crosses a serialization boundary — the
/// exact class of bug `PluginHarness.Transport.serializing` exists to catch.
struct LossyResult: Codable, Sendable, Equatable {
    var count: Int
    var note: String?

    private enum CodingKeys: String, CodingKey { case count, note }

    init(count: Int, note: String?) {
        self.count = count
        self.note = note
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decode(Int.self, forKey: .count)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// Forgets `note`. A plausible hand-written `encode` — and invisible in-process.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
    }
}

protocol LossyCommand: RemotableContract where Request == RunCommand, Response == LossyResult {}

enum LossyPoint: RemotableExtensionPoint {
    typealias Contract = any LossyCommand
    typealias Request = RunCommand
    typealias Response = LossyResult

    static let extensionPointID: ExtensionPointID = "com.example.editor.lossy"
    static let vocabulary: VocabularyID = "com.example.editor.api"
    static let contractVersion: SemanticVersion = "1.0.0"

    static func invoke(_ contract: Contract, with request: RunCommand) async throws -> LossyResult {
        try await contract.handle(request)
    }
}

// MARK: - The host's capabilities

/// A capability handle: concrete type, injected implementation. See ``Capability``
/// for why this is not a protocol.
struct FileReading: Capability {
    struct Scope: CapabilityScope {
        var roots: [String]

        static var unrestricted: Scope { Scope(roots: ["/"]) }

        /// Keeps only roots the limit also permits. Prefix-based, so a limit of
        /// `/tmp` admits `/tmp/work` but not `/etc`.
        func attenuated(to limit: Scope) -> Scope? {
            let kept = roots.filter { root in
                limit.roots.contains { root == $0 || root.hasPrefix($0) }
            }
            return kept.isEmpty ? nil : Scope(roots: kept)
        }
    }

    static let capabilityID: CapabilityID = "fs.read"
    static let sensitivity: CapabilitySensitivity = .sensitive

    /// The scope actually granted, so a plugin — and a test — can see the narrowing.
    let grantedRoots: [String]
    private let reader: @Sendable (String) async throws -> String

    init(grantedRoots: [String], reader: @escaping @Sendable (String) async throws -> String) {
        self.grantedRoots = grantedRoots
        self.reader = reader
    }

    func contents(of path: String) async throws -> String { try await reader(path) }
}

struct NetworkAccess: Capability {
    static let capabilityID: CapabilityID = "net.http"
    static let sensitivity: CapabilitySensitivity = .dangerous
    init() {}
}

/// A capability the fixtures never register, for the "host does not provide it" path.
struct ContactsAccess: Capability {
    static let capabilityID: CapabilityID = "contacts.read"
    init() {}
}

// MARK: - A service one plugin publishes for another

struct WordCounting: PluginService {
    static let serviceID: ServiceID = "text.wordCount"
    static let serviceVersion: SemanticVersion = "1.0.0"

    private let counter: @Sendable (String) -> Int
    init(counter: @escaping @Sendable (String) -> Int) { self.counter = counter }
    func count(_ text: String) -> Int { counter(text) }
}

// MARK: - Events

struct DocumentSaved: PluginEvent {
    static let topic: TopicID = "document.saved"
    var path: String
}

struct SecretHostEvent: PluginEvent {
    static let topic: TopicID = "host.internal"
    var payload: String
}

// MARK: - Plugins

/// The well-behaved reference plugin: declares what it uses, degrades when an
/// optional capability is denied, registers exactly what its manifest promises.
actor WordCountPlugin: Plugin {
    private var files: FileReading?
    private(set) var deactivations = 0

    init() {}

    func activate(_ context: any PluginContext) async throws {
        files = await context.optionalCapability(FileReading.self)
        let reader = files

        try await context.register(CommandPoint.self, name: "count") {
            CountCommand(files: reader)
        }
        try await context.provide(WordCounting.self) {
            WordCounting(counter: { $0.split(separator: " ").count })
        }
    }

    func deactivate() async {
        deactivations += 1
        files = nil
    }

    func healthCheck() async -> PluginHealth {
        files == nil ? .degraded(reason: "No file access; counts only the supplied text.") : .ok
    }
}

struct CountCommand: Command {
    let files: FileReading?

    func handle(_ request: RunCommand) async throws -> CommandResult {
        let words = request.text.split(whereSeparator: \.isWhitespace).count
        return CommandResult(
            wordCount: words,
            note: files == nil ? "no file access" : "roots: \(files!.grantedRoots.joined(separator: ","))"
        )
    }
}

/// Needs a capability and says so. Must fail cleanly when it is denied.
actor StrictPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        let files = try await context.capability(FileReading.self)
        try await context.register(CommandPoint.self, name: "strict") {
            CountCommand(files: files)
        }
    }

    func deactivate() async {}
}

/// Registers a contribution its manifest never declared. The host must refuse.
actor SneakyPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        try await context.register(CommandPoint.self, name: "undeclared") {
            CountCommand(files: nil)
        }
    }

    func deactivate() async {}
}

/// Asks for a capability it never declared. The host must refuse before policy.
actor GreedyPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        _ = try await context.capability(NetworkAccess.self)
        try await context.register(CommandPoint.self, name: "greedy") {
            CountCommand(files: nil)
        }
    }

    func deactivate() async {}
}

/// Throws on activation, for the failure and quarantine paths.
actor BrokenPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        throw PluginKitError.misconfigured(reason: "Intentionally broken.")
    }

    func deactivate() async {}
}

actor InspectorPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        try await context.register(InspectorPoint.self, name: "panel") {
            StubInspector()
        }
    }

    func deactivate() async {}
}

struct StubInspector: InspectorProviding {
    func makeView() -> InspectorView { InspectorView(title: "Stub") }
}

/// Consumes a peer's service through the host, never directly.
actor ConsumerPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        let counting = try await context.service(WordCounting.self)
        try await context.register(CommandPoint.self, name: "viaService") {
            ServiceBackedCommand(counting: counting)
        }
    }

    func deactivate() async {}
}

struct ServiceBackedCommand: Command {
    let counting: WordCounting

    func handle(_ request: RunCommand) async throws -> CommandResult {
        CommandResult(wordCount: counting.count(request.text), note: "via service")
    }
}

/// Loses a response field over a serialization boundary.
actor LossyPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        try await context.register(LossyPoint.self, name: "lossy") { LossyThing() }
    }

    func deactivate() async {}
}

struct LossyThing: LossyCommand {
    func handle(_ request: RunCommand) async throws -> LossyResult {
        LossyResult(count: request.text.count, note: "this note does not survive encoding")
    }
}

/// Publishes on a topic, for the event-bus ACL tests.
actor PublisherPlugin: Plugin {
    init() {}

    func activate(_ context: any PluginContext) async throws {
        try await context.events.publish(DocumentSaved(path: "/tmp/a.md"))
        try await context.register(CommandPoint.self, name: "publish") {
            CountCommand(files: nil)
        }
    }

    func deactivate() async {}
}

// MARK: - Fixtures

enum Fixture {
    static let host = "com.example.editor"

    static func catalog(
        deprecations: [ContractDeprecation] = [],
        includeInspector: Bool = true,
        includeLossy: Bool = false
    ) -> ExtensionPointCatalog {
        var catalog = ExtensionPointCatalog()
        catalog.register(
            CommandPoint.self,
            summary: "A command in the palette.",
            metadataShape: [
                MetadataFieldDescriptor(name: "title", type: "String"),
                MetadataFieldDescriptor(name: "category", type: "String", required: false),
            ],
            deprecations: deprecations
        )
        if includeInspector { catalog.register(InspectorPoint.self) }
        if includeLossy { catalog.register(LossyPoint.self) }
        return catalog
    }

    static func capabilities(
        readableRoots: [String] = ["/"],
        files: [String: String] = [:]
    ) -> CapabilityRegistry {
        var registry = CapabilityRegistry()
        registry.register(
            FileReading.self,
            summary: "Reads files inside the granted roots.",
            scopeExample: ["roots": ["~/Documents"]]
        ) { scope, _ in
            FileReading(grantedRoots: scope.roots) { path in
                guard let contents = files[path] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return contents
            }
        }
        registry.register(NetworkAccess.self) { _, _ in NetworkAccess() }
        return registry
    }

    /// A manifest for the reference plugin.
    static func wordCount(
        id: PluginID = "com.example.wordcount",
        version: SemanticVersion = "1.0.0",
        contractVersion: SemanticVersion = CommandPoint.contractVersion,
        capabilities: [CapabilityRequest] = [
            CapabilityRequest(
                id: "fs.read",
                scope: ["roots": ["/tmp", "/etc"]],
                required: false,
                reason: "Counts words in the open file."
            )
        ],
        activation: ActivationPolicy = .onDemand,
        metadata: JSONValue = ["title": "Count Words", "category": "Text"],
        provides: [ServiceDeclaration] = [
            ServiceDeclaration(id: "text.wordCount", version: "1.0.0")
        ]
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            version: version,
            displayName: "Word Count",
            summary: "Counts words.",
            sdkVersion: .compatible(with: PluginKitVersion.current),
            contracts: [
                ContractDependency(
                    vocabulary: CommandPoint.vocabulary,
                    builtAgainst: contractVersion
                )
            ],
            activation: activation,
            capabilities: capabilities,
            provides: provides,
            contributions: [
                Contribution(
                    extensionPoint: CommandPoint.extensionPointID,
                    name: "count",
                    contractVersion: contractVersion,
                    priority: 10,
                    metadata: metadata
                )
            ]
        )
    }

    /// A minimal manifest with one contribution and nothing else.
    static func minimal(
        id: PluginID,
        name: String,
        point: ExtensionPointID = CommandPoint.extensionPointID,
        contractVersion: SemanticVersion = CommandPoint.contractVersion,
        priority: Int = 0,
        metadata: JSONValue = ["title": "Untitled"],
        capabilities: [CapabilityRequest] = [],
        dependencies: [PluginDependency] = [],
        provides: [ServiceDeclaration] = [],
        version: SemanticVersion = "1.0.0"
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            version: version,
            displayName: id.rawValue,
            sdkVersion: .compatible(with: PluginKitVersion.current),
            contracts: [
                ContractDependency(
                    vocabulary: CommandPoint.vocabulary, builtAgainst: contractVersion
                )
            ],
            capabilities: capabilities,
            dependencies: dependencies,
            provides: provides,
            contributions: [
                Contribution(
                    extensionPoint: point,
                    name: name,
                    contractVersion: contractVersion,
                    priority: priority,
                    metadata: metadata
                )
            ]
        )
    }

    /// A manager wired with the fixture vocabulary and capabilities.
    static func manager(
        plugins: [(manifest: PluginManifest, factory: @Sendable () -> any Plugin)],
        trust: TrustLevel = .firstParty,
        catalog: ExtensionPointCatalog? = nil,
        capabilityPolicy: CapabilityPolicy = .allowAll,
        consent: (any ConsentStore)? = nil,
        files: [String: String] = [:],
        safeMode: Bool = false,
        crashBudget: CrashBudget = .lenient,
        vocabularies: [VocabularyDescriptor] = []
    ) -> PluginManager {
        HostHarness.manager(plugins: plugins, trust: trust, appIdentifier: host) { configuration in
            configuration.extensionPoints = catalog ?? Fixture.catalog(includeLossy: true)
            configuration.capabilities = Fixture.capabilities(files: files)
            configuration.capabilityPolicy = capabilityPolicy
            if let consent { configuration.consent = consent }
            configuration.safeMode = safeMode
            configuration.crashBudget = crashBudget
            configuration.vocabularies = vocabularies
        }
    }
}

/// Pairs a manifest with its factory.
///
/// A free function rather than a tuple literal so the closure is inferred
/// `@Sendable` — inside an array-of-tuples literal it is not, and every call site
/// would need the annotation spelled out.
func entry(
    _ manifest: PluginManifest,
    _ factory: @escaping @Sendable () -> any Plugin
) -> (manifest: PluginManifest, factory: @Sendable () -> any Plugin) {
    (manifest, factory)
}
