# Getting started

Integrating PluginKit into a macOS app, end to end. Roughly 30 minutes to a working
first-party plugin.

- [Install](#install)
- [1. Declare your vocabulary](#1-declare-your-vocabulary)
- [2. Declare your capabilities](#2-declare-your-capabilities)
- [3. Build the manager](#3-build-the-manager)
- [4. Read the registry](#4-read-the-registry)
- [5. Ship a first plugin](#5-ship-a-first-plugin)
- [6. Publish your vocabulary](#6-publish-your-vocabulary)
- [Verifying it works](#verifying-it-works)

## Install

**Xcode:** File → Add Package Dependencies…, then paste
`https://github.com/gumbracelet/PluginKit.git`.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/gumbracelet/PluginKit.git", from: "1.0.0")
],
```

PluginKit ships **six products**. You link different ones depending on which side of the
boundary you are on, and that separation is deliberate — see
[architecture.md](architecture.md).

| Product | Link it from | Why |
|---|---|---|
| `PluginKitCore` | your vocabulary target | The shared contract. The only product both a host and a plugin link. |
| `PluginKitHost` | your app | `PluginManager`, discovery, trust, brokering. |
| `PluginKitInProcess` | your app | The in-process runtime backend. Link only the runtimes you ship. |
| `PluginKitSDK` | a plugin | What a plugin author imports. **Never link this into an app.** |
| `PluginKitTesting` | test targets | `PluginHarness`, `HostHarness`, `PluginConformance`. |
| `pluginkit` (executable) | authors | `describe`, `validate`, `init`. |

A typical host package:

```swift
targets: [
    // Your app.
    .target(name: "AcmeEditor", dependencies: [
        .product(name: "PluginKitHost", package: "PluginKit"),
        .product(name: "PluginKitInProcess", package: "PluginKit"),
        "AcmeEditorPluginAPI",
    ]),

    // Your published vocabulary. PluginKitCore only — see step 1.
    .target(name: "AcmeEditorPluginAPI", dependencies: [
        .product(name: "PluginKitCore", package: "PluginKit"),
    ]),

    .testTarget(name: "AcmeEditorTests", dependencies: [
        "AcmeEditor",
        .product(name: "PluginKitTesting", package: "PluginKit"),
    ]),
]
```

Requirements: macOS 13+, Swift 6.0+, strict concurrency. No external dependencies.

---

## 1. Declare your vocabulary

Extension points go in **their own target**, depending on `PluginKitCore` and nothing else.

This is not tidiness. It is the artifact third-party authors compile against, and if it can
`import AcmeEditor` then your contracts will grow references to app types, and nobody
outside your team will be able to build against them. Keeping the dependency arrow pointing
one way — app → vocabulary, never the reverse — is what keeps that from happening by
accident.

```swift
// AcmeEditorPluginAPI/CommandPoint.swift
import PluginKitCore

// The wire types. Codable on both sides is what lets this contract run
// out-of-process later without a rewrite.
public struct RunCommand: Codable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct CommandResult: Codable, Sendable {
    public var didHandle: Bool
    public var message: String?
    public init(didHandle: Bool, message: String? = nil) {
        self.didHandle = didHandle
        self.message = message
    }
}

/// The contract a plugin implements. Pinning Request/Response in the `where`
/// clause is what lets `any Command` be called directly.
public protocol Command: RemotableContract
    where Request == RunCommand, Response == CommandResult {}

public enum CommandPoint: RemotableExtensionPoint {
    public typealias Contract = any Command
    public typealias Request = RunCommand
    public typealias Response = CommandResult

    /// The declarative half. Read from the manifest without loading code.
    public struct Metadata: Codable, Sendable {
        public let title: String
        public var category: String?
        public var keyEquivalent: String?
    }

    public static let extensionPointID: ExtensionPointID = "com.acme.editor.command"
    public static let vocabulary: VocabularyID = "com.acme.editor.api"
    public static let contractVersion: SemanticVersion = "1.0.0"

    /// One line per point. This is what makes location transparency mechanically
    /// true rather than merely asserted — see extension-points.md.
    public static func invoke(
        _ contract: Contract, with request: RunCommand
    ) async throws -> CommandResult {
        try await contract.handle(request)
    }
}
```

Prefer `RemotableExtensionPoint`. Use `LocalExtensionPoint` only when the contract
genuinely cannot cross a process boundary — vending live `NSView` instances, say — and
expect to write down why. [extension-points.md](extension-points.md#locality) covers the
trade.

## 2. Declare your capabilities

A capability is the **handle** a plugin receives, not a permission flag. Declare it as a
concrete type whose implementation you inject:

```swift
// AcmeEditorPluginAPI/FileReading.swift
import PluginKitCore

public struct FileReading: Capability {
    public struct Scope: CapabilityScope {
        public var roots: [String]
        public init(roots: [String]) { self.roots = roots }

        public static var unrestricted: Scope { Scope(roots: ["/"]) }

        /// Attenuation may only ever *shrink*. That monotonicity is what lets the
        /// host layer policy on top of a request without auditing this method.
        public func attenuated(to limit: Scope) -> Scope? {
            let kept = roots.filter { root in
                limit.roots.contains { root == $0 || root.hasPrefix($0) }
            }
            return kept.isEmpty ? nil : Scope(roots: kept)
        }
    }

    public static let capabilityID: CapabilityID = "fs.read"
    public static let sensitivity: CapabilitySensitivity = .sensitive

    /// The scope actually granted, so a plugin can adapt to being narrowed
    /// instead of discovering the limit as a series of failed calls.
    public let grantedRoots: [String]
    private let read: @Sendable (String) async throws -> Data

    public init(grantedRoots: [String], read: @escaping @Sendable (String) async throws -> Data) {
        self.grantedRoots = grantedRoots
        self.read = read
    }

    public func contents(of path: String) async throws -> Data { try await read(path) }
}
```

> **Why a struct and not a protocol?** `any FileReading` does not conform to `FileReading`,
> so a protocol-shaped capability could never satisfy the `C: Capability` constraint on
> `context.capability(_:)`. The concrete-handle-plus-closure shape gives you the same
> substitutability — real reader in production, stub in tests — while staying usable in a
> generic position.

## 3. Build the manager

```swift
import PluginKitHost
import PluginKitInProcess
import AcmeEditorPluginAPI

@MainActor
final class PluginController {
    let manager: PluginManager

    init() {
        manager = PluginManager(
            configuration: .standard(
                appIdentifier: "com.acme.editor",
                appVersion: SemanticVersion.fromBundle() ?? "1.0.0",
                consent: CallbackConsentStore { prompt in
                    await PermissionSheet.present(prompt)      // your UI
                }
            ) { configuration in
                // 3a. Publish the vocabulary.
                configuration.extensionPoints.register(
                    CommandPoint.self,
                    summary: "A command in the palette.",
                    metadataShape: [
                        MetadataFieldDescriptor(name: "title", type: "String"),
                        MetadataFieldDescriptor(name: "category", type: "String", required: false),
                        MetadataFieldDescriptor(name: "keyEquivalent", type: "String", required: false),
                    ]
                )

                // 3b. Say what you are willing to vend.
                configuration.capabilities.register(
                    FileReading.self,
                    summary: "Reads files inside the granted roots.",
                    scopeExample: ["roots": ["~/Documents"]]
                ) { scope, plugin in
                    FileReading(grantedRoots: scope.roots) { path in
                        try await ScopedReader(roots: scope.roots).read(path)
                    }
                }

                // 3c. Say where plugins may run.
                configuration.runtimes = [
                    InProcessPluginRuntime.registering([
                        "com.acme.editor.markdown": { MarkdownPlugin() },
                    ])
                ]

                // 3d. Topics plugins may observe.
                configuration.defaultSubscribableTopics = ["document.*"]
            }
        )
    }

    func start() async {
        await manager.start()
    }
}
```

`start()` does not throw. A launch path has to produce *some* state — an app that fails to
start because one plugin bundle is corrupt is worse than one that starts with that plugin
listed as broken. Failures land on the records and in diagnostics.

### What `.standard` gives you

| Seam | Default |
|---|---|
| Sources | machine-wide → app bundle → user → `$PLUGINKIT_DEV_PATH`, in that precedence |
| Trust | `LocationTrustPolicy` — replace with `CodeSigningTrustPolicy` before accepting third-party bundles |
| Runtime selection | `DefaultRuntimeSelector` — in-process needs `verifiedDeveloper` or better |
| Capability policy | `.promptForSensitive` |
| Consent | `DenyingConsentStore` unless you pass one |
| Settings + storage | file-backed under `~/Library/Application Support/<AppName>/PluginData` |
| Enablement | `UserDefaultsEnablementStore` |
| Safe mode | on when `PLUGINKIT_SAFE_MODE=1` |

**No runtime is included by default.** Adding one is an explicit decision, because choosing
where untrusted code runs is the most consequential choice in the framework and should not
be hidden inside a convenience initialiser.

For a headless daemon or CLI, use the same call and leave `consent` as
`DenyingConsentStore()`: there is nobody to prompt, and a store that blocked waiting for an
answer would hang the launch path. Fail closed, log, carry on.

## 4. Read the registry

```swift
// Menus and palettes — built from manifests. No plugin code is loaded here.
for handle in await manager.contributions(to: CommandPoint.self) {
    palette.add(
        title: handle.metadata.title,
        category: handle.metadata.category,
        key: handle.metadata.keyEquivalent
    ) {
        let command = try await handle.resolve()     // ← loads the plugin, here
        _ = try await command.handle(RunCommand(text: editor.selection))
    }
}
```

Handles come back ordered by the point's arity: descending `priority`, then source
precedence, then plugin ID. The order is stable across launches, because a menu whose order
depends on load order is a bug that only shows up on someone else's machine.

A plugin manager pane binds straight to the records:

```swift
for record in await manager.plugins() {
    Row(
        title: record.manifest.displayName,
        subtitle: record.trustSummary,             // honest about isolation
        state: record.phase,                       // .resolved, .active, .unsatisfied…
        problem: record.unsatisfied?.description,  // never nil-and-silent
        warnings: record.warnings,                 // deprecations, denied optionals
        cost: record.activationDuration
    )
}

try await manager.setEnabled("com.acme.editor.markdown", false)
await manager.revokeConsent(for: "com.acme.editor.markdown")
```

Observe changes with `await manager.events()`, and call
`await manager.publishLifecycle(.willTerminate)` plus `await manager.shutdown()` from
`applicationWillTerminate`.

## 5. Ship a first plugin

Start first-party and compiled in. It exercises the whole path — manifest authority,
capability brokering, lazy activation — with none of the code-signing questions.

```swift
import PluginKitSDK          // or just PluginKitCore for a compiled-in plugin
import AcmeEditorPluginAPI

actor MarkdownPlugin: Plugin {
    private var files: FileReading?

    init() {}

    func activate(_ context: any PluginContext) async throws {
        // Optional capability: degrade rather than refuse to load.
        files = await context.optionalCapability(FileReading.self)
        let reader = files

        try await context.register(CommandPoint.self, name: "render") {
            RenderCommand(files: reader)      // not called until first use
        }
    }

    func deactivate() async {
        files = nil                            // must be idempotent
    }

    func healthCheck() async -> PluginHealth {
        files == nil ? .degraded(reason: "No file access; rendering the selection only.") : .ok
    }
}

struct RenderCommand: Command {
    let files: FileReading?

    func handle(_ request: RunCommand) async throws -> CommandResult {
        CommandResult(didHandle: true, message: "Rendered \(request.text.count) characters.")
    }
}
```

Its manifest, in a `RegisteredPluginSource` or as `plugin.json` in a bundle:

```swift
let manifest = PluginManifest(
    id: "com.acme.editor.markdown",
    version: "1.0.0",
    displayName: "Markdown Tools",
    sdkVersion: .compatible(with: PluginKitVersion.current),
    contracts: [
        ContractDependency(vocabulary: CommandPoint.vocabulary, builtAgainst: "1.0.0")
    ],
    capabilities: [
        CapabilityRequest(
            id: "fs.read",
            scope: ["roots": ["~/Documents"]],
            required: false,
            reason: "Reads the open file to render a preview."
        )
    ],
    contributions: [
        Contribution(
            extensionPoint: CommandPoint.extensionPointID,
            name: "render",
            contractVersion: "1.0.0",
            priority: 10,
            metadata: ["title": "Render Markdown", "category": "Text"]
        )
    ]
)
```

Add it to the manager's sources:

```swift
configuration.sources.insert(
    RegisteredPluginSource(trustHint: .firstParty, manifests: [manifest]),
    at: 0
)
```

Loading third-party bundles from disk is
[plugin-development.md](plugin-development.md#shipping-as-a-loadable-bundle) plus
[distribution.md](distribution.md#code-signing-and-trust).

## 6. Publish your vocabulary

So authors can target your app without your source, write the catalog into your bundle:

```swift
// Once, in a build step or on first launch in a debug build.
let document = await manager.catalogDocument()
try document.encoded().write(
    to: bundleResources
        .appendingPathComponent("PluginAPI/AcmeEditorPluginAPI.catalog.json")
)
```

Then anyone can run:

```console
$ pluginkit describe --host /Applications/AcmeEditor.app
$ pluginkit init --id com.me.wordcount --point com.acme.editor.command \
                 --host /Applications/AcmeEditor.app
$ pluginkit validate --manifest plugin.json --host /Applications/AcmeEditor.app
```

Skip this and "the host owns the vocabulary" quietly becomes "ask the host's developer".

---

## Verifying it works

Four checks that confirm the parts that are easy to get subtly wrong:

```swift
import Testing
import PluginKitTesting

@Test("Listing contributions loads nothing")
func laziness() async {
    let counter = InstantiationCounter()
    let manager = HostHarness.manager(
        plugins: [(manifest, counter.tracking(manifest.id) { MarkdownPlugin() })]
    ) { $0.extensionPoints.register(CommandPoint.self) }

    await manager.start()
    _ = await manager.contributions(to: CommandPoint.self)
    #expect(counter.total == 0)                  // ← the whole design, in one assertion
}
```

```swift
@Test("The plugin is sound")
func conformance() async {
    let findings = await PluginConformance(manifest: manifest, makePlugin: { MarkdownPlugin() })
        .granting { harness in
            await harness.grant(FileReading.self) { scope, _ in
                FileReading(grantedRoots: scope.roots) { _ in Data() }
            }
        }
        .run()
    #expect(findings.isEmpty, "\(findings)")
}
```

Then, at runtime:

- **`await manager.plugins()`** — every plugin should be `.resolved`, and anything
  `.unsatisfied` carries a reason that says what to fix.
- **`await manager.diagnostics.activationCosts()`** — what each plugin costs at launch.

If something is `.unsatisfied` or `.rejected` and the reason is not obvious,
[troubleshooting.md](troubleshooting.md) indexes them by symptom.

## Where to go next

- [Extension points](extension-points.md) — designing a vocabulary that survives version 2.
- [Capabilities and trust](capabilities.md) — before you accept a third-party plugin.
- [Plugin development](plugin-development.md) — hand this to your plugin authors.
- [Lifecycle](lifecycle.md) — what each phase means and when things load.
