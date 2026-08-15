# Capabilities and trust

What plugins may do, who decides, and what your permission UI can honestly claim.

- [Three separate concepts](#three-separate-concepts)
- [The honest part](#the-honest-part)
- [Designing a capability](#designing-a-capability)
- [Attenuation](#attenuation)
- [Policy](#policy)
- [Consent](#consent)
- [Trust levels](#trust-levels)
- [Runtime selection](#runtime-selection)
- [Event topics](#event-topics)
- [TCC and OS permissions](#tcc-and-os-permissions)

## Three separate concepts

Conflating these is the usual source of confusion, so PluginKit keeps them apart:

| | What it is | Who decides | Enforced by |
|---|---|---|---|
| **Capability** | a typed, scoped grant to a host service | host policy + the manifest | the broker (+ sandbox, out-of-process) |
| **Consent** | user approval for a sensitive capability | the user, persisted | `ConsentStore` |
| **OS permission** | TCC: camera, contacts, full disk | the user, via macOS | the OS, against *your app* |

A plugin can be highly trusted and still be denied contacts. A capability can be granted by
policy and still require consent. And an OS permission is granted to your app, not to the
plugin — which is why the plugin's use of it has to be brokered.

## The honest part

Read this before designing a permission UI.

> **In-process, a capability grant is policy and disclosure — not a security boundary.**

A native plugin loaded into your address space can call `FileManager` directly, ignore the
broker entirely, and take the process down with it. There is no mechanism in the framework
that could prevent it, and there is no version of PluginKit that will change that.

So a capability plays two roles depending on where the plugin runs:

| Runtime | What a capability actually is |
|---|---|
| **In-process** | A reviewable, auditable, revocable **disclosure contract**. Real value — a user can see what a plugin claims to need, and revoke it — but not containment. |
| **Out-of-process** | Real enforcement: the child's sandbox profile derives from the granted set, and the broker is the only channel out. |

`PluginRecord.trustSummary` says which one a given plugin is getting:

```
"Bundled with the app — full app access"
"Verified developer — full app access, not sandboxed"
"Third party — sandboxed"
```

Bind your UI to that. An in-process plugin should read *"full app access"*, not a tidy list
of four permissions that implies containment you do not have. A permission list that lies is
worse than no permission list, because the user then makes decisions based on it.

PluginKit also flags this itself: a plugin below `firstParty` trust that ends up in-process
gains `PluginWarning(kind: .unisolated)` on its record.

## Designing a capability

A capability is the **handle** a plugin receives, not a flag it checks. A denied plugin gets
a thrown error and no handle at all, so there is no path through the code where an ungranted
capability is reachable.

Declare it as a concrete type with an injected implementation:

```swift
public struct NetworkAccess: Capability {
    public struct Scope: CapabilityScope {
        public var hosts: [String]

        public static var unrestricted: Scope { Scope(hosts: ["*"]) }

        public func attenuated(to limit: Scope) -> Scope? {
            if limit.hosts.contains("*") { return self }
            let kept = hosts.filter { limit.hosts.contains($0) }
            return kept.isEmpty ? nil : Scope(hosts: kept)
        }
    }

    public static let capabilityID: CapabilityID = "net.http"
    public static let sensitivity: CapabilitySensitivity = .dangerous

    public let grantedHosts: [String]
    private let perform: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await perform(request)
    }
}
```

Register it with the implementation:

```swift
configuration.capabilities.register(
    NetworkAccess.self,
    summary: "Makes HTTP requests to the granted hosts.",
    scopeExample: ["hosts": ["api.example.com"]]
) { scope, plugin in
    NetworkAccess(grantedHosts: scope.hosts) { request in
        guard let host = request.url?.host, scope.hosts.contains(host) else {
            throw URLError(.unsupportedURL)
        }
        return try await URLSession.shared.data(for: request)
    }
}
```

The factory receives the **already-attenuated** scope, so enforcement lives in one place
rather than being re-derived in every capability. Note the belt-and-braces host check
inside: the scope is authoritative, and the implementation should still not trust its own
caller.

> **Why a struct and not a protocol?** `any NetworkAccess` does not conform to
> `NetworkAccess`, so a protocol-shaped capability could never satisfy the `C: Capability`
> constraint on `context.capability(_:)`. The concrete-handle-plus-closure shape gives the
> same substitutability while staying usable in a generic position.

### Sensitivity

| Level | Meaning | Typical policy |
|---|---|---|
| `.benign` | no user-visible risk — the plugin's own storage, logging | allow |
| `.sensitive` | touches user data or the network | require consent |
| `.dangerous` | irreversible, or would alarm the user | require consent + confirmation |

The default is `.sensitive` — fail-safe, so a capability author who does not think about it
gets the classification that prompts rather than the one that silently allows.

## Attenuation

Capabilities are never vended raw. Not "filesystem access" but "read access to these roots".

`CapabilityScope.attenuated(to:)` must only ever **shrink**. That monotonicity is the whole
contract: it lets the host layer policy on top of a plugin's request without auditing every
capability implementation for whether it respects limits.

```
plugin requests   { roots: ["/tmp", "/etc"] }
policy limit      { roots: ["/tmp"] }
                  ─────────────────────────
granted           { roots: ["/tmp"] }        → CapabilityDecision.attenuated
```

The plugin is **told** it was narrowed — the decision carries both the requested and the
granted scope, and the context logs it — so it can adapt up front rather than discovering
the boundary as a series of failed calls.

An intersection that leaves nothing is `CapabilityError.scopeEmpty`, a denial. A capability
that fails on every call would be worse than an honest refusal.

An empty or absent `scope` in the manifest means `Scope.unrestricted` — "as much as you will
give me", not "a scope with every field missing".

## Policy

Resolution order, first match wins, defaulting to denial:

```
managed  →  per-plugin  →  per-capability  →  per-sensitivity  →  fallback
```

```swift
configuration.capabilityPolicy = CapabilityPolicy(
    // Set by an administrator. Unoverridable — by the user, and by every layer below.
    managed: ["net.http": .deny(reason: "Blocked by your organisation.")],

    byPlugin: [
        "com.acme.editor.markdown": ["fs.read": .allow(limit: ["roots": ["~/Documents"]])]
    ],

    byCapability: ["clipboard.read": .requireConsent],

    bySensitivity: [
        .benign: .allow,
        .sensitive: .requireConsent,
        .dangerous: .requireConsent,
    ],

    fallback: .deny(reason: "No policy permits this capability.")
)
```

Three presets:

| Preset | Use |
|---|---|
| `.denyAll` | The safest starting point, and the one you should move away from consciously. |
| `.promptForSensitive` | The reasonable default for an app with a consent UI. |
| `.allowAll` | A host that only runs plugins it compiled itself, and tests. Never third-party code. |

**Managed rulings cannot be overridden by anything.** That is what makes a fleet deployment
enforceable rather than advisory, and it is why managed sits above per-plugin rather than
below it.

## Consent

```swift
configuration.consent = CallbackConsentStore { prompt in
    await PermissionSheet.present(
        plugin: prompt.plugin.displayName,     // name the plugin
        capability: prompt.capability,
        reason: prompt.reason,                 // the plugin's own words
        scope: prompt.scope,                   // what will actually be granted
        sensitivity: prompt.sensitivity
    )
}
```

Four things about the prompt that are load-bearing:

1. **It names the plugin.** Without that, a dialog triggered by a plugin appears to come
   from your app, and the user's decision is attributed to the wrong party.
2. **It quotes the plugin's own `reason`** from the manifest. Which is why an empty reason
   is a manifest validation error rather than a style nit.
3. **It shows the scope after narrowing.** The user consents to what will really be granted,
   not to the plugin's opening bid.
4. **Answers are re-checked under isolation.** Two plugins activating concurrently and
   asking about the same grant produce one prompt, not two.

Return `.allowAlways` / `.denyAlways` to have the answer remembered;
`.allowOnce` / `.denyOnce` last only for this launch.

| Store | For |
|---|---|
| `DenyingConsentStore` | **The default.** A daemon or CLI has nobody to ask, and blocking would hang the launch path. Fail closed, log, carry on. |
| `CallbackConsentStore` | An app with a UI. Persists to `UserDefaults` unless you pass `nil`. |
| `AllowingConsentStore` | Tests, and hosts that only run their own plugins. |
| `InMemoryConsentStore` | Tests that need to assert on what *would* have been prompted. |

Revoke with `await manager.revokeConsent(for: pluginID, capability: nil)`. That does not
deactivate the plugin — it keeps whatever it already holds until next activation. Made
explicit because silently tearing down a running plugin from a permissions screen would be a
surprising side effect; call `deactivate(_:)` too if you want it immediate.

## Trust levels

`sandboxedOnly < verifiedDeveloper < firstParty`. Decided once, before loading, from where
the plugin came from and what its signature says.

```swift
configuration.trustPolicy = CodeSigningTrustPolicy(
    firstPartyTeamIDs: ["ABCDE12345"],           // your own team
    trustedTeamIDs: ["FGHIJ67890"],              // partners; empty = any valid signature
    unsignedTrust: nil,                          // nil = refuse unsigned
    refusesQuarantined: true,
    hostProvidedFrameworks: ["AcmeEditorPluginAPI"]
)
```

Checks, in order: quarantine attribute, duplicate framework, signature validity, team ID.

**The duplicate-framework check is the one people skip.** If a plugin bundle embeds its own
copy of a framework your app already provides, you get two sets of the same type metadata in
one address space, and `as?` across the seam fails while every version number involved looks
correct. Days to diagnose in the field, nothing to refuse up front.

`LocationTrustPolicy` — the default from `.standard` — trusts by *where the plugin was
found* and inspects nothing. It is correct for a host that only ships first-party plugins
compiled into it, and inadequate the moment untrusted bundles can appear on disk. It says so
in its own name rather than being called `DefaultTrustPolicy`, so you notice.

## Runtime selection

Trust decides where a plugin may run. **A plugin does not choose its own isolation** — a
runtime a plugin could pick for itself would make isolation decorative.

```swift
configuration.runtimeSelector = DefaultRuntimeSelector(
    minimumTrustForInProcess: .verifiedDeveloper,
    isolatingRuntimes: [.xpc, .appExtension, .script],
    allowsUnisolatedFallback: false          // ← fail closed
)
```

With `allowsUnisolatedFallback: false` (the default) and only the in-process runtime shipped,
a `sandboxedOnly` plugin is reported:

```
No way to run this plugin: 'inProcess' is unavailable at trust level sandboxedOnly.
```

That is the honest outcome. Rather than quietly granting full authority to untrusted code,
the plugin is listed with a reason a user can read. Flipping the flag to `true` is a
deliberate decision, and the plugin is then flagged `.unisolated` in its record.

A plugin contributing to a `LocalExtensionPoint` is a special case: locality forces
in-process, so a low-trust plugin targeting one is reported as a locality violation at
validation — before loading, with the point's own `localityReason` quoted.

## Event topics

Publish and subscribe rights are granted per topic, because a plugin able to publish
`document.saved` could mislead every other plugin:

```swift
configuration.defaultSubscribableTopics = ["document.*", "selection.*"]
configuration.defaultPublishableTopics = []          // ← the default: publish nothing

configuration.publishableTopics["com.acme.editor.sync"] = ["sync.*"]
```

Patterns support a trailing `*`. Publishing to an ungranted topic throws; subscribing to one
returns an empty stream and logs, so `subscribe` can stay non-throwing for every caller.

Delivery is best-effort by design: each subscriber has a bounded buffer and drops its oldest
events when it falls behind. A slow subscriber must never be able to stall a publisher, and
the publisher is usually your main actor.

## TCC and OS permissions

A plugin must never be able to silently trigger a TCC prompt attributed to your app.

Broker it: wrap the OS call in a capability, so `context.capability(Contacts.self)` shows
**your** consent sheet naming the plugin and its stated reason *first*, and only then
triggers the OS prompt.

```swift
configuration.capabilities.register(ContactsAccess.self) { _, plugin in
    // PluginKit's consent has already been obtained, naming this plugin, before
    // this factory runs. Only now does the OS prompt appear.
    try await CNContactStore().requestAccess(for: .contacts)
    return ContactsAccess(store: CNContactStore())
}
```

The consent record stores which plugin caused it, so revocation is meaningful and the audit
trail is attributable. Without this, the user sees your app's name on a dialog they did not
expect, grants or denies it for the wrong reasons, and has no way to revoke it per plugin.
