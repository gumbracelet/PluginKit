import Foundation
import Testing
@testable import PluginKitCore
import PluginKitSDK

@Suite("Manifest and value types")
struct ManifestTests {

    @Test("A hand-written manifest decodes with only its required keys")
    func minimalManifestDecodes() throws {
        let json = """
        {
          "id": "com.example.tiny",
          "version": "0.2.1",
          "displayName": "Tiny"
        }
        """
        let manifest = try PluginManifest.decode(from: Data(json.utf8))

        #expect(manifest.id == "com.example.tiny")
        #expect(manifest.version == SemanticVersion(0, 2, 1))
        // Everything unstated has a defensible default, so the shortest useful
        // manifest is three lines rather than thirty.
        #expect(manifest.activation == .onDemand)
        #expect(manifest.contributions.isEmpty)
        #expect(manifest.sdkVersion == .any)
    }

    @Test("A manifest round-trips through JSON unchanged")
    func roundTrips() throws {
        let original = Fixture.wordCount()
        let decoded = try PluginManifest.decode(from: try original.encoded())
        #expect(decoded == original)
    }

    @Test("A decoding failure names the key an author has to fix")
    func decodingErrorIsActionable() throws {
        let json = """
        { "id": "com.example.tiny", "displayName": "Tiny" }
        """
        do {
            _ = try PluginManifest.decode(from: Data(json.utf8))
            Issue.record("Expected a decoding failure.")
        } catch let error as PluginManifestError {
            guard case .decodingFailed(let reason) = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            // The raw DecodingError names Swift types the author never wrote.
            #expect(reason.contains("version"))
        }
    }

    @Test("Duplicate contributions are rejected structurally")
    func duplicateContributionsRejected() {
        var manifest = Fixture.wordCount()
        manifest.contributions.append(manifest.contributions[0])

        #expect(throws: PluginManifestError.self) {
            try manifest.validateStructure()
        }
    }

    @Test("A capability request without a reason is rejected")
    func capabilityNeedsReason() {
        var manifest = Fixture.wordCount()
        manifest.capabilities = [CapabilityRequest(id: "fs.read", reason: "")]

        // The reason is the entire text a user sees when deciding. An empty one is
        // not a style problem, it is a broken consent prompt.
        #expect(throws: PluginManifestError.self) {
            try manifest.validateStructure()
        }
    }

    @Test("A plugin cannot depend on itself")
    func selfDependencyRejected() {
        var manifest = Fixture.wordCount()
        manifest.dependencies = [PluginDependency(id: manifest.id)]

        #expect(throws: PluginManifestError.self) {
            try manifest.validateStructure()
        }
    }

    @Test("The declared contribution lookup drives manifest authority")
    func contributionLookup() {
        let manifest = Fixture.wordCount()
        #expect(manifest.contribution(to: CommandPoint.extensionPointID, named: "count") != nil)
        #expect(manifest.contribution(to: CommandPoint.extensionPointID, named: "other") == nil)
        #expect(manifest.capabilityRequest(for: "fs.read") != nil)
        #expect(manifest.capabilityRequest(for: "net.http") == nil)
    }

    @Test("The builder emits a manifest that passes host validation")
    func builderProducesValidManifest() throws {
        let manifest = try PluginManifestBuilder(
            id: "com.example.built",
            version: "1.0.0",
            displayName: "Built"
        )
        .requesting("fs.read", required: false, reason: "Reads the open document.")
        .contributing(
            to: CommandPoint.self,
            named: "run",
            priority: 5,
            metadata: CommandPoint.Metadata(title: "Run", category: "Build")
        )
        .validated()

        #expect(manifest.contributions.count == 1)
        #expect(manifest.contributions[0].contractVersion == CommandPoint.contractVersion)
        // Contributing through the typed overload records the vocabulary too, so the
        // two cannot disagree.
        #expect(manifest.contracts.contains { $0.vocabulary == CommandPoint.vocabulary })
        #expect(manifest.contributions[0].metadata["title"] == .string("Run"))
    }
}

@Suite("Semantic versions and ranges")
struct VersionTests {

    @Test("Versions parse, order, and round-trip", arguments: [
        ("1", SemanticVersion(1, 0, 0)),
        ("1.2", SemanticVersion(1, 2, 0)),
        ("1.2.3", SemanticVersion(1, 2, 3)),
    ])
    func parsing(input: String, expected: SemanticVersion) {
        #expect(SemanticVersion(string: input) == expected)
    }

    @Test("A pre-release sorts below its release")
    func prereleaseOrdering() {
        #expect(SemanticVersion(string: "1.0.0-beta.1")! < SemanticVersion(1, 0, 0))
        #expect(SemanticVersion(string: "1.0.0-alpha")! < SemanticVersion(string: "1.0.0-beta")!)
    }

    @Test("Malformed versions fail rather than defaulting")
    func malformedVersionsFail() {
        #expect(SemanticVersion(string: "") == nil)
        #expect(SemanticVersion(string: "1.2.3.4") == nil)
        #expect(SemanticVersion(string: "not-a-version") == nil)
    }

    @Test("Ranges parse every documented spelling", arguments: [
        "*", "1.2.3", ">=1.0.0", "<2.0.0", ">=1.0.0 <2.0.0", "1.0.0..<2.0.0",
    ])
    func rangeParsing(input: String) {
        #expect(VersionRange(string: input) != nil)
    }

    @Test("A 1.x series spans the whole major and stops at the next one")
    func seriesForStableVersion() {
        let range = VersionRange.series(of: "1.4.2")
        #expect(range.contains("1.0.0"))
        #expect(range.contains("1.99.99"))
        #expect(!range.contains("2.0.0"))
        #expect(!range.contains("0.9.0"))
    }

    @Test("A 0.x series stops at the next minor, because 0.x minors may break")
    func seriesForPrereleaseVersion() {
        // Semver explicitly permits a 0.x minor bump to break. Treating 0.1 and 0.9
        // as compatible would let a plugin built against an early prototype load
        // into a host that has since changed the contract underneath it.
        let range = VersionRange.series(of: "0.3.4")
        #expect(range.contains("0.3.0"))
        #expect(range.contains("0.3.9"))
        #expect(!range.contains("0.4.0"))
        #expect(!range.contains("0.2.9"))
    }

    @Test("What a plugin works with starts at what it was built against")
    func compatibleWithIsLowerBounded() {
        // Wider at the bottom would be a lie: a plugin built against 1.4 may use
        // something 1.4 added, so it cannot run on 1.0.
        let range = VersionRange.compatible(with: "1.4.0")
        #expect(range.contains("1.4.0"))
        #expect(range.contains("1.9.0"))
        #expect(!range.contains("1.0.0"))
        #expect(!range.contains("2.0.0"))
    }

    @Test("An exact range admits only that version")
    func exactRange() {
        let range = VersionRange.exact("1.2.3")
        #expect(range.contains("1.2.3"))
        #expect(!range.contains("1.2.4"))
        #expect(!range.contains("1.2.2"))
    }

    @Test("Overlap decides whether a negotiated version exists")
    func overlap() {
        let hostAccepts = VersionRange(string: ">=2.0.0 <3.0.0")!
        #expect(hostAccepts.overlaps(VersionRange(string: ">=2.1.0 <4.0.0")!))
        #expect(!hostAccepts.overlaps(VersionRange(string: ">=1.0.0 <2.0.0")!))
        #expect(!hostAccepts.overlaps(VersionRange(string: ">=3.0.0")!))
    }

    @Test("Ranges round-trip through their string form")
    func rangeRoundTrip() throws {
        for text in ["*", ">=1.0.0", "<2.0.0", ">=1.0.0 <2.0.0"] {
            let range = VersionRange(string: text)!
            let encoded = try JSONEncoder().encode(range)
            #expect(try JSONDecoder().decode(VersionRange.self, from: encoded) == range)
        }
    }
}

@Suite("JSONValue")
struct JSONValueTests {

    @Test("Integers survive a round-trip as integers, not doubles")
    func integersStayIntegers() throws {
        let value: JSONValue = ["count": 3]
        let decoded = try JSONDecoder().decode(
            JSONValue.self, from: try JSONEncoder().encode(value)
        )
        #expect(decoded["count"] == .int(3))
    }

    @Test("Booleans are not mistaken for integers")
    func booleansStayBooleans() throws {
        // NSNumber bridges Bool and Int to the same class; without the CFBoolean
        // check every `1` would come back as `true`.
        let value: JSONValue = ["flag": true, "one": 1]
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(value)
        )
        let wrapped = JSONValue(foundationObject: object)

        #expect(wrapped?["flag"] == .bool(true))
        #expect(wrapped?["one"] == .int(1))
    }

    @Test("Decoding into a concrete type is how host metadata stays typed")
    func decodeIntoConcreteType() throws {
        let value: JSONValue = ["title": "Count Words", "category": "Text"]
        let metadata = try value.decode(as: CommandPoint.Metadata.self)

        #expect(metadata.title == "Count Words")
        #expect(metadata.category == "Text")
    }

    @Test("A missing required field fails decoding")
    func missingFieldFails() {
        let value: JSONValue = ["category": "Text"]
        #expect(throws: (any Error).self) {
            try value.decode(as: CommandPoint.Metadata.self)
        }
    }

    @Test("EmptyMetadata decodes from anything, so a point can gain metadata later")
    func emptyMetadataIsPermissive() throws {
        _ = try JSONValue.object([:]).decode(as: EmptyMetadata.self)
        _ = try JSONValue.null.decode(as: EmptyMetadata.self)
        _ = try JSONValue.object(["unexpected": 1]).decode(as: EmptyMetadata.self)
    }

    @Test("Rendering is stable, so diagnostics and golden files are comparable")
    func stableDescription() {
        let value: JSONValue = ["b": 2, "a": 1]
        #expect(value.description == "{\"a\":1,\"b\":2}")
    }
}
