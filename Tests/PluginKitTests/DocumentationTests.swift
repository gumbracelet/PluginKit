import Foundation
import Testing
import PluginKitCore
import PluginKitHost
import PluginKitInProcess
import PluginKitSDK
import PluginKitTesting

// The code from README.md and docs/getting-started.md, compiled.
//
// Documentation that does not compile is documentation that will drift, and the
// drift is invisible until someone follows it and fails. So the published
// examples live here too, and a rename that breaks them breaks the build.
//
// Type names carry a `Docs` prefix only to avoid colliding with the fixtures in
// TestSupport.swift; everything else is as published.

// MARK: - docs/getting-started.md § 1. Declare your vocabulary

struct DocsRunCommand: Codable, Sendable {
    var text: String
    init(text: String) { self.text = text }
}

struct DocsCommandResult: Codable, Sendable {
    var didHandle: Bool
    var message: String?
    init(didHandle: Bool, message: String? = nil) {
        self.didHandle = didHandle
        self.message = message
    }
}

protocol DocsCommand: RemotableContract
    where Request == DocsRunCommand, Response == DocsCommandResult {}

enum DocsCommandPoint: RemotableExtensionPoint {
    typealias Contract = any DocsCommand
    typealias Request = DocsRunCommand
    typealias Response = DocsCommandResult

    struct Metadata: Codable, Sendable {
        let title: String
        var category: String?
        var keyEquivalent: String?
    }

    static let extensionPointID: ExtensionPointID = "com.acme.editor.command"
    static let vocabulary: VocabularyID = "com.acme.editor.api"
    static let contractVersion: SemanticVersion = "1.0.0"

    static func invoke(
        _ contract: Contract, with request: DocsRunCommand
    ) async throws -> DocsCommandResult {
        try await contract.handle(request)
    }
}

// MARK: - docs/getting-started.md § 2. Declare your capabilities

struct DocsFileReading: Capability {
    struct Scope: CapabilityScope {
        var roots: [String]
        init(roots: [String]) { self.roots = roots }

        static var unrestricted: Scope { Scope(roots: ["/"]) }

        func attenuated(to limit: Scope) -> Scope? {
            let kept = roots.filter { root in
                limit.roots.contains { root == $0 || root.hasPrefix($0) }
            }
            return kept.isEmpty ? nil : Scope(roots: kept)
        }
    }

    static let capabilityID: CapabilityID = "fs.read"
    static let sensitivity: CapabilitySensitivity = .sensitive

    let grantedRoots: [String]
    private let read: @Sendable (String) async throws -> Data

    init(grantedRoots: [String], read: @escaping @Sendable (String) async throws -> Data) {
        self.grantedRoots = grantedRoots
        self.read = read
    }

    func contents(of path: String) async throws -> Data { try await read(path) }
}

// MARK: - README § 3. Write a plugin

actor DocsMarkdownPlugin: Plugin {
    private var files: DocsFileReading?

    init() {}

    func activate(_ context: any PluginContext) async throws {
        files = await context.optionalCapability(DocsFileReading.self)
        let reader = files

        try await context.register(DocsCommandPoint.self, name: "render") {
            DocsRenderCommand(files: reader)
        }
    }

    func deactivate() async { files = nil }

    func healthCheck() async -> PluginHealth {
        files == nil ? .degraded(reason: "No file access; rendering the selection only.") : .ok
    }
}

struct DocsRenderCommand: DocsCommand {
    let files: DocsFileReading?

    func handle(_ request: DocsRunCommand) async throws -> DocsCommandResult {
        DocsCommandResult(didHandle: true, message: "Rendered \(request.text.count) characters.")
    }
}

// MARK: - docs/plugin-development.md § Shipping as a loadable bundle

@objc(DocsMarkdownEntry)
final class DocsMarkdownEntry: PluginPrincipal {
    override class func makePlugin() -> any Plugin { DocsMarkdownPlugin() }

    override class func contractVersions() -> [String: String] {
        ["com.acme.editor.api": "1.0.0"]
    }
}

// MARK: - The examples, run

@Suite("Documentation examples")
struct DocumentationTests {

    /// The manifest from README § 3, expressed through the builder rather than as
    /// JSON, so the fields and the types are both checked.
    private func manifest() throws -> PluginManifest {
        try PluginManifestBuilder(
            id: "com.acme.editor.markdown",
            version: "1.0.0",
            displayName: "Markdown Tools"
        )
        .requesting(
            "fs.read",
            scope: ["roots": ["~/Documents"]],
            required: false,
            reason: "Reads the open file to render a preview."
        )
        .contributing(
            to: DocsCommandPoint.self,
            named: "render",
            priority: 10,
            metadata: DocsCommandPoint.Metadata(title: "Render Markdown", category: "Text")
        )
        .validated()
    }

    @Test("The published manifest is valid and matches the published code")
    func manifestMatchesCode() async throws {
        let manifest = try manifest()
        let harness = PluginHarness(manifest: manifest)
        await harness.grant(DocsFileReading.self) { scope, _ in
            DocsFileReading(grantedRoots: scope.roots) { _ in Data() }
        }

        try await harness.activate(DocsMarkdownPlugin())

        let drift = await harness.drift()
        #expect(drift.isEmpty, "\(drift)")
    }

    /// The host wiring from README § 2 and getting-started § 3–4, minus the
    /// filesystem: registration, brokering, laziness, and resolution are real.
    @Test("The published host integration works, and loads nothing until used")
    func hostIntegration() async throws {
        let manifest = try manifest()
        let counter = InstantiationCounter()

        let manager = HostHarness.manager(
            plugins: [(manifest, counter.tracking(manifest.id) { DocsMarkdownPlugin() })],
            appIdentifier: "com.acme.editor"
        ) { configuration in
            configuration.extensionPoints.register(
                DocsCommandPoint.self,
                summary: "A command in the palette.",
                metadataShape: [
                    MetadataFieldDescriptor(name: "title", type: "String"),
                    MetadataFieldDescriptor(name: "category", type: "String", required: false),
                    MetadataFieldDescriptor(name: "keyEquivalent", type: "String", required: false),
                ]
            )
            configuration.capabilities.register(
                DocsFileReading.self,
                summary: "Reads files inside the granted roots.",
                scopeExample: ["roots": ["~/Documents"]]
            ) { scope, _ in
                DocsFileReading(grantedRoots: scope.roots) { _ in Data() }
            }
            configuration.defaultSubscribableTopics = ["document.*"]
        }

        await manager.start()

        // README's headline claim.
        let handles = await manager.contributions(to: DocsCommandPoint.self)
        #expect(handles.count == 1)
        #expect(handles[0].metadata.title == "Render Markdown")
        #expect(counter.total == 0)

        let command = try await handles[0].resolve()
        let result = try await DocsCommandPoint.invoke(
            command, with: DocsRunCommand(text: "# Heading")
        )
        #expect(result.didHandle)
        #expect(counter.total == 1)
    }

    /// docs/getting-started.md § 6 — the catalog an author reads with
    /// `pluginkit describe`, and the CLI parses back out of an app bundle.
    @Test("The emitted catalog round-trips for the CLI")
    func catalogRoundTrips() async throws {
        var catalog = ExtensionPointCatalog()
        catalog.register(
            DocsCommandPoint.self,
            summary: "A command in the palette.",
            metadataShape: [MetadataFieldDescriptor(name: "title", type: "String")]
        )

        let document = catalog.document(
            appIdentifier: "com.acme.editor",
            appVersion: "3.2.0",
            capabilities: [
                CapabilityDescriptor(id: "fs.read", sensitivity: .sensitive)
            ]
        )

        let decoded = try JSONDecoder().decode(
            CatalogDocument.self, from: try document.encoded()
        )
        #expect(decoded == document)
        #expect(decoded.extensionPoint("com.acme.editor.command")?.contractVersion == "1.0.0")
    }

    /// docs/plugin-development.md § Shipping as a loadable bundle — the handshake
    /// the host reads before calling `makePlugin()`.
    @Test("The published entry point declares its contracts")
    func entryPointHandshake() {
        let contracts = DocsMarkdownEntry.declaredContracts
        #expect(contracts.count == 1)
        #expect(contracts[0].vocabulary == "com.acme.editor.api")
        #expect(contracts[0].builtAgainst == SemanticVersion(1, 0, 0))
        #expect(DocsMarkdownEntry.makePlugin() is DocsMarkdownPlugin)
    }

    /// docs/testing.md § The serializing transport — both transports, same result.
    @Test(
        "The published contract survives a boundary",
        arguments: PluginHarness.Transport.allCases
    )
    func transports(transport: PluginHarness.Transport) async throws {
        let harness = PluginHarness(manifest: try manifest(), transport: transport)
        await harness.grant(DocsFileReading.self) { scope, _ in
            DocsFileReading(grantedRoots: scope.roots) { _ in Data() }
        }
        try await harness.activate(DocsMarkdownPlugin())

        let result = try await harness.invoke(
            DocsCommandPoint.self, name: "render", DocsRunCommand(text: "# Heading")
        )
        #expect(result.didHandle, "transport: \(transport)")
    }
}
