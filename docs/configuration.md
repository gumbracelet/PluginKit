# Configuration and storage

Plugin settings, managed profiles, and per-plugin containers.

- [Three storage classes](#three-storage-classes)
- [The layers](#the-layers)
- [Declaring a schema](#declaring-a-schema)
- [Reading and writing](#reading-and-writing)
- [Managed configuration](#managed-configuration)
- [Storage](#storage)
- [Secrets](#secrets)
- [Wiring it up](#wiring-it-up)

## Three storage classes

Kept separate because conflating them causes two specific bugs: window positions syncing
between machines, and access tokens ending up in a plist.

| Class | Contents | Where | Synced | Schema |
|---|---|---|---|---|
| **Settings** | user-facing preferences | `settings.json` in the plugin container | yes | required |
| **State** | caches, window frames, opaque | plugin container | no | none |
| **Secrets** | tokens, keys | Keychain | via Keychain | n/a |

`ConfigKey` carries which class it belongs to:

```swift
let theme = ConfigKey("theme", default: "system", scope: .settings)
let lastPath = ConfigKey("lastOpenedPath", default: "", scope: .state)
```

Only `.settings` keys appear in a preferences UI or a managed profile.

## The layers

A lookup walks these in order and returns the first hit. The plugin sees one flat namespace
and does not know which layer answered.

| Layer | Set by | Overridable by the user? |
|---|---|---|
| `session` | a launch flag, or a test | — |
| `managed` | an MDM configuration profile | **no** |
| `user` | what the user set | yes |
| `bundled` | shipped inside the plugin bundle | yes |
| `schemaDefault` | the manifest's declared default | yes |

`ConfigurationLayer.resolutionOrder` is that list, and the ordering lives on the type rather
than in whichever store implements lookup — so there is one definition of precedence.

`session` sits above `managed` on purpose: a test has to be able to reproduce a
configuration regardless of what is on the machine, and a launch flag is a debugging tool,
not a policy bypass available to a plugin.

## Declaring a schema

In the plugin's manifest:

```json
"configuration": {
  "version": 1,
  "keys": [
    { "name": "threshold", "type": "int", "default": 10,
      "title": "Word threshold",
      "summary": "Highlight documents longer than this." },
    { "name": "style", "type": "string", "default": "plain",
      "title": "Report style",
      "allowedValues": ["plain", "detailed"] },
    { "name": "lastReportPath", "type": "string", "scope": "state" }
  ]
}
```

Types: `bool`, `int`, `double`, `string`, `json`. (`double` also accepts an `int`, because
an integer written by a JSON encoder can come back either way.)

The payoff is the same as declarative contribution metadata: **a host can render a plugin's
settings pane without loading its code.** Read `record.manifest.configuration` and draw it.

`version` is bumped when keys are added, removed, or change meaning, and drives migration in
`willUpgrade(from:context:)`.

A schema whose default contradicts its own type is a manifest validation error — caught at
the author's desk, not on a user's machine.

## Reading and writing

```swift
let threshold = ConfigKey("threshold", default: 10)

let value = await context.configuration.value(threshold)
try await context.configuration.set(threshold, to: 25)
```

**Reads never throw. Writes do.** That asymmetry is deliberate:

- A configuration read sits on the activation path. A corrupt preferences file must not be
  able to stop a plugin from loading — it produces the key's default and a diagnostic. A
  value of the wrong type falls through to the next layer rather than failing.
- A write that is refused — the key is locked by a managed profile, or the value fails the
  schema — is a real condition with a user action behind it, and reporting it is useful.

Observing, without the read-then-subscribe race:

```swift
for await threshold in context.settingUpdates(ConfigKey("threshold", default: 10)) {
    self.threshold = threshold      // yields the current value first, then every change
}
```

Doing this by hand means reading once and then subscribing, and losing any change published
in between. The SDK convenience subscribes first.

Two accessors exist for UI:

```swift
await store.isLocked("threshold")         // → show a lock badge, not a dead control
await store.resolvedLayer("threshold")    // → .managed, .user, .schemaDefault…
```

## Managed configuration

```swift
configuration.configurationStores = FileConfigurationStoreFactory(
    root: dataRoot,
    managed: [
        "com.acme.editor.markdown": [
            "threshold": 50,
            "style": "plain",
        ]
    ]
)
```

Managed values cannot be written over. A plugin's `set(_:to:)` throws, and a settings UI
should show a lock rather than a control the user cannot actually change.

Read the values from a `.mobileconfig` payload or your MDM channel at launch, then apply
them; `LayeredConfigurationStore.replace(layer:with:)` swaps a whole layer at runtime for a
freshly fetched profile.

Managed configuration pairs with managed *capability policy* (see
[capabilities.md](capabilities.md#policy)). Together they are what makes a fleet deployment
enforceable rather than advisory.

## Storage

Each plugin gets a private, inescapable container:

```swift
try await context.storage.setValue(recentPaths, forKey: "recent")
let recent = try await context.storage.value([String].self, forKey: "recent") ?? []

try await context.storage.setData(nil, forKey: "recent")     // delete
let keys = try await context.storage.keys()
context.storage.containerURL                                  // for bulk files
```

Default location: `~/Library/Application Support/<AppName>/PluginData/<plugin-id>/`.

Keys are sanitised into filenames, and the sanitisation is not cosmetic: a key containing
`../` would otherwise let a plugin write outside its own container, which is exactly the
escape the scoping exists to prevent. Only alphanumerics and `-_.` survive, and leading dots
are stripped.

## Secrets

Do not put them here. A token in a plist is a token in a backup.

Use the Keychain. If plugins need it, vend it as a capability so the host controls the
access group and the item scoping:

```swift
configuration.capabilities.register(SecretStorage.self) { _, plugin in
    SecretStorage(accessGroup: "\(teamID).com.acme.editor.plugins.\(plugin.id)")
}
```

That way one plugin's secrets are not reachable by another, and the host — not the plugin —
decides the naming scheme.

## Wiring it up

```swift
// File-backed. The default from `.standard`.
configuration.configurationStores = FileConfigurationStoreFactory(root: dataRoot)
configuration.storage = FileSystemStorageFactory(root: dataRoot)

// In-memory. Tests, previews, or a host that deliberately keeps no plugin settings.
configuration.configurationStores = InMemoryConfigurationStoreFactory()
configuration.storage = InMemoryStorageFactory()
```

Both are protocols — `ConfigurationStoreFactory` and `PluginStorageFactory` — so a host that
already has a preferences system can put plugin settings wherever it keeps its own. They are
factories rather than single shared stores because each plugin's namespace must be separate
and inescapable: a plugin able to name another's keys could read its settings, and there is
no legitimate reason to allow it.

Persistence sits behind a further seam, `ConfigurationPersistence`, so the layering logic is
testable without touching the filesystem.
