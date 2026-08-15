# Testing

Testing a plugin without a host, and a host without real plugins.

- [PluginHarness](#pluginharness)
- [The serializing transport](#the-serializing-transport)
- [Drift](#drift)
- [PluginConformance](#pluginconformance)
- [HostHarness](#hostharness)
- [What to actually test](#what-to-actually-test)

Link `PluginKitTesting` from your test target only.

## PluginHarness

A plugin author has no host app to test against and cannot attach a debugger to a shipped
one. Without a harness, the only way to find out whether a plugin activates cleanly under a
denied capability is to ship it.

```swift
import Testing
import PluginKitTesting

@Test("Counts words in the selection")
func counts() async throws {
    let harness = PluginHarness(manifest: manifest)

    await harness.grant(FileReading.self) { scope, _ in
        FileReading(grantedRoots: scope.roots) { _ in Data("one two three".utf8) }
    }
    await harness.deny("net.http")
    await harness.limit("fs.read", to: ["roots": ["/tmp"]])
    await harness.setSetting("threshold", to: 5)

    try await harness.activate(WordCountPlugin())

    let result = try await harness.invoke(
        CommandPoint.self, name: "count", RunCommand(text: "alpha beta gamma")
    )
    #expect(result.wordCount == 3)
}
```

The harness is built from the **real** `HostPluginContext`, the **real**
`PolicyCapabilityBroker`, and the **real** layered configuration store. That is deliberate:
a hand-written fake context would drift from the host's behaviour and then confidently
report a passing test.

Which means manifest authority applies in the harness too. `grant` makes a capability
available, but the manifest still has to declare it — a harness that granted an undeclared
capability would hide exactly the drift the host will refuse at runtime.

| Call | Does |
|---|---|
| `grant(_:_:)` / `grant(_:factory:)` | make a capability available, backed by a stub |
| `deny(_:reason:)` | refuse it, as policy would |
| `limit(_:to:)` | grant it narrowed, to test what the plugin does with less |
| `setSetting(_:to:)` / `setManagedSetting(_:to:)` | seed the user or managed layer |
| `activate(_:)` / `deactivate()` | drive the lifecycle |
| `contract(_:name:)` | the raw contract |
| `invoke(_:name:_:)` | call it, honouring `transport` |
| `service(_:)` | a service the plugin published |
| `drift()` | manifest ↔ code differences |
| `messages()` / `published(_:)` | what it logged and broadcast |
| `timesDeactivated` | for asserting idempotence |

## The serializing transport

The check worth putting in CI:

```swift
let harness = PluginHarness(manifest: manifest, transport: .serializing)
```

Every request and response crosses a JSON round-trip before and after the call. It catches
the assumptions that make a contract quietly un-remotable — a reference type smuggled
through, a `Codable` that does not round-trip, an identity comparison that survives
in-process and breaks over XPC — with none of the setup an actual out-of-process test needs.

Here is one failing, from the test suite:

```swift
// A response with a hand-written `encode` that forgets a field. Entirely
// invisible in-process, because the value is right there in memory.
struct LossyResult: Codable, Sendable {
    var count: Int
    var note: String?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)      // `note` never written
    }
}
```

```swift
let direct = PluginHarness(manifest: manifest, transport: .direct)
try await direct.activate(LossyPlugin())
let inProcess = try await direct.invoke(LossyPoint.self, name: "lossy", request)
#expect(inProcess.note != nil)          // fine

let wire = PluginHarness(manifest: manifest, transport: .serializing)
try await wire.activate(LossyPlugin())
let overWire = try await wire.invoke(LossyPoint.self, name: "lossy", request)
#expect(overWire.note == nil)           // ← the bug, found before it shipped
```

Run both transports over the same assertions and the plugin is ready to move behind an
isolation boundary whenever the host adds one:

```swift
@Test("Behaves identically over both transports", arguments: PluginHarness.Transport.allCases)
func bothTransports(transport: PluginHarness.Transport) async throws {
    let harness = PluginHarness(manifest: manifest, transport: transport)
    try await harness.activate(WordCountPlugin())
    let result = try await harness.invoke(CommandPoint.self, name: "count",
                                          RunCommand(text: "one two three"))
    #expect(result.wordCount == 3, "transport: \(transport)")
}
```

## Drift

Generating a manifest from code needs macro machinery. *Detecting drift* needs none:
activate the plugin, record what it registers and requests, diff against `plugin.json`.

```swift
@Test("The manifest matches the code")
func noDrift() async throws {
    let harness = PluginHarness(manifest: manifest)
    await harness.grant(FileReading.self) { scope, _ in StubReader(scope) }
    try await harness.activate(WordCountPlugin())

    #expect(await harness.drift().isEmpty)
}
```

| Finding | Fatal? | Means |
|---|---|---|
| `registeredButNotDeclared` | **yes** | the host will refuse it at runtime |
| `capabilityUsedButNotDeclared` | **yes** | same |
| `serviceProvidedButNotDeclared` | **yes** | same |
| `declaredButNotRegistered` | no | a menu item that throws when clicked |
| `capabilityDeclaredButUnused` | no | inflates the list a user is asked to approve |

Fail a build on the fatal ones and warn on the rest:

```swift
let drift = await harness.drift()
#expect(drift.filter(\.isFatal).isEmpty, "\(drift)")
```

The non-fatal ones still matter. A declared-but-unused capability makes every *other* line
in a permission prompt mean less, which is a real cost even though nothing breaks.

`pluginkit validate` cannot see this — it reads data and never loads plugin code. Drift needs
the plugin activated, which is what the harness is for.

## PluginConformance

The invariants a host relies on and an author has no natural reason to test, because each
only matters in a situation the author does not reproduce locally:

```swift
@Test("Word Count conforms")
func conformance() async {
    let findings = await PluginConformance(
        manifest: manifest,
        makePlugin: { WordCountPlugin() }
    )
    .granting { harness in
        await harness.grant(FileReading.self) { scope, _ in
            FileReading(grantedRoots: scope.roots) { _ in Data() }
        }
    }
    .run()

    #expect(findings.isEmpty, "\(findings)")
}
```

| Check | Catches |
|---|---|
| `manifest` | structural manifest errors |
| `activation` | fails to activate with everything granted |
| `manifest-drift` | fatal drift |
| `optional-capability-denied` | **refuses to load when an optional capability is denied** |
| `required-capability-denied` | activates anyway when a *required* one is denied |
| `deactivation-budget` | three `deactivate()` calls overrun the budget |

The fourth row is the one that earns its keep. It is the failure users actually hit — they
decline one prompt and the plugin stops loading entirely — and it is the one an author never
sees, because they always grant everything on their own machine.

The fifth is its mirror: a plugin that activates with a *required* capability denied has
either mislabelled it, or is deferring a failure to somewhere with no context attached.

A fresh instance is built for each check, because a plugin that only passes when reused is a
plugin with hidden state.

## HostHarness

For testing the host side — your extension points, your capabilities, your policy:

```swift
let counter = InstantiationCounter()
let manager = HostHarness.manager(
    plugins: [
        (manifest, counter.tracking(manifest.id) { WordCountPlugin() })
    ],
    trust: .firstParty
) { configuration in
    configuration.extensionPoints.register(CommandPoint.self)
    configuration.capabilities = myCapabilityRegistry
    configuration.capabilityPolicy = .promptForSensitive
    configuration.consent = InMemoryConsentStore(fallback: .denyOnce)
}

await manager.start()
```

Everything is real except where plugins come from and where their data goes, so the test
exercises the actual discovery, validation, resolution, and lazy-activation paths.

| Helper | For |
|---|---|
| `InstantiationCounter` | proving nothing loaded — `counter.total == 0` |
| `FixedTrustPolicy(level:)` | driving trust-dependent behaviour without signed bundles |
| `BlockingTrustPolicy(reason:)` | the rejection path |
| `InMemoryConsentStore` | asserting on what *would* have been prompted |
| `RecordingEventBus` | asserting on emissions without wiring subscribers |

`InstantiationCounter` is lock-backed rather than an actor, because a plugin factory is
synchronous — an actor would force a fire-and-forget `Task` to record into, which races the
very assertion it exists to make.

## What to actually test

Not coverage. These are the claims that break silently.

**Nothing loads until it is used.**

```swift
await manager.start()
_ = await manager.contributions(to: CommandPoint.self)
#expect(counter.total == 0)
```

If this regresses, launch time regresses with it, and nothing else will tell you.

**A denied optional capability degrades.** Covered by `PluginConformance`, and worth an
explicit test for the *behaviour* — that the feature hides rather than the plugin failing.

**Undeclared registration is refused.**

```swift
await #expect(throws: (any Error).self) {
    try await harness.activate(PluginThatRegistersSomethingUndeclared())
}
```

**A wrong-version contribution reports both versions.** For a host that has bumped a
contract, that the message is actionable rather than just present.

**Failure is contained.** Two plugins, one broken: the working one still resolves and the
broken one is `.failed`, not both.

**Ordering is deterministic.** Same priorities in, same order out, every launch.

For reference, PluginKit's own suite is 110 tests across 13 suites organised the same way —
`Tests/PluginKitTests/` is worth reading as worked examples of each of the above.
