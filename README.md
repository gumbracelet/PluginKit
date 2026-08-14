<p align="center">
  <img src="docs/images/hero.svg" alt="PluginKit" width="820">
</p>

<p align="center">
  <a href="#requirements"><img src="https://img.shields.io/badge/platform-macOS%2013%2B-0a0a0c?style=flat-square" alt="macOS 13+"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/swift-6.0%2B-f05138?style=flat-square" alt="Swift 6.0+"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/dependencies-none-3da639?style=flat-square" alt="No dependencies"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/concurrency-strict-4a90d9?style=flat-square" alt="Swift 6 strict concurrency"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3da639?style=flat-square" alt="MIT"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#writing-a-plugin">Writing a plugin</a> ·
  <a href="#capabilities-and-trust">Capabilities</a> ·
  <a href="#testing">Testing</a> ·
</p>

---

**PluginKit** is a plugin foundation for macOS apps. It handles declaration, discovery,
versioning, ordering, permission brokering, and lazy loading — and knows nothing at all
about what your app does.

It is built around one rule, and everything else follows from it:

> **Everything the host needs in order to *decide* is declarative data, readable
> without loading or running plugin code.**

A host with sixty installed plugins boots with sixty **resolved** and **zero loaded**. It
builds its whole command palette, its settings panes, and its permission list from
manifests, then loads a plugin the first time someone actually uses it. A plugin the user
never invokes never executes.

The second rule is what makes it adaptable: **the host owns the vocabulary.** PluginKit
ships zero domain extension points. Your app declares its own — commands, exporters,
inspectors, linters, whatever it really has — in a small package plugin authors compile
against. The framework provides the machinery and never learns a domain concept.

```swift
// The entire host-side integration for a command palette. No plugin code is loaded.
for handle in await manager.contributions(to: CommandPoint.self) {
    palette.add(title: handle.metadata.title, category: handle.metadata.category) {
        let command = try await handle.resolve()          // ← loads here, on click
        _ = try await command.handle(RunCommand(text: editor.selection))
    }
}
```

## What it does

- **Manifest-first discovery** — validate identity, dependencies, contract versions,
  metadata shape, and requested permissions before any code exists in the process
- **Typed extension points** you declare, with arity, ordering, and per-point versioning
- **Lazy activation**, memoised, deduplicated across concurrent callers
- **Capability brokering** with scope attenuation, layered policy, and user consent
- **Trust evaluation** from code signature, team ID, quarantine, and framework linkage
- **Pluggable runtimes** behind one interface, so isolation is a deployment choice
- **Layered configuration** (session → managed → user → bundled → default) with MDM locks
- **Authoring tools** — a `pluginkit` CLI, a plugin-side test harness, a conformance suite

## Package structure

Three layers, and the separation is the product:

```
                     ┌──────────────────────┐
                     │    PluginKitCore     │   Layer 0 — the shared contract
                     │  manifest · points   │   Pure types + protocol seams.
                     │  capabilities · errs │   No I/O, no AppKit, no discovery.
                     └──────────┬───────────┘
                     ┌──────────┴───────────┐
                     ▼                      ▼
          ┌────────────────────┐  ┌────────────────────┐
          │   PluginKitSDK     │  │   PluginKitHost    │   Layer 1 — the two consumers
          │  what a *plugin*   │  │  what an *app*     │   Siblings. Neither depends
          │  imports           │  │  imports           │   on the other.
          └────────────────────┘  └─────────┬──────────┘
                                            ▼
                                 ┌────────────────────┐
                                 │ PluginKitInProcess │   Layer 2 — runtime backends
                                 └────────────────────┘   Link only what you ship.
```

| Target | Who links it | Contains |
|---|---|---|
| `PluginKitCore` | **both** | `PluginManifest`, `ExtensionPoint`, `Plugin`, `PluginContext`, `Capability`, `JSONValue`, `SemanticVersion`, errors |
| `PluginKitSDK` | plugin | `PluginPrincipal`, `PluginManifestBuilder`, context conveniences, drift types |
| `PluginKitHost` | app | `PluginManager`, discovery, trust, catalog, brokers, config and storage |
| `PluginKitInProcess` | app | `InProcessPluginRuntime` |
| `PluginKitTesting` | tests | `PluginHarness`, `HostHarness`, `PluginConformance` |
| `pluginkit` | authors | `describe`, `validate`, `init` |

**Why this shape, concretely.**

- **No duplicate code, no duplicate builds.** `PluginKitCore` is the *only* target in both
  a host's and a plugin's dependency graph. There is one definition of a manifest and one
  build of it, so the two sides cannot drift.
- **No duplicate weight.** A shipping app never links the authoring tooling, and a plugin
  never links discovery, trust evaluation, or brokering — none of which it may perform for
  itself anyway. The security boundary and the size boundary are the same line.
- **Fast incremental builds.** Core has no dependencies and no I/O; editing the manager
  cannot trigger a plugin rebuild, because nothing a plugin links can see the manager.
- **Extension without breaking.** New runtimes arrive as new targets (Layer 2). New
  discovery, trust, consent, config, or storage behaviour arrives as a conformance to an
  existing protocol. Neither touches Core, which is the only surface with a permanent
  commitment attached.

## Requirements

macOS 13+, Swift 6.0+, strict concurrency (`swiftLanguageModes: [.v6]`), zero external
dependencies.

macOS-only by design. The trust model, the runtime backends, and the filesystem
conventions have no meaningful analogue elsewhere, and pretending otherwise would produce
a lowest-common-denominator API.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/you/PluginKit.git", from: "0.1.0")
],
targets: [
    // Your app
    .target(name: "YourApp", dependencies: [
        .product(name: "PluginKitHost", package: "PluginKit"),
        .product(name: "PluginKitInProcess", package: "PluginKit"),
        "YourAppPluginAPI",
    ]),
    // Your published vocabulary — see below
    .target(name: "YourAppPluginAPI", dependencies: [
        .product(name: "PluginKitCore", package: "PluginKit"),
    ]),
]
```

---

# Quick start

## 1. Declare your vocabulary

Extension points live in **their own target**, depending on `PluginKitCore` and nothing
else. This is the artifact you publish and third-party authors compile against. If it can
import your app, contracts leak app types and nobody outside your team can build against
them.

```swift
// YourAppPluginAPI/CommandPoint.swift
import PluginKitCore

public struct RunCommand: Codable, Sendable { public var text: String }
public struct CommandResult: Codable, Sendable { public var wordCount: Int }

/// The recommended contract shape: one `handle`, both sides `Codable`.
public protocol Command: RemotableContract
    where Request == RunCommand, Response == CommandResult {}

public enum CommandPoint: RemotableExtensionPoint {
    public typealias Contract = any Command
    public typealias Request = RunCommand
    public typealias Response = CommandResult

    public struct Metadata: Codable, Sendable {
        public let title: String
        public var category: String?
    }

    public static let extensionPointID: ExtensionPointID = "com.acme.editor.command"
    public static let vocabulary: VocabularyID = "com.acme.editor.api"
    public static let contractVersion: SemanticVersion = "1.0.0"

    /// The one-line shim that makes location transparency mechanically true.
    public static func invoke(
        _ contract: Contract, with request: RunCommand
    ) async throws -> CommandResult {
        try await contract.handle(request)
    }
}
```

## 2. Wire up the host

```swift
import PluginKitHost
import PluginKitInProcess
import YourAppPluginAPI

let manager = PluginManager(
    configuration: .standard(
        appIdentifier: "com.acme.editor",
        appVersion: "3.2.0",
        consent: CallbackConsentStore { prompt in
            await PermissionSheet.present(prompt)      // your UI
        }
    ) { configuration in
        configuration.extensionPoints.register(
            CommandPoint.self,
            summary: "A command in the palette.",
            metadataShape: [
                MetadataFieldDescriptor(name: "title", type: "String"),
                MetadataFieldDescriptor(name: "category", type: "String", required: false),
            ]
        )

        configuration.capabilities.register(FileReading.self) { scope, plugin in
            FileReading(grantedRoots: scope.roots) { path in
                try await SandboxedReader(roots: scope.roots).read(path)
            }
        }

        configuration.runtimes = [
            InProcessPluginRuntime.registering([
                "com.acme.editor.markdown": { MarkdownPlugin() },   // first-party
            ])
        ]
    }
)

try await manager.start()
```

`.standard` supplies machine-wide, built-in, user, and development plugin directories in
descending precedence; code-signing-ready trust; file-backed settings and storage;
`UserDefaults` enablement; and a prompt-for-sensitive capability policy. Every one of those
is a named property you can replace.

> **No runtime is included by default.** A host adds one explicitly, because choosing where
> untrusted code runs is the most consequential decision in the framework and should not be
> hidden behind a convenience initialiser.

## 3. Read the registry

```swift
// Menus, palettes, and settings panes — all from manifests, nothing loaded.
for handle in await manager.contributions(to: CommandPoint.self) {
    palette.add(handle.metadata.title) {
        _ = try await handle.resolve().handle(RunCommand(text: selection))
    }
}

// A plugin manager pane binds straight to the records.
for record in await manager.plugins() {
    row(record.manifest.displayName,
        subtitle: record.trustSummary,                 // honest about isolation
        state: record.phase,
        problem: record.unsatisfied?.description,      // never silent
        warnings: record.warnings)
}
try await manager.setEnabled("com.acme.editor.markdown", false)
```

---

# Writing a plugin

## The plugin

```swift
import PluginKitSDK
import YourAppPluginAPI

actor MarkdownPlugin: Plugin {
    private var files: FileReading?

    init() {}

    func activate(_ context: any PluginContext) async throws {
        // Optional capability: degrade instead of refusing to load.
        files = await context.optionalCapability(FileReading.self)
        let reader = files

        try await context.register(CommandPoint.self, name: "count") {
            CountCommand(files: reader)          // not called until first use
        }
    }

    func deactivate() async {
        files = nil                              // must be idempotent
    }

    func healthCheck() async -> PluginHealth {
        files == nil ? .degraded(reason: "No file access; counting the selection only.") : .ok
    }
}

struct CountCommand: Command {
    let files: FileReading?

    func handle(_ request: RunCommand) async throws -> CommandResult {
        CommandResult(wordCount: request.text.split(whereSeparator: \.isWhitespace).count)
    }
}
```

Prefer an `actor`. A plugin is called from the host's concurrency domain at times it does
not choose — a menu click, a background refresh, a deactivation on quit — and an actor
removes that whole class of race rather than documenting a locking discipline nobody
follows.

## The manifest

`plugin.json`, inside the bundle at `Contents/Resources/`:

```json
{
  "id": "com.acme.editor.markdown",
  "version": "1.0.0",
  "displayName": "Markdown Tools",
  "summary": "Word counts and preview for Markdown.",
  "sdkVersion": ">=0.1.0 <0.2.0",
  "contracts": [
    { "vocabulary": "com.acme.editor.api",
      "builtAgainst": "1.0.0", "compatibleWith": ">=1.0.0 <2.0.0" }
  ],
  "runtime": { "kind": "inProcess" },
  "activation": { "kind": "onDemand" },
  "capabilities": [
    { "id": "fs.read", "required": false,
      "reason": "Counts words in the open file.",
      "scope": { "roots": ["~/Documents"] } }
  ],
  "contributions": [
    { "extensionPoint": "com.acme.editor.command", "name": "count",
      "contractVersion": "1.0.0", "priority": 10,
      "metadata": { "title": "Count Words", "category": "Text" } }
  ]
}
```

Every optional key has a defensible default, so the shortest useful manifest is three
lines. `PluginManifestBuilder` will generate this from Swift if you would rather treat code
as the authoring source of truth.

## Shipping as a loadable bundle

Set `NSPrincipalClass` in `Info.plist` and subclass `PluginPrincipal`:

```swift
@objc(MarkdownEntry)
final class MarkdownEntry: PluginPrincipal {
    override class func makePlugin() -> any Plugin { MarkdownPlugin() }

    /// Read by the host *before* `makePlugin()`, and cross-checked against the
    /// manifest. The manifest is a file an author can edit without recompiling;
    /// the binary's answer is not.
    override class func contractVersions() -> [String: String] {
        ["com.acme.editor.api": "1.0.0"]
    }
}
```

## Discovering a host's vocabulary

You do not need the host's source. `pluginkit describe` reads the catalog out of an
**installed** app:

```console
$ pluginkit describe --host /Applications/Acme.app
com.acme.editor 3.2.0  ·  PluginKit 0.1.0

VOCABULARIES
  com.acme.editor.api  1.2.0   accepts >=1.0.0 <2.0.0

EXTENSION POINTS
  com.acme.editor.command
      contract 1.2.0   accepts >=1.0.0 <2.0.0   remotable   many(priority)
      A command in the palette.
      metadata: title: String, category: String?
      ⚠ contract 1.x deprecated since 1.2.0, removed in 2.0.0
        Use tags instead of category.
  com.acme.editor.inspector
      contract 1.0.0   accepts >=1.0.0 <2.0.0   LOCAL-ONLY   single
      ⚠ in-process only — Vends live view objects.

CAPABILITIES
  fs.read  [sensitive]
      Reads files inside the granted roots.
      scope e.g. {"roots":["~/Documents"]}
```

A host emits that file with `await manager.catalogDocument()` and writes it into
`Contents/Resources/PluginAPI/`. Then:

```console
$ pluginkit init --id com.me.wordcount --point com.acme.editor.command \
                 --host /Applications/Acme.app
$ pluginkit validate --manifest plugin.json --host /Applications/Acme.app
```

`validate` exits non-zero on a problem, so it can gate a build. It never loads plugin code.

---

# Architecture

## Extension points and locality

The rich-protocol-versus-serializable question is answered by the *type system*, so an
author is never guessing:

| | Hostable in | Declare as |
|---|---|---|
| **Remotable** (default) | in-process, XPC, app extension, script | `RemotableExtensionPoint` |
| **Local** (opt-out) | in-process only | `LocalExtensionPoint` + a written `localityReason` |

Remotability is a `Request`/`Response` pair plus an `invoke` shim rather than a constraint
on `Contract`. The mechanical reason is that `Contract` is normally an existential
(`any Command`), and `any P` does not conform to `P`, so `where Contract: RemotableContract`
cannot be written. The better reason is that `invoke` gives the framework a **uniform way
to actually call** any remotable contract — which is what a transport needs. A marker
constraint would only have labelled the point; this makes location transparency
mechanically true, and it is exactly what the serializing test transport uses.

Contributing to a local point costs something: such a plugin can never be isolated, so one
whose trust level forbids in-process hosting is reported `unsatisfied` rather than loaded.
The friction is deliberate — the escape hatch should be visible.

## Lifecycle

```
discovered → validated → resolved → loading → active → inactive → (unloaded)
     ↓            ↓          ↓          ↓        ↓                     ↓
 rejected    unsatisfied  ◄steady►   failed   failed            quarantined
```

- **`resolved` is the steady state.** Contributions are queryable here. No code is loaded.
- **`unsatisfied` is never silent.** Every entry carries a structured reason — missing
  dependency, denied required capability, contract version out of range, locality violation,
  no runtime available — surfaced on the record and in diagnostics.
- **Failures are contained.** `resolve()` throws, the host skips that contribution and logs.
  One row goes red; the app keeps working.
- **Crash budget.** Repeated failures quarantine a plugin, so one bad plugin cannot make the
  app feel permanently broken.
- **Deactivation has a deadline** (2s default). An overrun is *abandoned in place*, never
  unloaded: an in-process plugin's objects may still be reachable from the host, so
  reclaiming its code would turn a hang into a crash.
- **Safe mode** (`PLUGINKIT_SAFE_MODE=1`) discovers everything and loads nothing.

## Capabilities and trust

Three concepts, kept deliberately distinct:

| | What it is | Who decides | Enforced by |
|---|---|---|---|
| **Capability** | a typed, scoped grant to a host service | host policy + manifest | broker (+ sandbox, out-of-process) |
| **Consent** | user approval for a sensitive capability | the user, persisted | `ConsentStore` |
| **OS permission** | TCC: camera, contacts, full disk | the user, via macOS | the OS, against the *host* |

Capabilities are never vended raw. Not "filesystem access" but
`FileReading.Scope(roots: ["/tmp"])`, and `attenuated(to:)` may only ever **shrink**.
Policy resolves **managed → per-plugin → per-capability → per-sensitivity → default**, first
match wins, defaulting to denial. Managed rulings cannot be overridden by anything, which is
what makes a fleet deployment enforceable rather than advisory.

Declare a capability as a **concrete handle with an injected implementation**, not a
protocol — `any FileReading` would not conform to `FileReading`, so it could never satisfy
the generic constraint:

```swift
public struct FileReading: Capability {
    public struct Scope: CapabilityScope {
        public var roots: [String]
        public static var unrestricted: Scope { Scope(roots: ["/"]) }
        public func attenuated(to limit: Scope) -> Scope? { /* intersect, nil if empty */ }
    }
    public static let capabilityID: CapabilityID = "fs.read"
    public static let sensitivity: CapabilitySensitivity = .sensitive

    private let read: @Sendable (String) async throws -> String
    public func contents(of path: String) async throws -> String { try await read(path) }
}
```

### The honest part

**In-process, a capability is policy and disclosure — not a security boundary.** Native code
sharing an address space with the host can call `FileManager` directly and ignore the broker
entirely. Pretending otherwise would be the most dangerous claim this framework could make.

So a capability plays two roles depending on runtime:

- **Every runtime** — a reviewable, auditable, revocable *disclosure* contract.
- **Out-of-process only** — real enforcement, because the child's sandbox profile is derived
  from the granted set and the broker is the only channel out.

`PluginRecord.trustSummary` reflects which one the user is getting. An in-process plugin
reads *"full app access, not sandboxed"*, not a permission list that implies containment.

### Trust levels

`sandboxedOnly < verifiedDeveloper < firstParty`. `CodeSigningTrustPolicy` checks the
signature, the team ID against a pin list, quarantine, and — the check people skip — whether
the bundle embeds its own copy of a framework the host already provides. Two copies of the
same contract types in one address space make `as?` fail across the seam while every version
number involved looks correct: days to diagnose in the field, nothing to refuse up front.

## Manifest authority

**A plugin cannot contribute to, request, or publish anything it did not declare.** Not
"warn and allow" — refuse:

```swift
try await context.register(CommandPoint.self, name: "undeclared") { … }
// throws ExtensionPointError.contributionNotFound

let net = try await context.capability(NetworkAccess.self)
// throws CapabilityError.undeclared, before policy is even consulted
```

This is a drift check for the honest case and a containment boundary for the dishonest one:
a plugin that could register past its own disclosure could contribute past the list a user
approved.

## Communication model

Four channels. **None of them is plugin-to-plugin direct.**

1. **Host → plugin** — extension point invocation via `ExtensionHandle.resolve()`.
2. **Plugin → host** — brokered capability handles from `PluginContext`.
3. **Broadcast** — `EventBus`, per-topic ACLs (`"document.*"`), bounded per-subscriber
   buffers that drop oldest. Best-effort by design: a slow subscriber must never stall a
   publisher, and the publisher is usually the host's main actor.
4. **Plugin ↔ plugin** — `context.service(_:)`, host-brokered. The consumer gets a proxy and
   the provider is activated on demand. So the provider stays swappable, the wiring stays
   subject to policy, and a provider failure arrives as a thrown error rather than a cascade.

Dependency cycles are refused rather than ordered arbitrarily — picking an order means
picking which plugin sees a half-initialised peer, and there is no right answer to that. A
service cycle is caught by a task-local activation chain rather than deadlocking.

## Configuration

Three storage classes, kept separate because conflating them causes two specific bugs —
window positions syncing between machines, and access tokens ending up in a plist:

| Class | Store | Synced | Schema |
|---|---|---|---|
| **Settings** | plist in the plugin container | yes | required |
| **State** | plugin container | no | none |
| **Secrets** | Keychain | via Keychain | n/a |

Resolution: `session → managed → user → bundled → schemaDefault`.

**Reads never throw; writes do.** A configuration read sits on the activation path, so a
corrupt preferences file must not be able to stop a plugin loading — it produces the default
and a diagnostic. A locked or invalid *write* is a real condition with a user action behind
it, so that side throws. `isLocked(_:)` lets a settings UI show a lock badge instead of a
control the user cannot actually change.

The declared schema means a host can render a plugin's settings pane **without loading its
code** — the same win as declarative contribution metadata.

---

# Testing

## Plugin-side: `PluginHarness`

A plugin author has no host app to test against and cannot attach a debugger to a shipped
one. The harness is built from the *real* `HostPluginContext`, the real broker, and the real
layered store — a hand-written fake would drift from the host and then confidently report a
passing test.

```swift
let harness = PluginHarness(manifest: manifest)
await harness.grant(FileReading.self) { scope, _ in
    FileReading(grantedRoots: scope.roots) { _ in "one two three" }
}
await harness.deny("net.http")
await harness.limit("fs.read", to: ["roots": ["/tmp"]])

try await harness.activate(MarkdownPlugin())

let result = try await harness.invoke(CommandPoint.self, name: "count",
                                      RunCommand(text: "alpha beta"))
#expect(result.wordCount == 2)
#expect(await harness.drift().isEmpty)
```

### The transport that earns its keep

```swift
PluginHarness(manifest: manifest, transport: .serializing)
```

Every request and response crosses a JSON round-trip first. It catches the assumptions that
make a contract quietly un-remotable — a reference type smuggled through, a `Codable` that
does not round-trip, an identity comparison that survives in-process and breaks over XPC —
with none of the setup an actual out-of-process test needs. Get this green in CI and moving
a plugin behind an isolation boundary later stops being a surprise.

### Drift detection, today

Generating a manifest from code needs macro machinery. *Detecting drift* needs none:
activate the plugin, record what it registers and requests, diff against `plugin.json`.

```swift
#expect(await harness.drift() == [])
// .registeredButNotDeclared(point:name:)     ← fatal; the host refuses it at runtime
// .capabilityUsedButNotDeclared(_)           ← fatal, same reason
// .declaredButNotRegistered(point:name:)     ← a menu item that throws when clicked
// .capabilityDeclaredButUnused(_)            ← inflates the list a user is asked to approve
```

So the invariant holds from v0.1, and the later tooling becomes an ergonomic upgrade rather
than the thing propping it up.

## `PluginConformance`

The invariants a host relies on and an author has no natural reason to test, because each
only matters in a situation the author does not reproduce locally:

```swift
let findings = await PluginConformance(manifest: manifest, makePlugin: { MarkdownPlugin() })
    .granting { harness in
        await harness.grant(FileReading.self) { scope, _ in StubReader(scope) }
    }
    .run()

#expect(findings.isEmpty, "\(findings)")
```

Checks: the manifest is structurally valid; activation succeeds with everything granted;
activation still succeeds with **every optional capability denied** (the failure users
actually hit — they decline one prompt and the plugin stops loading); activation **fails**
when a required capability is denied; `deactivate()` is idempotent across three calls and
finishes inside the budget; and no fatal manifest drift.

## Host-side: `HostHarness`

```swift
let counter = InstantiationCounter()
let manager = HostHarness.manager(
    plugins: [(manifest, counter.tracking(manifest.id) { MarkdownPlugin() })],
    trust: .sandboxedOnly                    // drive the refusal paths
) { configuration in
    configuration.extensionPoints.register(CommandPoint.self)
}
await manager.start()

#expect(counter.total == 0)                  // listed, not loaded
```

Everything is real except where plugins come from and where their data goes.

---

# Binary compatibility

Two constraints worth stating plainly, because they decide what a given app can ship.

**Library validation.** With the hardened runtime enabled, a host can only load code signed
by its own team unless it carries `com.apple.security.cs.disable-library-validation` — an
entitlement that is not realistically approvable for the App Store. So *App Store +
third-party native plugins ⇒ app extension or script runtime.* There is no third option.
`InProcessPluginRuntime(loadsBundles: false)` is the honest setting for a host in that
position.

**Swift module stability.** A plugin compiled by a different toolchain than the host is only
safe if the shared contract modules are built with library evolution. `PluginKitCore` and
`PluginKitSDK` are the only targets on that boundary, and CI builds both with
`-enable-library-evolution` on every change. Evolution mode is not set in `Package.swift`,
because `.unsafeFlags` would make the package unusable as a git dependency; the distribution
build passes the flag instead.

Your own contract package should ship as a **dynamic framework embedded in the host app** —
one copy, ever — with plugins linking `@executable_path/../Frameworks` and *not* embedding
it. That path resolves against the host executable, so it works identically for plugins
inside `Contents/PlugIns` and for user-installed plugins anywhere on disk.
`CodeSigningTrustPolicy(hostProvidedFrameworks:)` blocks a bundle that embeds a duplicate.

---

# Source map

| Area | Where |
|---|---|
| Manifest, contributions, capability requests | `Core/Model/PluginManifest.swift`, `Contribution.swift` |
| Extension points, locality, remotability | `Core/Contracts/ExtensionPoint.swift` |
| `Plugin`, `PluginContext`, `HostInfo` | `Core/Contracts/Plugin.swift` |
| Host service seams (config, storage, events, consent) | `Core/Contracts/HostServices.swift` |
| The error surface | `Core/Support/Errors.swift` |
| Vocabulary catalog for authors | `Core/Model/CatalogDocument.swift` |
| Orchestration and the lifecycle state machine | `Host/PluginManager.swift` |
| Composition root | `Host/HostConfiguration.swift` |
| Contract-version acceptance, metadata validation | `Host/Registry/ExtensionPointCatalog.swift` |
| Discovery and trust | `Host/Discovery/` |
| Brokering, policy, consent | `Host/Capabilities/` |
| Manifest authority enforcement | `Host/Lifecycle/ContributionRegistrar.swift` |
| Runtime and selector seams | `Host/Runtime/PluginRuntime.swift` |

**Where a change belongs.** A new domain concept → your vocabulary target, never PluginKit.
A new place plugins come from → a `PluginSource`. A new isolation model → a `PluginRuntime`
in its own target. A new permission → a `Capability` plus a registry entry. A new trust
rule → a `TrustPolicy`. If a change seems to require editing `PluginKitCore`, that is worth a
second look: Core is the only surface with a permanent compatibility commitment attached.

---

# Honest limits

What this version does **not** do, stated plainly rather than discovered later:

- **Only one runtime ships** (`InProcessPluginRuntime`). Until an isolating runtime exists,
  a `sandboxedOnly` plugin is reported `unsatisfied` with a readable reason rather than
  quietly given full authority. A host can opt out with
  `DefaultRuntimeSelector(allowsUnisolatedFallback: true)`, and the plugin is then flagged
  `.unisolated` in its record.
- **No XPC, app-extension, or script runtime yet.** The seams they need are in place and the
  `.serializing` test transport already proves contracts can survive the boundary.
- **No contract adapters.** A contribution outside the accepted version range is reported
  with both versions and the host's own guidance string, but cannot yet be *translated*
  forward.
- **No macros.** `plugin.json` is hand-written or generated by `PluginManifestBuilder`, and
  drift is caught by `PluginHarness.drift()` rather than made impossible.
- **No UI module.** `PluginRecord` carries everything a manager pane needs
  (phase, trust summary, warnings, unsatisfied reason, activation cost); drawing it is yours.
- **No marketplace, no install/uninstall flow, no production hot reload.** Deliberate
  anti-goals, not omissions.
- **Cross-launch upgrade detection** relies on a marker in the plugin's own container, so a
  host that swaps out `PluginStorageFactory` for something non-persistent loses
  `willUpgrade(from:)`.

## What to build next

1. **`PluginKitXPC`** — the runtime that turns capability grants from policy into
   enforcement. Everything else is already shaped for it.
2. **`ContributionAdapter`** — translate an old contract major forward instead of dropping it.
3. **`PluginKitUI`** — the manager pane and consent sheet, so every host stops rewriting them.
4. **Macros** — `#PluginEntry` and manifest generation, once the hand-written path has been
   used enough to know what it should generate.

Before any of that, the gate worth insisting on: build **two structurally different hosts** on
this foundation — a document-based GUI app and a headless daemon — plus **one plugin written
by someone with no access to either host's source, using only `pluginkit describe`**. The
first two test the host API. Only the third tests whether the authoring story actually works.

## License

PluginKit is released under the [MIT License](LICENSE).
