import Foundation
import Testing
import PluginKitCore
import PluginKitHost

@Suite("Extension point catalog")
struct CatalogTests {

    @Test("A contribution built against the current contract validates")
    func currentContractPasses() {
        let catalog = Fixture.catalog()
        let contribution = Contribution(
            extensionPoint: CommandPoint.extensionPointID,
            name: "count",
            contractVersion: CommandPoint.contractVersion,
            metadata: ["title": "Count"]
        )
        #expect(catalog.validate(contribution, permitsInProcess: true) == nil)
    }

    @Test("An unknown extension point is named, not silently ignored")
    func unknownPointIsReported() {
        let catalog = Fixture.catalog()
        let contribution = Contribution(
            extensionPoint: "com.example.editor.nonexistent",
            name: "x",
            contractVersion: "1.0.0"
        )
        guard case .unknownExtensionPoint(let id)? =
            catalog.validate(contribution, permitsInProcess: true)
        else {
            Issue.record("Expected unknownExtensionPoint.")
            return
        }
        #expect(id == "com.example.editor.nonexistent")
    }

    @Test("A next-major contract is refused with both versions in the message")
    func nextMajorRefused() throws {
        let catalog = Fixture.catalog()
        let contribution = Contribution(
            extensionPoint: CommandPoint.extensionPointID,
            name: "count",
            contractVersion: "2.0.0",
            metadata: ["title": "Count"]
        )
        guard case .contractVersionUnsupported(_, let built, let accepts)? =
            catalog.validate(contribution, permitsInProcess: true)
        else {
            Issue.record("Expected contractVersionUnsupported.")
            return
        }
        #expect(built == SemanticVersion(2, 0, 0))
        #expect(!accepts.contains("2.0.0"))
        // A plugin that "silently stopped appearing" is the failure mode this
        // replaces; the message has to be actionable on its own.
        let text = ExtensionPointError
            .contractVersionUnsupported(
                point: CommandPoint.extensionPointID, pluginBuiltAgainst: built, hostAccepts: accepts
            )
            .errorDescription ?? ""
        #expect(text.contains("2.0.0"))
    }

    @Test("An older contract inside the accepted range still loads")
    func olderContractAccepted() {
        let catalog = Fixture.catalog()
        let contribution = Contribution(
            extensionPoint: CommandPoint.extensionPointID,
            name: "count",
            contractVersion: "1.0.0",
            metadata: ["title": "Count"]
        )
        #expect(catalog.validate(contribution, permitsInProcess: true) == nil)
    }

    @Test("A host can widen what it accepts to keep an old major alive")
    func explicitWideRange() {
        var catalog = ExtensionPointCatalog()
        catalog.register(CommandPoint.self, accepting: "1.0.0" ..< "3.0.0")

        let contribution = Contribution(
            extensionPoint: CommandPoint.extensionPointID,
            name: "count",
            contractVersion: "2.4.0",
            metadata: ["title": "Count"]
        )
        #expect(catalog.validate(contribution, permitsInProcess: true) == nil)
    }

    @Test("Bad metadata is caught before any code loads, and names the field")
    func metadataValidatedWithoutLoading() {
        let catalog = Fixture.catalog()
        let contribution = Contribution(
            extensionPoint: CommandPoint.extensionPointID,
            name: "count",
            contractVersion: CommandPoint.contractVersion,
            metadata: ["category": "Text"]  // no `title`
        )
        guard case .metadataDecodingFailed(_, let reason)? =
            catalog.validate(contribution, permitsInProcess: true)
        else {
            Issue.record("Expected metadataDecodingFailed.")
            return
        }
        #expect(reason.contains("title"))
    }

    @Test("A local-only point is refused when in-process hosting is not permitted")
    func localityEnforced() {
        let catalog = Fixture.catalog()
        let contribution = Contribution(
            extensionPoint: InspectorPoint.extensionPointID,
            name: "panel",
            contractVersion: InspectorPoint.contractVersion
        )
        #expect(catalog.validate(contribution, permitsInProcess: true) == nil)

        guard case .localityViolation(_, let reason)? =
            catalog.validate(contribution, permitsInProcess: false)
        else {
            Issue.record("Expected localityViolation.")
            return
        }
        // The reason the point's author wrote, surfaced verbatim.
        #expect(reason == InspectorPoint.localityReason)
    }

    @Test("requiresInProcess reflects whether any contribution forces it")
    func requiresInProcessDetection() {
        let catalog = Fixture.catalog()
        let command = Contribution(
            extensionPoint: CommandPoint.extensionPointID,
            name: "count",
            contractVersion: CommandPoint.contractVersion
        )
        let inspector = Contribution(
            extensionPoint: InspectorPoint.extensionPointID,
            name: "panel",
            contractVersion: InspectorPoint.contractVersion
        )
        #expect(!catalog.requiresInProcess([command]))
        #expect(catalog.requiresInProcess([command, inspector]))
    }

    @Test("A deprecated contract still loads, and says so with the host's guidance")
    func deprecationIsSurfacedNotEnforced() throws {
        let catalog = Fixture.catalog(deprecations: [
            ContractDeprecation(
                major: 1,
                since: "1.2.0",
                removedIn: "2.0.0",
                guidance: "Move category into the new tags field."
            )
        ])
        let contribution = Contribution(
            extensionPoint: CommandPoint.extensionPointID,
            name: "count",
            contractVersion: "1.0.0",
            metadata: ["title": "Count"]
        )

        // Deprecated is not the same as rejected: the plugin keeps working.
        #expect(catalog.validate(contribution, permitsInProcess: true) == nil)

        let warning = try #require(catalog.deprecationWarning(for: contribution))
        #expect(warning.kind == .deprecatedContract)
        #expect(warning.guidance == "Move category into the new tags field.")
    }

    @Test("The emitted catalog carries everything an author needs to target the host")
    func catalogDocumentIsComplete() throws {
        let catalog = Fixture.catalog()
        let document = catalog.document(
            appIdentifier: Fixture.host,
            appVersion: "3.2.0",
            capabilities: Fixture.capabilities().descriptors,
            topics: [TopicDescriptor(id: DocumentSaved.topic, pluginMayPublish: false)]
        )

        let command = try #require(document.extensionPoint(CommandPoint.extensionPointID))
        #expect(command.contractVersion == CommandPoint.contractVersion)
        #expect(command.metadataShape.map(\.name) == ["title", "category"])
        if case .remotable = command.locality {} else {
            Issue.record("CommandPoint should be remotable.")
        }

        let inspector = try #require(document.extensionPoint(InspectorPoint.extensionPointID))
        guard case .local(let reason) = inspector.locality else {
            Issue.record("InspectorPoint should be local-only.")
            return
        }
        #expect(reason == InspectorPoint.localityReason)

        // The vocabulary is inferred from the points even though it was not declared,
        // so an author never sees a blank where a version should be.
        let vocabulary = try #require(document.vocabulary(CommandPoint.vocabulary))
        #expect(vocabulary.version == CommandPoint.contractVersion)

        #expect(document.capability("fs.read")?.sensitivity == .sensitive)
        #expect(document.topics.first?.pluginMayPublish == false)
    }

    @Test("The emitted catalog round-trips, so the CLI reads what the host wrote")
    func catalogDocumentRoundTrips() throws {
        let document = Fixture.catalog().document(
            appIdentifier: Fixture.host,
            appVersion: "3.2.0",
            capabilities: Fixture.capabilities().descriptors
        )
        let decoded = try JSONDecoder().decode(
            CatalogDocument.self, from: try document.encoded()
        )
        #expect(decoded == document)
    }
}
