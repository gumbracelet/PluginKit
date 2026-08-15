# Distribution

Versioning policy, cutting a release, packaging plugin bundles, and the two macOS
constraints that decide what your app can ship.

- [Versioning policy](#versioning-policy)
- [Cutting a release](#cutting-a-release)
- [The changelog](#the-changelog)
- [Library evolution](#library-evolution)
- [Packaging a plugin bundle](#packaging-a-plugin-bundle)
- [Code signing and trust](#code-signing-and-trust)
- [The App Store constraint](#the-app-store-constraint)
- [Roadmap](#roadmap)

## Versioning policy

PluginKit is distributed as source over SwiftPM. **The git tag is the version** — there is no
`version` field in a file that could drift from what a consumer resolves.

While pre-1.0, semver's 0.x rule applies and PluginKit follows it in code as well as in
policy:

| Bump | Promises |
|---|---|
| **patch** (`0.1.0 → 0.1.1`) | No API change. Bug fixes and documentation. |
| **minor** (`0.1.0 → 0.2.0`) | **May change public API.** Pre-1.0, the minor is the breaking boundary. |
| **major** (`0.x → 1.0.0`) | The API is stable from here; breaking changes need another major. |

That is not just a note in a file. `VersionRange.series(of:)` implements it: for `0.x` the
next *minor* is the breaking boundary, so `series(of: "0.3.4")` is `0.3.0 ..< 0.4.0`. A
plugin declaring `sdkVersion` from `PluginManifestBuilder` gets `>=0.1.0 <0.2.0`, not
`>=0.0.0 <1.0.0` — which would have let a plugin built against an early prototype load into
a host that had since changed the contract underneath it.

Pin accordingly:

```swift
// Pre-1.0: pin the minor.
.package(url: "…/PluginKit.git", .upToNextMinor(from: "0.1.0"))

// Post-1.0: the usual.
.package(url: "…/PluginKit.git", from: "1.0.0")
```

### Your vocabulary versions separately

Your contract package has its **own** semver, independent of both PluginKit's version and
your app's marketing version. It is the *vocabulary version*, and it is what plugin
compatibility is computed against. See
[extension-points.md](extension-points.md#versioning).

## Cutting a release

Three paths, all landing in the same place.

### Automatic — a push to `Sources/`

Any change under `Sources/` merged to `main`/`master` ships a release with no human input.
The workflow infers the bump from the **conventional-commit prefixes** of the commits since
the last tag:

| Prefix | Bump |
|---|---|
| `feat!:` / `BREAKING CHANGE:` | major |
| `feat:` | minor |
| anything else (`fix`, `refactor`, …) | patch |

A `paths`-filter guard confirms `Sources/` actually changed, so the release's own
`CHANGELOG.md` commit (which never touches `Sources/`) does not re-trigger a loop. This is
the intended path for routine work — push to a branch, merge to `main`, a tag lands
automatically.

### Manual dispatch — for the unusual cases

GitHub → Actions → **Release** → Run workflow:

| Input | |
|---|---|
| `version_type` | `auto` / `patch` / `minor` / `major` |
| `dry_run` | verify and generate notes, but do not commit, tag, or publish |

`auto` behaves exactly like the push path: infer the bump from commit prefixes. Pick
`patch` / `minor` / `major` when you want to override the inference — most often a
deliberate major when public API changed shape but the commit did not say so.

The workflow then:

1. Reads the newest `v*` tag and computes the next version.
2. Fails if that tag already exists.
3. Runs `swift test`, a release build, **and the library-evolution check** (below).
4. Generates release notes from conventional commits since the last tag.
5. Writes `CHANGELOG.md`, commits `chore(release): X.Y.Z [skip ci]`, tags `vX.Y.Z`, pushes.
6. Publishes a GitHub release with install instructions.

Everything that can fail happens in steps 1–4, **before** the repository is touched. A
broken build never leaves a stray tag or changelog commit behind — both are far more
annoying to undo than to prevent.

Pushing with the default `GITHUB_TOKEN` deliberately does not retrigger workflows, which is
what stops the new tag from starting a second release. Swapping in a PAT would reintroduce
that loop.

### Tag by hand — the escape hatch

```console
$ git tag -a v0.2.0 -m "PluginKit 0.2.0" && git push origin v0.2.0
```

The same workflow runs on `v*` tags. It verifies, generates notes, and publishes the GitHub
release — but does **not** write `CHANGELOG.md` or move the tag, because the tag already
exists and its changelog entry is yours to add. Only the dispatched and auto paths own the
version.

### Locally

Rehearse the identical sequence before trusting CI with it:

```console
$ Scripts/pluginkit-release minor --dry-run    # verify, print notes, write nothing
$ Scripts/pluginkit-release auto --publish     # infer the bump, then push + `gh release create`
$ Scripts/pluginkit-release patch --publish    # force a patch, then push + release
```

It refuses to run on a dirty tree or a shallow clone. A shallow clone has no tag history, so
the computed version would be silently wrong — worse than failing, because the mistake
ships.

## The changelog

`Scripts/pluginkit-changelog` reads conventional commits and emits the
conventional-changelog format: emoji sections, a compare link in the heading, one linked
commit per entry. No Node, no dependencies, bash 3.2.

```console
$ Scripts/pluginkit-changelog next-version minor   # 0.2.0
$ Scripts/pluginkit-changelog next-version auto    # infer: breaking -> major, feat -> minor, else patch
$ Scripts/pluginkit-changelog notes 0.2.0          # preview — writes nothing
$ Scripts/pluginkit-changelog update 0.2.0         # prepend to CHANGELOG.md
```

Commit types, in the order they appear:

| Type | Section | | Type | Section |
|---|---|---|---|---|
| `feat` | ✨ Features | | `revert` | ⏪ Reverts |
| `fix` | 🐛 Bug Fixes | | `refactor` | ♻️ Code Refactoring |
| `perf` | ⚡ Performance | | `docs` | 📝 Documentation |
| `test` | ✅ Tests | | `build` | 📦 Build System |
| `ci` | 👷 CI/CD | | `style` | 💄 Styles |

`chore` is deliberately omitted — a changelog is for people consuming the library, and a
dependency bump is not news to them.

A `!` before the colon, or a `BREAKING CHANGE:` footer, additionally lists the commit under
**⚠ BREAKING CHANGES**, which leads the entry. Breaking changes are the only thing in a
library's changelog that forces a reader to act, so they go first.

```
feat(host): add contract adapters
fix(core): reject 0.x minors as compatible
feat(sdk)!: rename PluginPrincipal.makePlugin
```

### Why the bump is normally chosen, not inferred

Tools like semantic-release derive the bump from commit types. PluginKit's default is to ask
a human, because for a library the minor-versus-major decision depends on whether *public
API changed shape* — which a commit prefix does not reliably capture. That distinction
matters more here than in most packages: `PluginKitCore` sits on a binary boundary between
separately-compiled host and plugin code, so an unnoticed breaking change does not produce a
compile error for the person affected. It produces a plugin that will not load in the field.

The automatic `Sources/` path and `next-version auto` therefore use conventional-commit
prefixes as a **fallback**: a `BREAKING CHANGE` or `feat!:` forces a major, `feat:` a minor,
everything else a patch. It is a sensible default, not a guarantee — if your commit history
did not capture an API-shape change, dispatch manually and pick the bump yourself.

## Library evolution

`PluginKitCore` and `PluginKitSDK` are the only targets on a binary boundary between a host
and a separately-compiled plugin. If either stops compiling under library evolution, a
plugin built against one release cannot be loaded by a host linking another — and nothing
else in the build would say so.

Both CI and `Scripts/pluginkit-release` check it on every change:

```console
$ swift build -c release --target PluginKitCore -Xswiftc -enable-library-evolution
$ swift build -c release --target PluginKitSDK  -Xswiftc -enable-library-evolution
```

It is deliberately **not** set in `Package.swift`. `.unsafeFlags` would make the package
unusable as a git dependency, and evolution mode only matters when you are actually shipping
a binary boundary. If you distribute your host's contract package as a prebuilt framework,
build it with the flag too.

## Packaging a plugin bundle

```
WordCount.plugin/
└── Contents/
    ├── Info.plist          NSPrincipalClass = WordCountEntry
    ├── MacOS/WordCount     the dylib
    └── Resources/
        └── plugin.json
```

Install to `~/Library/Application Support/<AppName>/Plugins/`. `.plugin` and `.bundle`
extensions are both recognised.

### Single-copy linkage — the mistake worth avoiding

Ship your host's contract package as a **dynamic framework embedded in the host app**, and
have plugins link it *without* embedding it:

```
AcmeEditor.app/Contents/Frameworks/AcmeEditorPluginAPI.framework   ← the one and only copy
AcmeEditor.app/Contents/PlugIns/Foo.plugin                          ← links, does not embed
~/Library/Application Support/AcmeEditor/Plugins/Bar.plugin         ← same
```

Plugins set `LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks`. That resolves against
the **host executable's** bundle, so it works identically for plugins inside `Contents/PlugIns`
and for user-installed plugins anywhere on disk.

If two plugins each embed their own copy, you get duplicate type metadata in one address
space and `as?` fails across the seam while every version number involved looks correct.
Days to diagnose in the field. `CodeSigningTrustPolicy(hostProvidedFrameworks:)` refuses a
bundle that does it, up front:

```swift
configuration.trustPolicy = CodeSigningTrustPolicy(
    firstPartyTeamIDs: ["ABCDE12345"],
    hostProvidedFrameworks: ["AcmeEditorPluginAPI"]
)
```

Out-of-process runtimes are immune — separate address space, so each side has its own copy
and only the wire format has to agree. Another reason isolation is the safer default.

### The load-time handshake

`PluginPrincipal.contractVersions()` is read **before** `makePlugin()` and cross-checked
against the manifest. A plugin linked against an incompatible contract can fail in ways
indistinguishable from memory corruption once its code is running, so the check happens while
backing out is still clean. When the two disagree, the manifest is the one that lied — it is
a file an author can edit without recompiling, and the binary's answer is not.

## Code signing and trust

```swift
configuration.trustPolicy = CodeSigningTrustPolicy(
    firstPartyTeamIDs: ["ABCDE12345"],
    trustedTeamIDs: ["FGHIJ67890"],     // empty = any valid signature
    unsignedTrust: nil,                 // nil = refuse unsigned
    refusesQuarantined: true,
    hostProvidedFrameworks: ["AcmeEditorPluginAPI"]
)
```

Sign a plugin bundle as you would any other code:

```console
$ codesign --force --options runtime --timestamp \
           --sign "Developer ID Application: You (TEAMID)" WordCount.plugin
$ xcrun notarytool submit WordCount.plugin.zip --keychain-profile notary --wait
$ xcrun stapler staple WordCount.plugin
```

`unsignedTrust: nil` is the default and refuses unsigned bundles. A development host that
needs them should say so explicitly, in one place, rather than having the framework quietly
permit it everywhere.

## The App Store constraint

Two facts decide what your app can ship, and they are worth stating plainly.

**Library validation.** With the hardened runtime enabled, your app can only load code
signed by its own team unless it carries
`com.apple.security.cs.disable-library-validation` — an entitlement that is not realistically
approvable for the App Store.

**Therefore:** *App Store + third-party native plugins ⇒ app extension or script runtime.
There is no third option.*

| Distribution | First-party plugins | Third-party plugins |
|---|---|---|
| **Direct / notarised** | in-process ✅ | in-process with the entitlement, or isolated |
| **App Store** | in-process ✅ (same team) | app extension or script runtime only |

If you are shipping to the App Store, set `InProcessPluginRuntime(loadsBundles: false)` and
ship registered (compiled-in) plugins only until an isolating runtime is available. That is
the honest configuration, and it makes the constraint visible in code rather than discovered
at review.

## Roadmap

Ordered by what unblocks the most:

1. **`PluginKitXPC`** — the runtime that turns capability grants from policy into
   enforcement. Every seam it needs is already in place, and `PluginHarness`'s serializing
   transport already proves contracts survive the boundary.
2. **`ContributionAdapter`** — translate an old contract major forward instead of dropping
   it. Today a contribution outside the accepted range is reported with both versions and the
   host's guidance, but cannot be automatically migrated.
3. **`PluginKitUI`** — the manager pane and consent sheet, so every host stops rewriting them.
   `PluginRecord` already carries everything they need.
4. **Macros** — `#PluginEntry` and manifest generation, once the hand-written path has been
   used enough to know what it should generate. Drift is already *caught* by
   `PluginHarness.drift()`; macros would make it impossible instead.

Before any of that, the gate worth insisting on: build **two structurally different hosts**
on this foundation — a document-based GUI app and a headless daemon — plus **one plugin
written by someone with no access to either host's source, using only `pluginkit describe`**.
The first two test the host API. Only the third tests whether the authoring story works.
