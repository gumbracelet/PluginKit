# Plugin development

Writing a plugin for a PluginKit host. You do not need the host's source.

- [Find out what the host publishes](#find-out-what-the-host-publishes)
- [Set up the package](#set-up-the-package)
- [Write the plugin](#write-the-plugin)
- [Write the manifest](#write-the-manifest)
- [Manifest reference](#manifest-reference)
- [Shipping as a loadable bundle](#shipping-as-a-loadable-bundle)
- [The authoring loop](#the-authoring-loop)
- [Patterns worth copying](#patterns-worth-copying)

## Find out what the host publishes

```console
$ pluginkit describe --host /Applications/AcmeEditor.app
com.acme.editor 3.2.0  ·  PluginKit 0.1.0

VOCABULARIES
  com.acme.editor.api  1.2.0   accepts >=1.0.0 <2.0.0

EXTENSION POINTS
  com.acme.editor.command
      contract 1.2.0   accepts >=1.0.0 <2.0.0   remotable   many(priority)
      A command in the palette.
      metadata: title: String, category: String?
  com.acme.editor.inspector
      contract 1.0.0   accepts >=1.0.0 <2.0.0   LOCAL-ONLY   single
      ⚠ in-process only — Vends live view objects.

CAPABILITIES
  fs.read  [sensitive]
      Reads files inside the granted roots.
      scope e.g. {"roots":["~/Documents"]}

EVENT TOPICS
  document.saved  (subscribe only)
```

Read that output carefully before choosing a point:

- **`LOCAL-ONLY`** means a plugin contributing there can only run in-process. If the host
  does not trust you for that, your plugin will be `unsatisfied` and never load. Prefer a
  remotable point when you have the choice.
- **`accepts`** is the contract range. Build against something inside it.
- **`⚠ deprecated`**, when present, tells you what the host wants you to move to and when it
  will stop accepting the old shape.

If the host ships no catalog, ask for the contract package — everything below still applies.

Then scaffold:

```console
$ pluginkit init --id com.me.wordcount \
                 --point com.acme.editor.command \
                 --host /Applications/AcmeEditor.app
Wrote plugin.json
```

The metadata skeleton comes from the host's declared shape, so the first thing you write is
already the right shape.

## Set up the package

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WordCountPlugin",
    platforms: [.macOS(.v13)],
    products: [
        // A loadable bundle is a dynamic library the host maps in at runtime.
        .library(name: "WordCountPlugin", type: .dynamic, targets: ["WordCountPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/duongductrong/PluginKit.git", from: "0.1.0"),
        .package(url: "https://github.com/acme/AcmeEditorPluginAPI.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "WordCountPlugin", dependencies: [
            .product(name: "PluginKitSDK", package: "PluginKit"),
            .product(name: "AcmeEditorPluginAPI", package: "AcmeEditorPluginAPI"),
        ]),
        .testTarget(name: "WordCountPluginTests", dependencies: [
            "WordCountPlugin",
            .product(name: "PluginKitTesting", package: "PluginKit"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
```

Link **`PluginKitSDK`**, never `PluginKitHost`. The host machinery is not something a plugin
may perform for itself, and linking it would put discovery, trust evaluation, and brokering
code into your bundle for nothing.

Do **not** embed the host's contract framework in your bundle. Link it and let it resolve
against the host's copy at `@executable_path/../Frameworks`. Two copies of the same types in
one address space make casts fail across the seam while every version number looks correct;
`CodeSigningTrustPolicy` blocks a bundle that does it. See
[distribution.md](distribution.md#packaging-a-plugin-bundle).

## Write the plugin

```swift
import PluginKitSDK
import AcmeEditorPluginAPI

actor WordCountPlugin: Plugin {
    private var files: FileReading?

    init() {}                    // do no work here — nothing is available yet

    func activate(_ context: any PluginContext) async throws {
        files = await context.optionalCapability(FileReading.self)
        let reader = files

        try await context.register(CommandPoint.self, name: "count") {
            CountCommand(files: reader)      // not called until first use
        }
    }

    func deactivate() async {
        files = nil                          // must be idempotent
    }

    func healthCheck() async -> PluginHealth {
        files == nil
            ? .degraded(reason: "No file access; counting the selection only.")
            : .ok
    }
}

struct CountCommand: Command {
    let files: FileReading?

    func handle(_ request: RunCommand) async throws -> CommandResult {
        let words = request.text.split(whereSeparator: \.isWhitespace).count
        return CommandResult(didHandle: true, message: "\(words) words")
    }
}
```

### Four rules

**Prefer an `actor`.** You are called from the host's concurrency domain at times you do not
choose — a menu click, a background refresh, a deactivation on quit. An actor removes that
class of race. A stateless `final class` marked `@unchecked Sendable` is fine too.

**Do nothing in `init()`.** Nothing is available yet, and a plugin that fails there cannot
report why. All setup goes in `activate(_:)`.

**Register factories, not instances.** The closure runs on first use and its result is
memoised. Building everything eagerly in `activate` defeats lazy loading for the whole
plugin, including the parts nobody uses.

**Make `deactivate()` idempotent.** The host calls it after a failed activation, on user
disable, and again on quit — and it runs under a deadline (2s by default). Overrun and the
host abandons your plugin in place rather than waiting.

### Degrade, do not refuse

An `optionalCapability` that returns `nil` should hide a feature, not fail activation:

```swift
// Good — the user declines one prompt and everything else still works.
files = await context.optionalCapability(FileReading.self)

// Only when you genuinely cannot function, and the manifest says required: true.
let files = try await context.capability(FileReading.self)
```

`PluginConformance` checks both directions: that you survive every optional capability being
denied, and that you *do* throw when a required one is. See [testing.md](testing.md).

### What you can reach

Everything, and only, through `PluginContext`:

| Member | For |
|---|---|
| `identity`, `host` | who you are, and what app you are in |
| `logger` | output, pre-stamped with your plugin ID |
| `configuration` | your settings (see [configuration.md](configuration.md)) |
| `storage` | your private container |
| `events` | pub/sub, gated per topic |
| `capability(_:)` / `optionalCapability(_:)` | host services |
| `service(_:)` / `provide(_:_:)` | contracts from and for other plugins |
| `register(_:name:factory:)` | your contributions |
| `lifecycleEvents()` | `.willTerminate`, `.willDeactivate`, … |

There is no `PluginKit.shared`. If you find yourself wanting one, the thing you want is
probably a capability the host should be vending.

## Write the manifest

`plugin.json`, at `Contents/Resources/plugin.json` inside the bundle:

```json
{
  "id": "com.me.wordcount",
  "version": "1.0.0",
  "displayName": "Word Count",
  "summary": "Counts words in the selection or the open document.",
  "author": { "name": "Me", "url": "https://example.com" },

  "sdkVersion": ">=0.1.0 <0.2.0",
  "contracts": [
    { "vocabulary": "com.acme.editor.api",
      "builtAgainst": "1.2.0",
      "compatibleWith": ">=1.0.0 <2.0.0" }
  ],

  "runtime": { "kind": "inProcess", "entryPoint": "WordCountEntry" },
  "activation": { "kind": "onDemand" },

  "capabilities": [
    { "id": "fs.read",
      "required": false,
      "reason": "Counts words in the open file.",
      "scope": { "roots": ["~/Documents"] } }
  ],

  "contributions": [
    { "extensionPoint": "com.acme.editor.command",
      "name": "count",
      "contractVersion": "1.2.0",
      "priority": 10,
      "metadata": { "title": "Count Words", "category": "Text" } }
  ],

  "configuration": {
    "version": 1,
    "keys": [
      { "name": "includeMarkdownSyntax", "type": "bool", "default": false,
        "title": "Count Markdown syntax" }
    ]
  }
}
```

Every optional key has a defensible default, so the shortest useful manifest is three lines
(`id`, `version`, `displayName`).

**The manifest is authoritative.** You cannot register a contribution, request a capability,
or publish a service it does not declare — those are refused at runtime, not warned about.
Keep it in step with your code using `PluginHarness.drift()`.

### Generating it from Swift

```swift
let manifest = try PluginManifestBuilder(
    id: "com.me.wordcount", version: "1.0.0", displayName: "Word Count"
)
.requesting("fs.read", scope: ["roots": ["~/Documents"]],
            reason: "Counts words in the open file.")
.contributing(to: CommandPoint.self, named: "count", priority: 10,
              metadata: CommandPoint.Metadata(title: "Count Words", category: "Text"))
.validated()

try manifest.encoded().write(to: outputURL)
```

The typed `contributing(to:)` overload takes the host's own `Metadata` type, so a host
renaming a field breaks your build instead of producing a manifest the host silently
rejects. It also records the vocabulary dependency for you.

## Manifest reference

| Key | Type | Default | Notes |
|---|---|---|---|
| `id` | string | **required** | Reverse-DNS. Permanent across versions. |
| `version` | semver | **required** | Drives upgrade detection and config migration. |
| `displayName` | string | **required** | Shown in the plugin manager. |
| `summary` | string | — | One or two sentences. |
| `author` | object | — | `name`, `email`, `url`. Display only — never a trust input. |
| `sdkVersion` | range | `*` | PluginKit generations you support. Outside it → rejected. |
| `contracts` | array | `[]` | `vocabulary`, `builtAgainst`, `compatibleWith`. |
| `runtime` | object | `inProcess` | A *request*. The host's selector decides. |
| `activation` | object | `onDemand` | `onDemand`, `eager` (needs `reason`), `onEvent`. |
| `capabilities` | array | `[]` | `id`, `scope`, `required`, `reason` (**required, non-empty**). |
| `dependencies` | array | `[]` | `id`, `versions`, `required`. |
| `provides` | array | `[]` | Services you publish: `id`, `version`. |
| `contributions` | array | `[]` | `extensionPoint`, `name`, `contractVersion`, `priority`, `metadata`. |
| `configuration` | object | — | `version` + `keys[]`. Lets the host draw your settings pane. |
| `minimumOSVersion` | semver | — | When you need more than the host does. |

Version ranges accept `*`, `1.2.3`, `>=1.0.0`, `<2.0.0`, `>=1.0.0 <2.0.0`, `1.0.0..<2.0.0`.

**`reason` is mandatory for every capability** and must be non-empty. It is the entire text
a user sees when deciding whether to grant access, so write it for them, not for the log.

**`activation: eager` requires a `reason`.** It costs launch time for every user whether or
not your plugin is used, so the cost and the justification are both visible in the manager
UI. Use `onDemand` unless you genuinely must run at startup.

## Shipping as a loadable bundle

Set `NSPrincipalClass` in `Info.plist` and subclass `PluginPrincipal`:

```swift
@objc(WordCountEntry)
final class WordCountEntry: PluginPrincipal {
    override class func makePlugin() -> any Plugin { WordCountPlugin() }

    /// Read by the host *before* `makePlugin()` and cross-checked against the
    /// manifest. The manifest is a file you can edit without recompiling; this
    /// is not — so when they disagree, the manifest is the one that lied.
    override class func contractVersions() -> [String: String] {
        ["com.acme.editor.api": "1.2.0"]
    }
}
```

Bundle layout:

```
WordCount.plugin/
└── Contents/
    ├── Info.plist          NSPrincipalClass = WordCountEntry
    ├── MacOS/WordCount     the dylib
    └── Resources/
        └── plugin.json
```

Install to `~/Library/Application Support/<AppName>/Plugins/`. Packaging, code signing, and
the library-validation constraint are in
[distribution.md](distribution.md#packaging-a-plugin-bundle).

## The authoring loop

```console
# 1. Fast iteration: point the host at your build directory.
$ export PLUGINKIT_DEV_PATH=~/dev/wordcount/build
$ open /Applications/AcmeEditor.app

# 2. Check the manifest against the host, in a build phase or a pre-commit hook.
$ pluginkit validate --manifest plugin.json --host /Applications/AcmeEditor.app
com.me.wordcount 1.0.0 — ok

# 3. Test without the host at all.
$ swift test
```

`validate` exits non-zero on a problem, so it can gate a build. It reads manifests and
catalogs as data and never loads plugin code, so it is fast enough for a hook and safe to
run against a host you do not trust.

It cannot see drift between your manifest and your *code* — that needs the plugin
activated. `PluginHarness.drift()` covers it; see [testing.md](testing.md#drift).

## Patterns worth copying

**Observe a setting without a race.**

```swift
for await enabled in context.settingUpdates(ConfigKey("includeMarkdownSyntax", default: false)) {
    self.includeSyntax = enabled
}
```

Yields the current value first, then every change. Saves you the read-then-subscribe dance
and the lost update in the middle of it.

**Publish a service for other plugins.**

```swift
try await context.provide(WordCounting.self) {
    WordCounting(counter: { $0.split(separator: " ").count })
}
```

Declare it in `provides`. Consumers reach it via `context.service(_:)` and get a proxy the
host brokers — never your object — so your crash becomes their thrown error rather than
their crash.

**Persist state in your own container.**

```swift
try await context.storage.setValue(recentPaths, forKey: "recent")
let recent = try await context.storage.value([String].self, forKey: "recent") ?? []
```

Scoped to your identity and inescapable. Not for secrets — a token in a plist is a token in
a backup. Use the Keychain.

**Migrate on upgrade.**

```swift
func willUpgrade(from previousVersion: SemanticVersion, context: any PluginContext) async throws {
    guard previousVersion < "2.0.0" else { return }
    // Runs before activate(_:), so nothing has read the old shape yet.
}
```
