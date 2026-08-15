# Architecture

Why the package is split the way it is, what each seam is for, and where a change belongs.

- [1. The central idea](#1-the-central-idea)
- [2. Layering](#2-layering)
- [3. The seams](#3-the-seams)
- [4. What crosses the boundary](#4-what-crosses-the-boundary)
- [5. Manifest authority](#5-manifest-authority)
- [6. Concurrency](#6-concurrency)
- [7. Testability](#7-testability)
- [8. Source map](#8-source-map)
- [9. Where a change belongs](#9-where-a-change-belongs)

## 1. The central idea

> **The host decides from data, not from code.**

Identity, dependencies, contract versions, contribution metadata, configuration schema, and
every permission a plugin will ever request live in `plugin.json`. All of it is parsed,
cross-checked against the host's own catalog, and resolved before a single byte of plugin
code is mapped into the process.

That is not tidiness — it is the mechanism behind four things at once:

- **Launch cost.** Sixty installed plugins cost sixty small JSON reads, not sixty `dlopen`s.
- **Reviewable permissions.** A user or an administrator can read the complete list of what
  a plugin will ever ask for, before installing it.
- **Working UI for broken plugins.** A plugin that cannot run is still listed, with a
  reason, because listing never required running it.
- **Containment.** The manifest is a published disclosure the runtime then enforces, so a
  plugin cannot reach past what it declared.

The alternative is the shape most plugin systems drift into: load everything at launch to
find out what is there, discover a plugin is broken by crashing, and describe permissions in
documentation that the code does not enforce.

## 2. Layering

```
                     ┌──────────────────────┐
                     │    PluginKitCore     │   Layer 0 — the shared contract
                     └──────────┬───────────┘
                     ┌──────────┴───────────┐
                     ▼                      ▼
          ┌────────────────────┐  ┌────────────────────┐
          │   PluginKitSDK     │  │   PluginKitHost    │   Layer 1 — the two consumers
          └────────────────────┘  └─────────┬──────────┘
                                            ▼
                                 ┌────────────────────┐
                                 │ PluginKitInProcess │   Layer 2 — runtime backends
                                 └────────────────────┘
                                            ▼
                                 ┌────────────────────┐
                                 │  PluginKitTesting  │   Layer 3 — harnesses
                                 └────────────────────┘
```

**Layer 0 — `PluginKitCore`.** Pure domain types plus the protocol seams a host implements
and a plugin consumes. No discovery, no loading, no brokering, no AppKit. This is the
**only** target that appears in both a host's and a plugin's dependency graph.

**Layer 1 — `PluginKitSDK` and `PluginKitHost`.** Deliberately siblings: neither depends on
the other, and CI would catch it if that changed.

**Layer 2 — runtime backends.** Each knows Core (to speak the contract) and Host (to
conform to `PluginRuntime`), never the SDK.

**Layer 3 — `PluginKitTesting`.** The one place that legitimately sees every layer, because
it fakes whichever side is not under test.

### Why the sibling split matters

Four things follow from Host and SDK not depending on each other:

1. **One definition, one build.** There is exactly one `PluginManifest` type and one
   compilation of it. A host and a plugin cannot disagree about what a manifest is, because
   there is nothing to disagree with.

2. **No duplicate weight.** A shipping app never links manifest-authoring tooling. A plugin
   never links discovery, trust evaluation, or brokering — none of which it may perform for
   itself anyway. **The security boundary and the size boundary are the same line**, which
   is why neither can drift without the other being noticed.

3. **Fast incremental builds.** Core has no dependencies and no I/O. Editing `PluginManager`
   cannot trigger a plugin rebuild, because nothing a plugin links can see the manager.

4. **Extension without breaking.** A new runtime is a new Layer 2 target. New discovery,
   trust, consent, configuration, or storage behaviour is a conformance to an existing
   protocol. Neither touches Core — the only surface carrying a permanent compatibility
   commitment.

### The one-directional rule

```
app  →  your vocabulary package  →  PluginKitCore
```

Your vocabulary package must not import your app. If it can, contracts grow references to
app types, and third-party authors cannot compile against them. This is the single most
common way a plugin system stops being usable by outsiders, and it happens by accident.

## 3. The seams

Every one of these is a protocol with at least one shipped implementation. Replacing one is
how PluginKit adapts to an app whose shape it did not anticipate.

| Seam | Question it answers | Shipped |
|---|---|---|
| `PluginSource` | Where do plugins come from? | `DirectoryPluginSource`, `RegisteredPluginSource` |
| `TrustPolicy` | How much is this one trusted? | `LocationTrustPolicy`, `CodeSigningTrustPolicy` |
| `PluginRuntime` | Where does its code run? | `InProcessPluginRuntime` |
| `RuntimeSelector` | Which runtime is it *allowed* to use? | `DefaultRuntimeSelector` |
| `CapabilityBroker` | May it have this? | `PolicyCapabilityBroker` |
| `ConsentStore` | What did the user say? | `Denying`, `Allowing`, `Callback`, `InMemory` |
| `ConfigurationStoreFactory` | Where do its settings live? | `File`, `InMemory` |
| `PluginStorageFactory` | Where does its data live? | `FileSystem`, `InMemory` |
| `PluginEnablementStore` | Is it turned on? | `UserDefaults`, `InMemory` |
| `PluginLogging` | Where does its output go? | `Silent`, `Callback` |

Two of those pairs are worth explaining, because splitting them is not obvious.

**`PluginRuntime` vs `RuntimeSelector`.** *What backends exist* and *which one a given
plugin may use* are different decisions with different owners. The first is what your app
shipped; the second is policy. Fusing them would mean a host that adds an XPC runtime
silently changes where every existing plugin runs.

**`TrustPolicy` vs `CapabilityBroker`.** Trust is about the code's provenance and is decided
once, before loading. Capability is about a specific request and is decided per grant, with
the user possibly involved. A plugin can be highly trusted and still be denied contacts.

**`PluginSource` + `PluginRuntime` together** are the migration path. A host with an
existing plugin system writes one of each, and its old plugins appear in the new registry
alongside the new ones — same lifecycle, same manager, no flag day.

## 4. What crosses the boundary

### Contracts are erased to `any Sendable`

`PluginInstance.contract(for:contribution:)` returns `any Sendable`, and the manager casts
it to `P.Contract`. The erasure is necessary because the concrete contract type belongs to
your vocabulary, which no runtime backend can know. It is `any Sendable` rather than `Any`
because the value crosses actor boundaries on the way back, and plain `Any` would be a lie
the compiler correctly refuses.

A failed cast becomes `ExtensionPointError.contractTypeMismatch(point:expected:found:)`
carrying both type names — the author cannot see your stack, so the error has to be
self-contained.

### Metadata is `JSONValue`, decoded at the edge

The framework holds contribution metadata opaquely. Your host registered a closure that
*does* know the type, so `ExtensionPointCatalog` can decode and validate the metadata at
discovery — rejecting a contribution whose payload does not match its point, with the
offending field named, before any plugin code exists in the process.

### Remotability is an `invoke` shim, not a constraint

`RemotableExtensionPoint` requires a `Request`/`Response` pair and a static
`invoke(_:with:)`, rather than `where Contract: RemotableContract`.

The mechanical reason: `Contract` is normally an existential (`any Command`), and `any P`
does not conform to `P`, so that constraint cannot be written.

The better reason: `invoke` gives the framework a **uniform way to actually call** any
remotable contract, which is what a transport needs. A marker constraint would only have
labelled the point. This makes location transparency mechanically true — and it is exactly
what `PluginHarness.Transport.serializing` uses to prove a contract survives a boundary
before anyone attempts XPC.

## 5. Manifest authority

Enforced in `ContributionRegistrar` and `HostPluginContext`:

```swift
try await context.register(CommandPoint.self, name: "undeclared") { … }
// throws ExtensionPointError.contributionNotFound

let net = try await context.capability(NetworkAccess.self)
// throws CapabilityError.undeclared — before policy is even consulted
```

The ordering in the second case matters. An undeclared capability is refused *before* the
broker runs, so a plugin cannot cause a prompt for something the user never saw on its
disclosure list.

For the honest case this is a drift check, and `PluginHarness.drift()` reports it as a
build-time diff rather than a runtime surprise. See [testing.md](testing.md#drift).

## 6. Concurrency

The package builds under Swift 6 strict concurrency with no escapes beyond two audited
`@unchecked Sendable` boxes (a lock-guarded capability cache, and `UserDefaults`, which is
thread-safe but unannotated).

- **`PluginManager` is an actor.** Plugin state is genuinely contended: a preferences panel,
  a menu click, a filesystem change, and a background refresh can all touch it at once.
- **Concurrent activation is deduplicated.** Two menu clicks in one frame produce one
  activation, via an in-flight task map.
- **Contracts are memoised** per contribution. That is a semantic guarantee, not an
  optimisation: a contract holding per-contribution state must not be silently rebuilt on
  every click.
- **Service cycles are caught by a task-local activation chain.** A shared flag would give
  false positives under actor reentrancy; the task-local answers the right question — *did
  this activation lead here?*
- **Plugins should be actors.** A plugin is called from the host's concurrency domain at
  times it does not choose, and an actor removes that class of race rather than documenting
  a locking discipline nobody follows.
- **Deactivation races a latch, not a task group.** A group awaits its children, so a plugin
  whose `deactivate()` never returns would hang the very timeout meant to contain it.
  Overrunning work is *abandoned*, deliberately leaked — an in-process plugin's objects may
  still be reachable from the host, so reclaiming its code would turn a hang into a crash.

## 7. Testability

Every dependency arrives through `HostConfiguration`. Nothing inside the manager reaches for
a global, so a test builds the struct with in-memory stores and gets fully deterministic
behaviour. There is no separate "test mode" — production and tests take the same path, which
is what keeps the two honest.

`PluginHarness` goes further: it is built from the *real* `HostPluginContext`, the *real*
`PolicyCapabilityBroker`, and the *real* layered configuration store. A hand-written fake
context would drift from the host's behaviour and then confidently report a passing test.

## 8. Source map

```
Sources/PluginKitCore/
  Model/PluginManifest.swift        manifest, dependencies, services, validation
  Model/Contribution.swift          contributions, capability requests, activation, runtime
  Model/ConfigurationSchema.swift   settings schema, layers, ConfigKey
  Model/PluginPhase.swift           phases, health, warnings, host lifecycle events
  Model/CatalogDocument.swift       the emitted vocabulary description
  Model/PluginBundleLayout.swift    on-disk conventions
  Contracts/ExtensionPoint.swift    points, locality, arity, RemotableContract
  Contracts/Capability.swift        capability, scope, decision, consent
  Contracts/Plugin.swift            Plugin, PluginContext, HostInfo, PluginService
  Contracts/HostServices.swift      config, storage, events, consent seams
  Contracts/PluginEntryPoint.swift  bootstrap contract
  Support/                          identifiers, versions, JSONValue, errors, logging

Sources/PluginKitHost/
  PluginManager.swift               orchestration + the lifecycle state machine
  HostConfiguration.swift           the composition root
  Registry/ExtensionPointCatalog    version acceptance, metadata validation, catalog emission
  Registry/PluginRecord.swift       what a manager UI binds to
  Discovery/PluginSource.swift      sources and locations
  Discovery/TrustPolicy.swift       trust levels, code signing
  Capabilities/                     registry, policy, broker, consent stores
  Lifecycle/ContributionRegistrar   manifest authority + contract memoisation
  Lifecycle/HostPluginContext       the plugin's only door
  Runtime/PluginRuntime.swift       runtime + selector seams
  Services/                         layered config, storage, event bus
  Diagnostics/                      events, activation costs, the deadline helper
```

### The files to be careful with

- **`ContributionRegistrar.swift`** — manifest authority lives here. Loosening either
  `register` or `provide` to warn-and-allow would silently remove a containment boundary the
  rest of the design assumes.
- **`PluginManager.validate(_:)`** — the order of checks is the order of error messages a
  user sees. Runtime availability is checked *last* on purpose, so everything genuinely
  wrong with a plugin is reported in preference to the most configurable failure.
- **`DefaultRuntimeSelector`** — `allowsUnisolatedFallback` defaults to `false`. Flipping it
  changes untrusted plugins from "reported unsatisfied" to "given full app authority".

## 9. Where a change belongs

| You want to… | Do this | Not this |
|---|---|---|
| Add a domain concept (a new kind of contribution) | Add an extension point to **your vocabulary package** | Add anything to PluginKit |
| Support a new plugin location | Write a `PluginSource` | Extend `DirectoryPluginSource` |
| Add an isolation model | New Layer 2 target conforming to `PluginRuntime` | Add a case to an enum in Host |
| Add a permission | A `Capability` type + `capabilities.register` | A boolean on the manifest |
| Change who may load what | A `TrustPolicy` or `RuntimeSelector` | Conditionals inside the manager |
| Change where settings live | A `ConfigurationStoreFactory` | Reach into `LayeredConfigurationStore` |
| Add a plugin-facing convenience | An extension in **`PluginKitSDK`** | A requirement on `PluginContext` |

That last row is the one worth internalising. `PluginContext` sits on a binary boundary
between separately-compiled code: every requirement added to it is a requirement that can
never be removed. Conveniences belong on the side that can add to them freely — which is
exactly why `optionalCapability(_:)` and `settingUpdates(_:)` are SDK extensions rather than
protocol members.

If a change seems to require editing `PluginKitCore`, that is worth a second look. Core is
the only surface with a permanent commitment attached, and most changes that appear to need
it actually need a new conformance somewhere else.
