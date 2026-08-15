# Lifecycle

What each phase means, when code actually loads, and how failures are contained.

- [Phases](#phases)
- [Discovery and validation](#discovery-and-validation)
- [Activation triggers](#activation-triggers)
- [Failure and quarantine](#failure-and-quarantine)
- [Deactivation](#deactivation)
- [Upgrade](#upgrade)
- [Safe mode](#safe-mode)
- [Diagnostics](#diagnostics)
- [Plugin-to-plugin services](#plugin-to-plugin-services)

## Phases

```
discovered → validated → resolved → loading → active → inactive → (unloaded)
     ↓            ↓          ↓          ↓        ↓                     ↓
 rejected    unsatisfied  ◄steady►   failed   failed            quarantined
```

| Phase | Meaning | Contributions listed? | Code loaded? |
|---|---|---|---|
| `discovered` | manifest parsed, nothing else | no | no |
| `rejected` | refused before loading: trust, signature, malformed manifest | no | no |
| `validated` | well-formed and trusted enough to consider | no | no |
| `unsatisfied` | well-formed, but something it needs is missing | no | no |
| `resolved` | **the steady state** | **yes** | **no** |
| `loading` | code being mapped in | yes | yes |
| `active` | `activate()` returned; contracts resolvable | yes | yes |
| `inactive` | deactivated but still installed and re-resolvable | yes | no |
| `failed` | loading or activation threw; retryable within budget | no | no |
| `quarantined` | auto-disabled after repeated failures | no | no |

**`resolved` is where a healthy host idles.** Sixty installed plugins should sit at sixty
`resolved` and zero loaded. If you see plugins going `active` at launch that you did not
expect, something declared `activation: eager` — check `record.manifest.activation`.

**`unsatisfied` is never silent.** Every entry carries an `UnsatisfiedReason`:

```swift
switch record.unsatisfied {
case .missingDependency(let id):                 // "Requires 'x', which is not installed."
case .dependencyVersionMismatch(let id, _, _):   // both versions in the message
case .dependencyCycle(let cycle):                // "a → b → a"
case .requiredCapabilityDenied(let id, _):       // the host does not provide it at all
case .extensionPoint(let error):                 // unknown point, version, metadata, locality
case .vocabularyUnsupported(let id, _, _):       // built against the wrong generation
case .noRuntimeAvailable(let requested, let trust):
case .disabledByUser:
case .disabledByPolicy(let reason):              // safe mode, minimum OS version
case nil:                                        // not unsatisfied
}
```

`reason.description` is a complete sentence suitable for showing a user. That is the point:
a plugin that "silently stopped appearing" is the failure mode this design exists to
eliminate.

## Discovery and validation

`await manager.start()` runs, in order:

1. **Discover** from every source, in descending precedence. On an identity collision the
   earlier source wins and the loss is recorded as a `.shadowed` diagnostic — a user-dropped
   plugin quietly overriding an IT-deployed one is a support incident waiting to happen.
2. **Validate** each candidate, without loading anything:
   - structural manifest checks (duplicate contributions, empty reasons, self-dependency)
   - `sdkVersion` against this PluginKit
   - `minimumOSVersion` against the running system
   - trust policy → `rejected` or a `TrustLevel`
   - vocabulary compatibility (**before** per-point checks, so a wrong-generation plugin
     reports *that* rather than a cascade with one cause)
   - each contribution against the catalog: point exists, contract version accepted,
     metadata decodes, locality permitted
   - required capabilities the host does not implement at all
   - user enablement, safe mode
   - runtime availability — **checked last**, because it is the most configurable failure,
     so everything genuinely wrong is reported in preference to it
3. **Resolve dependencies** once every candidate's phase is known, then detect cycles.
4. **Activate eager plugins** only.

`start()` does not throw. A launch path has to produce *some* state; failures land on the
records. Calling it again re-runs discovery and applies the difference — plugins that
disappeared are deactivated first.

## Activation triggers

| Policy | When code loads |
|---|---|
| `.onDemand` | first `resolve()` of one of its contributions — **the default** |
| `.eager(reason:)` | during `start()`. Requires a justification, shown in the manager UI |
| `.onEvent(patterns:)` | *declared and validated; event-triggered loading is not implemented yet* |

Lazy activation, in full:

```swift
let handles = await manager.contributions(to: CommandPoint.self)   // 0 plugins loaded
let contract = try await handles[0].resolve()                      // 1 plugin loaded
```

`resolve()` calls into the manager, which ensures the plugin is active, asks the runtime for
the contract, and casts it. Guarantees worth relying on:

- **Memoised.** The factory runs at most once per contribution. Repeated `resolve()` returns
  the same instance — a semantic guarantee, so a contract holding per-contribution state is
  not silently rebuilt on every click.
- **Deduplicated.** Eight concurrent `resolve()` calls produce one activation.
- **Cycle-safe.** If activating A requires a service from B, and B needs one from A, you get
  `dependencyCycle` rather than a deadlock — a task-local activation chain answers *did this
  activation lead here?*, which a shared flag could not.

## Failure and quarantine

A failure is contained to the plugin that caused it:

```swift
for handle in await manager.contributions(to: CommandPoint.self) {
    do {
        _ = try await handle.resolve()
    } catch {
        // One plugin failed. Skip it, log it, keep going. Every other
        // contribution in this list still works.
    }
}
```

The record moves to `.failed` with `lastError` set and `failureCount` incremented.

```swift
configuration.crashBudget = CrashBudget(maximumFailures: 3, quarantines: true)
```

At the budget, the plugin moves to `.quarantined` and is not retried. One plugin throwing on
every launch must not be able to make the app feel permanently broken.

`CrashBudget.lenient` disables quarantine, which is what you want during development, where
a plugin failing three times in a row is a normal afternoon.

> The name reflects the eventual out-of-process world. In-process, a plugin *crash* is your
> app's crash and there is nothing left to count — what this actually bounds is repeated
> load and activation failures. The accounting exists now so the runtime that needs it does
> not have to add it later.

## Deactivation

```swift
await manager.deactivate(pluginID)          // → .inactive, re-resolvable
try await manager.setEnabled(pluginID, false)  // → .unsatisfied(.disabledByUser), persisted
await manager.shutdown()                    // everything, dependents first
```

`deactivate()` on the plugin runs under a deadline (`deactivationBudget`, 2s by default).

**Overrun is abandoned, not killed.** In-process, the plugin's objects may still be
reachable from your app, so unloading its code would turn a hang into a crash. The host
records the overrun, logs it, drops its references, and moves on — deliberately leaking
rather than risking a crash. Out-of-process, the same overrun will become a `SIGKILL`.

This is why `deactivate()` must be idempotent: it is called after a failed activation, on
user disable, and again on quit.

`shutdown()` visits dependents before dependencies, so nothing is torn down while something
still using it is alive. Call it from `applicationWillTerminate`, after
`publishLifecycle(.willTerminate)`.

## Upgrade

When the host sees a different version of a plugin ID than it last ran:

```
deactivate old  →  willUpgrade(from:context:)  →  activate
```

```swift
func willUpgrade(from previousVersion: SemanticVersion, context: any PluginContext) async throws {
    guard previousVersion < "2.0.0" else { return }
    let old = try await context.storage.value(LegacyState.self, forKey: "state")
    try await context.storage.setValue(migrate(old), forKey: "state")
}
```

It runs **before** `activate(_:)`, so nothing has read the old shape yet. Two versions of
one `PluginID` are never active at once.

The previously-run version is recorded in the plugin's own container, so a host that swaps
`PluginStorageFactory` for something non-persistent loses upgrade detection.

## Safe mode

```console
$ PLUGINKIT_SAFE_MODE=1 open /Applications/AcmeEditor.app
```

Discovers everything and loads nothing. Every plugin appears with
`unsatisfied == .disabledByPolicy(reason: "Safe mode is on.")`.

Non-negotiable in any extensible app: the user whose app will not start needs a way in, and
building this now is far cheaper than retrofitting it during an incident. Wire it to a held
modifier at launch, matching the convention users already know from other Mac apps.

## Diagnostics

```swift
let diagnostics = await manager.diagnostics

await diagnostics.activationCosts()      // [(plugin, Duration)], slowest first
await diagnostics.events(for: pluginID)  // everything about one plugin
await diagnostics.events(of: .failed)    // everything of one kind
await diagnostics.count(of: .capabilityDenied)
```

Event kinds: `discovered`, `rejected`, `unsatisfied`, `resolved`, `activated`,
`deactivated`, `failed`, `quarantined`, `capabilityGranted`, `capabilityDenied`,
`capabilityAttenuated`, `contractResolved`, `deprecationWarning`, `shadowed`.

The buffer is bounded (512 by default) — an unbounded diagnostic buffer is a leak with good
intentions.

`activationCosts()` is the number to reach for when launch time regresses and there are
sixty plugins installed. It answers "which one" without instrumenting anything.

### Observing changes

```swift
for await event in await manager.events() {
    switch event {
    case .startedDiscovery, .finishedDiscovery(let discovered, let resolved, let rejected):
        break
    case .phaseChanged(let id, let from, let to):
        break
    case .warningAdded(let id, let warning):
        break
    case .failed(let id, let reason):
        break
    case .registryChanged:
        refreshMenus()          // ← the one a UI usually cares about
    }
}
```

### Logging

```swift
configuration.log = CallbackPluginLog(minimumLevel: .info) { level, plugin, message in
    Logger(subsystem: "com.acme.editor.plugins", category: plugin?.rawValue ?? "host")
        .log("\(message)")
}
```

PluginKit never writes to stdout or a system log on its own — where plugin output goes is
your decision. Every message a plugin emits is stamped with its own `PluginID`, which is the
only post-mortem attribution available when an in-process plugin takes your app down with
it.

## Plugin-to-plugin services

There is no direct plugin-to-plugin edge anywhere in the graph.

```swift
// Provider — must be declared in `provides`.
try await context.provide(WordCounting.self) {
    WordCounting(counter: { $0.split(separator: " ").count })
}

// Consumer — the host resolves it and activates the provider on demand.
let counting = try await context.service(WordCounting.self)
```

The consumer receives a proxy the host brokers, never the provider's own object. So the
provider stays swappable, the wiring stays subject to policy, the interaction is loggable,
and a provider failure arrives as a thrown error rather than a cascade.

Declare the relationship in `dependencies` as well, so the host can report a missing
provider at *discovery* rather than at first use.
