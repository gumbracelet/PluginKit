# Troubleshooting

Symptom → cause → fix. Grouped by where you are standing when it happens.

**First move, always:**

```swift
for record in await manager.plugins() {
    print(record.id, record.phase,
          record.unsatisfied?.description ?? record.lastError ?? "")
}
```

Nothing in PluginKit fails silently. A plugin that is not working is in a phase, with a
reason attached, and that reason is a complete sentence.

- [My plugin does not appear](#my-plugin-does-not-appear)
- [It appears but will not load](#it-appears-but-will-not-load)
- [It loads but misbehaves](#it-loads-but-misbehaves)
- [Capabilities and permissions](#capabilities-and-permissions)
- [Versioning](#versioning)
- [Host integration](#host-integration)
- [Build and packaging](#build-and-packaging)
- [Tests](#tests)

---

## My plugin does not appear

### Not in `manager.plugins()` at all

The source never found it.

- **Wrong directory.** User plugins go in
  `~/Library/Application Support/<AppName>/Plugins/`, where `<AppName>` defaults to the last
  component of `appIdentifier` — `com.acme.editor` → `editor`. Pass `appName:` explicitly to
  `.standard` if that is not what you want.
- **Wrong extension.** Only `.plugin` and `.bundle` are scanned.
- **No manifest.** `PluginBundleLayout.manifestURL(inBundleAt:)` looks at
  `Contents/Resources/plugin.json`, then `Resources/plugin.json`, then `plugin.json` at the
  root. A bundle with none is skipped silently, because one unreadable bundle must not hide
  the other nineteen.
- **The manifest does not parse.** Same silent skip. Run
  `pluginkit validate --manifest plugin.json` to find out why.

### Present, but `phase == .rejected`

Read `record.lastError`.

| Message | Fix |
|---|---|
| "…is not code signed." | Sign it, or set `unsignedTrust:` on `CodeSigningTrustPolicy` for development. |
| "…is quarantined." | `xattr -d com.apple.quarantine Foo.plugin`, or set `refusesQuarantined: false`. |
| "…signed by 'X', not by 'Y'." | Add the team to `trustedTeamIDs`, or leave that array empty to accept any valid signature. |
| "…embeds its own copy of 'Z'." | Stop embedding the host's contract framework. See [distribution.md](distribution.md#single-copy-linkage--the-mistake-worth-avoiding). |
| "The plugin needs PluginKit X; this host provides Y." | Widen `sdkVersion` in the manifest, or update one side. |
| "Duplicate contribution…", "…needs a reason…" | Structural manifest error. `pluginkit validate` reports the same thing. |

### Present, but its contributions are missing from a menu

`contributions(to:)` only returns plugins whose phase `contributesToRegistry` —
`resolved`, `loading`, `active`, `inactive`. A `failed`, `unsatisfied`, `rejected`, or
`quarantined` plugin contributes nothing.

If the *plugin* is `.resolved` but one contribution is absent, its metadata failed to decode.
That is logged per contribution and skipped — one plugin's bad manifest must not empty
another's menu. Check your log sink; the message names the field.

---

## It appears but will not load

`phase == .unsatisfied`. `record.unsatisfied` says which of these it is.

### `noRuntimeAvailable`

> "No way to run this plugin: 'inProcess' is unavailable at trust level sandboxedOnly."

**The most common first-run surprise, and it is working as intended.** With only the
in-process runtime shipped, `DefaultRuntimeSelector` refuses to put a `sandboxedOnly` plugin
into your address space. Options, best first:

1. Raise its trust — sign it and use `CodeSigningTrustPolicy` with your team pinned.
2. Ship an isolating runtime. (Not available yet; see
   [distribution.md](distribution.md#roadmap).)
3. Opt in explicitly:
   ```swift
   configuration.runtimeSelector = DefaultRuntimeSelector(allowsUnisolatedFallback: true)
   ```
   The plugin then loads and gains `PluginWarning(kind: .unisolated)` on its record. Show
   that warning — the user is getting a plugin with full app access.

### `extensionPoint(.localityViolation)`

The plugin contributes to a `LocalExtensionPoint`, which can only run in-process, and its
trust level forbids that. The message quotes the point's own `localityReason`.

Same three options as above. Longer term, ask whether the point really needs to be local —
[extension-points.md](extension-points.md#locality).

### `missingDependency` / `dependencyVersionMismatch`

Install the dependency, or relax `versions` in the manifest. Both messages name the
identifier, and the mismatch names both versions.

### `dependencyCycle`

Refused rather than ordered arbitrarily: picking an order means picking which plugin sees a
half-initialised peer. Break the cycle — usually by extracting the shared part into a third
plugin, or by turning one direction into an event instead of a dependency.

### `requiredCapabilityDenied`

> "Needs 'contacts.read', which was denied: This host does not provide it."

The host never registered that capability. Either register it, or the plugin is targeting a
host that does not support what it needs. Checkable without prompting, which is why it is
reported at discovery rather than asking the user about a plugin that can never work.

### `vocabularyUnsupported`

The plugin's `compatibleWith` range excludes the host's vocabulary version. Reported once,
before per-point checks, so a wrong-generation plugin reports *that* rather than a cascade of
mismatches with one cause.

### `disabledByUser` / `disabledByPolicy`

The user turned it off (`setEnabled(_:_:)`), or safe mode is on (`PLUGINKIT_SAFE_MODE=1`),
or `minimumOSVersion` exceeds the running system.

---

## It loads but misbehaves

### `phase == .failed`

`record.lastError` has the message. Usually one of:

- a **required** capability was denied → the plugin threw, correctly
- the plugin threw for its own reasons during `activate(_:)`
- a service it consumes has no provider

### `phase == .quarantined`

It failed `crashBudget.maximumFailures` times. `CrashBudget.lenient` disables this during
development, where a plugin failing three times in a row is a normal afternoon.

### `contractTypeMismatch` on `resolve()`

> "The contribution to 'com.acme.editor.command' produced CountCommand, but the contract is
> any InspectorProviding."

The plugin registered a factory under the wrong extension point. Only detectable at
resolution — the manifest says which point, but the *type* is not known until the factory
runs. Both type names are in the message, because the author cannot see your stack.

### Contributions appear in a different order each launch

They should not. Ordering is priority → source precedence → plugin ID → contribution name.
If you are seeing instability, you are probably sorting the handles yourself afterwards, or
reading them from more than one `contributions(to:)` call and interleaving.

### The plugin's factory runs more than once

It should not — contracts are memoised per contribution. Two `resolve()` calls return the
same instance. If you are seeing repeats, check whether something is calling
`deactivate(_:)` in between: deactivation resets the registrar, so the next resolve builds
fresh. That is intended.

### `deactivate()` seems to hang

It overran `deactivationBudget` (2s default) and the host abandoned it. Look for
`"Deactivation overran …; abandoning in place."` in your log.

In-process, abandoned means **deliberately leaked** — the plugin's objects may still be
reachable from your app, so unloading its code would turn a hang into a crash. Fix the
plugin, or raise the budget if the work is genuinely slow and genuinely necessary.

### Log messages are not attributed to a plugin

`PluginLogging.log` receives a `PluginID?`. Include it in your sink:

```swift
CallbackPluginLog { level, plugin, message in
    Logger(subsystem: "…", category: plugin?.rawValue ?? "host").log("\(message)")
}
```

Without it, you lose the only post-mortem attribution available when an in-process plugin
takes your app down with it.

---

## Capabilities and permissions

### `CapabilityError.undeclared`

The plugin asked for something its manifest does not declare. Add it to `capabilities` with
a non-empty `reason`.

This is refused **before** policy is consulted, deliberately — a plugin must not be able to
cause a prompt for something the user never saw on its disclosure list.

### `CapabilityError.unavailable`

The host never called `capabilities.register(...)` for that ID. Different from `denied`:
nothing exists to grant.

### `scopeEmpty`

The requested scope and the policy limit have no overlap. A capability that failed on every
call would be worse than an honest refusal. Widen the policy limit or narrow the request.

### `scopeMalformed`

The manifest's `scope` did not decode into the capability's `Scope` type. Note that an
absent or empty `{}` scope means `Scope.unrestricted` — "as much as you will give me" — not
"every field missing".

### The user is prompted twice for the same thing

Should not happen: `CallbackConsentStore` re-checks under isolation before prompting, so two
plugins activating concurrently produce one prompt. If you wrote your own `ConsentStore`, do
the same re-check inside `requestConsent`.

### A denied capability crashes the plugin

The plugin used `capability(_:)` where it wanted `optionalCapability(_:)`. `PluginConformance`
catches this — the `optional-capability-denied` check.

### The permission list looks wrong for an in-process plugin

It is. Bind your UI to `record.trustSummary`, not to a list of granted capabilities. In
process, a capability grant is a disclosure contract and not a boundary; a list implying
containment is worse than no list. See [capabilities.md](capabilities.md#the-honest-part).

---

## Versioning

### `contractVersionUnsupported`

> "…built against 'com.acme.editor.command' contract 2.0.0; this host accepts >=1.0.0 <2.0.0."

Rebuild the plugin against a version in range, or widen what the host accepts:

```swift
configuration.extensionPoints.register(CommandPoint.self, accepting: "1.0.0" ..< "3.0.0")
```

### A plugin that used to work stopped after a host update

Compare `record.manifest.contracts[].builtAgainst` against the catalog's `accepts`. If you
bumped a major without widening `accepting:`, every plugin on the old contract went
`unsatisfied` at once.

Widen the range and add a `ContractDeprecation` with guidance, so authors get a warning
instead of a wall. See [extension-points.md](extension-points.md#deprecation).

### A `0.x` plugin loads into a host it should not

Check you are using `VersionRange.series(of:)` / `.compatible(with:)` rather than a
hand-built range. For `0.x`, the next *minor* is the breaking boundary —
`0.0.0 ..< 1.0.0` would treat `0.1` and `0.9` as compatible.

---

## Host integration

### `start()` returns but nothing is resolved

- `configuration.sources` is empty — `.standard` populates it, a bare `init` does not.
- `configuration.runtimes` is empty. **No runtime is included by default**, deliberately.
- Safe mode is on.

### `contributions(to:)` returns nothing, but plugins are `.resolved`

- The point was never registered on `configuration.extensionPoints`, so every contribution
  to it was rejected at validation as `unknownExtensionPoint`.
- The `ExtensionPointID` in the manifest does not match the one in your point.
- The point's arity is `.single` and something with higher priority won.

### Everything loads at launch

Something declared `activation: eager`. Check `record.manifest.activation`, and confirm with
`await manager.diagnostics.activationCosts()`. `.eager` requires a written reason precisely
so this is visible.

### Launch got slower after adding plugins

```swift
for (plugin, duration) in await manager.diagnostics.activationCosts() {
    print(plugin, duration)
}
```

If plugins appear there that you did not expect to be loaded, something is resolving
contributions eagerly at startup — building menus is fine, calling `resolve()` on them is
not.

### `try await manager.start()` warns

`start()` does not throw. A launch path has to produce *some* state. Drop the `try`.

---

## Build and packaging

### "Source files for target X should be located under…"

A target directory is empty. Every target in `Package.swift` needs at least one file.

### The plugin bundle loads but `principalClass` is nil

`NSPrincipalClass` is missing from `Info.plist`, or the class is not `@objc`-exposed under
the name given. Use `@objc(WordCountEntry)` and match it exactly.

### "…does not conform to PluginEntryPoint"

The principal class does not subclass `PluginPrincipal`. Subclass it and override
`makePlugin()`.

### "The manifest says 'X' 1.0.0 but the binary links 1.2.0"

The load-time handshake caught a real mismatch. The manifest is a file that can be edited
without recompiling; the binary's answer is not — so update the manifest, or rebuild against
the version it claims.

### Library-evolution check fails in CI

Something in `PluginKitCore` or `PluginKitSDK` is not resilient. Those are the only targets
on a binary boundary; if either stops compiling under evolution, a plugin built against one
release cannot be loaded by a host linking another.

### The release workflow refuses to run

- "tag vX.Y.Z already exists" — the bump would land on an existing tag. Pick a different one.
- "shallow clone" (local script) — `git fetch --unshallow`. Tag history is where the version
  comes from, and a wrong version computed silently is worse than a failure.
- "working tree is dirty" — commit or stash first.

---

## Tests

### `PluginHarness.activate` throws `contributionNotFound`

The plugin registered something the manifest does not declare. That is the harness applying
the same manifest authority the host does — a harness that allowed it would hide exactly the
drift you are trying to catch.

### `grant()` has no effect

Call it **before** `activate(_:)`. The broker is assembled at activation time.

Also confirm the manifest declares the capability: granting it in the harness does not
declare it, on purpose.

### `.serializing` fails where `.direct` passes

Working as intended — the contract does not survive a boundary. Common causes: a custom
`encode(to:)` that drops a field; a type relying on reference identity; a `Codable`
conformance that is not round-trip stable.

Fix it now, while it is one failing test, rather than when the plugin moves out-of-process.

### `InstantiationCounter.total` is not zero after `start()`

Something activated eagerly. Either the manifest says `activation: eager`, or the test
resolved a contribution before asserting.

### A drift finding you do not expect

`declaredButNotRegistered` usually means a conditional registration path did not run under
the harness's arrangement — grant whatever that branch needs.
`capabilityDeclaredButUnused` usually means the manifest is stale.
