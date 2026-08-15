# Extension points

Designing the vocabulary your app publishes, and evolving it without breaking the plugins
that already target it.

- [Anatomy](#anatomy)
- [Locality](#locality)
- [Arity and ordering](#arity-and-ordering)
- [Metadata design](#metadata-design)
- [Versioning](#versioning)
- [Deprecation](#deprecation)
- [Publishing the catalog](#publishing-the-catalog)
- [Design checklist](#design-checklist)

## Anatomy

An extension point is a typed socket with two halves:

| Half | Lives in | Read when |
|---|---|---|
| **`Metadata`** | the manifest | at discovery, with no code loaded |
| **`Contract`** | the plugin's code | on first `resolve()` |

Splitting them is what lets a host build its entire command palette at launch for the cost
of reading JSON, then load a plugin the first time someone clicks one of its items.

```swift
public enum ExporterPoint: RemotableExtensionPoint {
    public typealias Contract = any Exporter
    public typealias Request = ExportRequest
    public typealias Response = ExportResult

    public struct Metadata: Codable, Sendable {
        public let displayName: String          // for the Export… menu
        public let fileExtension: String        // for the save panel
        public var supportsBatch: Bool = false  // to enable a control
    }

    public static let extensionPointID: ExtensionPointID = "com.acme.editor.exporter"
    public static let vocabulary: VocabularyID = "com.acme.editor.api"
    public static let contractVersion: SemanticVersion = "1.0.0"
    public static let arity: ExtensionPointArity = .many(ordering: .priority)

    public static func invoke(
        _ contract: Contract, with request: ExportRequest
    ) async throws -> ExportResult {
        try await contract.handle(request)
    }
}
```

### Identifiers

`extensionPointID` is reverse-DNS and permanent. Renaming it orphans every plugin that
targets it, with no migration path — the host simply reports
`unknownExtensionPoint`. Treat it as you would a public URL.

`vocabulary` groups points that version together. One host may publish several: a stable
`com.acme.editor.api` and an experimental `com.acme.editor.labs`, versioned independently,
so the experimental one can churn without forcing a major bump on everything else.

## Locality

The rich-protocol-versus-serializable question is answered by which protocol you conform to,
so an author never has to guess:

| | Hostable in | Conform to |
|---|---|---|
| **Remotable** — the default | in-process, XPC, app extension, script | `RemotableExtensionPoint` |
| **Local** — the opt-out | in-process only | `LocalExtensionPoint` |

### Remotable

Requires a `Request`/`Response` pair, both `Codable & Sendable`, plus a one-line `invoke`
shim. That shim is not ceremony: it is how a transport calls the contract, and it is what
`PluginHarness.Transport.serializing` uses to prove the contract survives a boundary.

Multi-operation contracts are modelled as an enum `Request`:

```swift
public enum LinterRequest: Codable, Sendable {
    case lint(text: String, language: String)
    case fixAll(text: String)
    case describeRules
}
```

Verbose, but it needs no code generation, works identically across every transport, and is
trivially recordable and replayable in tests. Richer multi-method remotable protocols need a
generated proxy and skeleton; see [distribution.md](distribution.md#roadmap).

### Local

```swift
public enum InspectorPoint: LocalExtensionPoint {
    public typealias Contract = any InspectorProviding   // vends live NSView
    public static let localityReason =
        "Vends NSView instances directly into the host's view hierarchy."
    // …
}
```

`localityReason` is required and is shown by `pluginkit describe` and in the emitted
catalog, so an author discovers the constraint **while choosing which point to target** —
not after their sandboxed plugin fails to load.

Local costs something real: a plugin contributing to a local point can never be isolated, so
one whose trust level forbids in-process hosting is reported `.unsatisfied` with a locality
violation rather than loaded. That friction is the feature — the escape hatch should be
visible.

> Even UI can be remoted, via app-extension remote view controllers, at the cost of a
> narrower interaction model. `LocalExtensionPoint` is a pragmatic escape hatch, not a
> physical law. Treat each use as a debt entry.

## Arity and ordering

```swift
public static let arity: ExtensionPointArity = .many(ordering: .priority)   // default
public static let arity: ExtensionPointArity = .many(ordering: .declared)
public static let arity: ExtensionPointArity = .single
```

- **`.many(ordering: .priority)`** — descending `Contribution.priority`. The default, and
  right for menus and palettes where plugins reasonably compete for position.
- **`.many(ordering: .declared)`** — manifest order, then source precedence. For pipelines
  where the author knows the order and the host has no opinion.
- **`.single`** — at most one contribution wins. `contributions(to:)` returns zero or one.

Ties always break by source precedence, then plugin ID, then contribution name. The result
is stable across launches: a menu whose order depends on load order is a bug that only shows
up on someone else's machine.

Use `.single` sparingly. A point that can only be filled once is a point the second plugin
author cannot use at all, and the losing contribution is not reported as an error — it is
simply absent.

## Metadata design

Metadata is everything the host needs to *present* a contribution without running it. The
test for whether a field belongs there: **could the host draw its UI without it?**

```swift
public struct Metadata: Codable, Sendable {
    public let displayName: String            // yes — needed to draw the menu item
    public let fileExtension: String          // yes — needed to build the save panel
    public var supportsBatch: Bool = false    // yes — enables or disables a control
    // public let compressionLevel: Int       // no — that is the contract's business
}
```

Three rules that save pain later:

1. **Give new fields defaults.** A field with a default is a minor bump; a required one is
   effectively major, because every existing manifest becomes invalid.
2. **Declare `metadataShape`** when registering. It costs one line per field and it is what
   `pluginkit describe` shows an author who has no access to your source.
3. **Keep it small.** Metadata is parsed for every installed plugin at every launch.

Metadata is validated at discovery against the type you registered. A contribution whose
payload does not decode is reported as `metadataDecodingFailed` **with the offending field
named**, before any plugin code exists in the process — and only that contribution is
affected. One plugin's bad manifest cannot empty another plugin's menu.

## Versioning

`contractVersion` is per point, semver, and its meaning is fixed by rule:

| Change | Bump | Existing plugins |
|---|---|---|
| Add an optional metadata field (with a default) | minor | keep working |
| Add a new extension point | minor | unaffected |
| Add a case to an enum `Request` | minor | keep working — they never send it |
| Add a **required** metadata field | **major** | break |
| Change a field's type or meaning | **major** | break |
| Remove or rename a field | **major** | break |
| Change what `invoke` does semantically | **major** | break |

What a host accepts is separate from what it is on:

```swift
// Default: the whole compatibility series of the current version.
configuration.extensionPoints.register(CommandPoint.self)

// Keep an old major alive alongside the new one.
configuration.extensionPoints.register(CommandPoint.self, accepting: "1.0.0" ..< "3.0.0")
```

`VersionRange.series(of:)` supplies the default and follows semver's 0.x rule: for `0.x`,
the next **minor** is the breaking boundary, so `series(of: "0.3.4")` is
`0.3.0 ..< 0.4.0`, not `0.0.0 ..< 1.0.0`. Getting that wrong would let a plugin built
against an early prototype load into a host that has since changed the contract.

A contribution outside the accepted range is reported before loading:

```
The plugin was built against 'com.acme.editor.command' contract 2.0.0;
this host accepts >=1.0.0 <2.0.0.
```

Both versions are in the message, because "the plugin silently stopped appearing" is the
failure mode this exists to replace.

### Two levels of check

| Level | Declared in | Checked against |
|---|---|---|
| Vocabulary | `manifest.contracts[].compatibleWith` | `HostConfiguration.vocabularies` |
| Per-point | `contribution.contractVersion` | the catalog entry's `accepts` |

The vocabulary check runs first, so a plugin built against the wrong generation reports
*that* rather than a cascade of per-point mismatches that all have the same cause.

## Deprecation

When you bump a major, tell the people still on the old one:

```swift
configuration.extensionPoints.register(
    CommandPoint.self,
    accepting: "1.0.0" ..< "3.0.0",
    deprecations: [
        ContractDeprecation(
            major: 1,
            since: "2.1.0",
            removedIn: "3.0.0",
            guidance: "Move `category` into the new `tags` array."
        )
    ]
)
```

A contribution on a deprecated major **still loads**, and gains a
`PluginWarning(kind: .deprecatedContract)` on its record carrying your `guidance` string
verbatim. That reaches an author through three channels:

1. `pluginkit validate --manifest plugin.json --host /Applications/YourApp.app`
2. the plugin manager UI, via `record.warnings`
3. `await manager.diagnostics.events(of: .deprecationWarning)`

**Commit to a window.** A major bump should keep the previous major working for at least two
minor releases of the vocabulary. A deprecation nobody has time to act on is just a removal
with extra steps.

> Contract *adapters* — translating an old major forward instead of dropping it — are not
> implemented yet. Today a contribution outside the accepted range is reported with both
> versions and your guidance, but cannot be automatically migrated.

## Publishing the catalog

```swift
let document = await manager.catalogDocument()
try document.encoded().write(to: resources.appendingPathComponent(
    "PluginAPI/AcmeEditorPluginAPI.catalog.json"
))
```

Write it under `Contents/Resources/PluginAPI/` and `pluginkit describe --host` finds it.
The catalog carries every point's id, contract version, accepted range, arity, locality
(with its reason), metadata shape, summary, and deprecations — plus your capabilities and
topics.

Skipping this does not break anything. It just means an author has to ask you what your
extension points are, which is the thing "the host owns the vocabulary" was supposed to
avoid.

## Design checklist

Before you publish a point and lose the ability to change it freely:

- [ ] Is the ID right? It is permanent.
- [ ] Could this be remotable? Default to yes; write down a reason if not.
- [ ] Are `Request` and `Response` genuinely `Codable`, with no reference identity assumed?
      (`PluginHarness.Transport.serializing` will tell you.)
- [ ] Does the metadata carry everything needed to draw the UI, and nothing else?
- [ ] Do new metadata fields have defaults?
- [ ] Is `.single` really right, or will the second plugin author be stuck?
- [ ] Have you declared `metadataShape` and a `summary` for `pluginkit describe`?
- [ ] Does the vocabulary group points that will genuinely version together?
