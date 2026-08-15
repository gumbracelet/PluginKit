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

PluginKit is distributed as source over SwiftPM, so **the git tag is the version** — it is
what a consumer resolves and the only thing they can pin.

One number, four spellings. They are kept in step mechanically, not by hand:

| Surface | Form | Written by |
|---|---|---|
| Git tag | `v1.0.0` — annotated, message `PluginKit 1.0.0` | release path |
| GitHub Release | title `v1.0.0`, matching the ref | release path |
| CHANGELOG heading | `## [1.0.0](…) (YYYY-MM-DD)` — bare version | `pluginkit-changelog` |
| `PluginKitVersion.current` | `"1.0.0"` | `pluginkit-version set` |

The `v` prefix lives on the tag and the release title, and nowhere else. The package name is
spelled out only in the tag's annotation message.

### The one version that is not the tag

`PluginKitVersion.current` is compiled in, because a plugin's `sdkVersion` is checked against
it at discovery — before anything is loaded, when no tag is readable. It is therefore a
second source for a fact the tag already owns, and the two drifted exactly as you would
expect: v1.0.0 shipped with the constant still reading `0.1.0`.

The tag stays authoritative and the constant follows it:

```console
$ Scripts/pluginkit-version read     # 1.0.0
$ Scripts/pluginkit-version check    # fails if it disagrees with the newest tag
$ Scripts/pluginkit-version set 1.1.0
```

The release path stamps it *before* building, so the tree that is tested is the tree that is
tagged, and it lands in the same `chore(release):` commit as the changelog entry — the two
cannot be pushed apart. CI runs `check` on every push and pull request, and the tag-push
release path runs it too, since a hand-pushed tag writes no commit to stamp into. Drift now
fails a build rather than surfacing in the field as a plugin that will not load.

### What each bump promises

| Bump | Promises |
|---|---|
| **patch** (`1.0.0 → 1.0.1`) | No API change. Bug fixes and documentation. |
| **minor** (`1.0.0 → 1.1.0`) | Additive only. Existing code keeps compiling and loading. |
| **major** (`1.x → 2.0.0`) | **May change public API.** Post-1.0, the major is the breaking boundary. |

That is not just a note in a file. `VersionRange.series(of:)` implements it: for `1.x` the
next *major* is the breaking boundary, so `series(of: "1.2.3")` is `1.0.0 ..< 2.0.0`, and a
plugin declaring `sdkVersion` from `PluginManifestBuilder` gets `>=1.0.0 <2.0.0`.

The same function still implements semver's 0.x rule for anything below 1.0 — there, the
*minor* is the breaking boundary, so `series(of: "0.3.4")` is `0.3.0 ..< 0.4.0`. That applies
to your own vocabulary versions while they are pre-1.0, not to PluginKit itself any more.

Pin accordingly:

```swift
.package(url: "…/PluginKit.git", from: "1.0.0")
```

### Your vocabulary versions separately

Your contract package has its **own** semver, independent of both PluginKit's version and
your app's marketing version. It is the *vocabulary version*, and it is what plugin
compatibility is computed against. See
[extension-points.md](extension-points.md#versioning).

## Cutting a release

Three paths, all landing in the same place.

### Automatic — a releasable push to `Sources/`

A push to `main`/`master` ships a release with no human input, but only when **both** halves
hold. A `gate` job decides, and it has to answer yes three times:

1. **Did this push touch `Sources/`?** Computed with `git diff` over the pushed range, not a
   third-party action — path comparison is not worth granting write access for.
2. **Is `HEAD` our own `chore(release):` commit?** If so, stop. The release commit stamps the
   version constant, so it touches `Sources/` and would otherwise qualify.
3. **Is anything since the last tag worth releasing?** At least one `feat`, `fix`, `perf` or
   `revert`, or any breaking change.

Point 3 is the difference between a semantic release and a path-triggered one. Touching a
file under `Sources/` is not news; a fix is. Without it, a `chore` or `style` commit that
happens to live under `Sources/` mints a version whose entire changelog entry reads
*"No user-facing changes recorded"* — a version every consumer has to evaluate, for nothing.
`refactor` is excluded on the same grounds: if a refactor changed behaviour, the commit
should have said `fix` or `feat`.

When the gate declines it writes a summary saying which check failed and how to override, so
a run that ships nothing is never confused with one that did.

The bump itself is then inferred from the **conventional-commit prefixes** since the last
tag:

| Prefix | Bump |
|---|---|
| `feat!:` / `BREAKING CHANGE:` | major |
| `feat:` | minor |
| anything else (`fix`, `perf`, …) | patch |

The gate runs on `ubuntu-latest` and the release itself on `macos-15`, so deciding *not* to
release costs seconds on a cheap runner rather than minutes on one GitHub bills at ten times
the rate.

To release something the gate would decline — a docs-only change you want tagged, say —
dispatch manually. That path skips all three checks.

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
3. Stamps `PluginKitVersion.current` to that version.
4. Runs `swift test`, a release build, **and the library-evolution check** (below).
5. Generates release notes from conventional commits since the last tag.
6. Writes `CHANGELOG.md`, commits `chore(release): X.Y.Z [skip ci]` with the stamped
   constant, tags `vX.Y.Z` (annotated, `PluginKit X.Y.Z`), pushes.
7. Publishes a GitHub release titled `vX.Y.Z` with install instructions.

Everything that can fail happens in steps 1–5, **before** anything is committed. A broken
build never leaves a stray tag or changelog commit behind — both are far more annoying to
undo than to prevent.

Because step 3 writes into `Sources/`, the release's own commit looks exactly like real work
to a path filter. Two independent things stop it re-triggering: pushing with the default
`GITHUB_TOKEN` does not retrigger workflows at all, and the `gate` job refuses to release a
`HEAD` whose subject starts with `chore(release):`. Swapping in a PAT would defeat the first
but not the second.

### Tag by hand — the escape hatch

```console
$ Scripts/pluginkit-version set 1.1.0
$ git commit -am "chore(release): 1.1.0"
$ git tag -a v1.1.0 -m "PluginKit 1.1.0" && git push origin v1.1.0
```

Stamp first. The same workflow runs on `v*` tags, but this path writes no commit, so it
**checks** `PluginKitVersion.current` against the tag rather than setting it — and fails if
you skipped that step. Tag annotated (`-a`) rather than lightweight, so the tag carries a
message and an author.

It then verifies, generates notes, and publishes the GitHub release — but does **not** write
`CHANGELOG.md` or move the tag, because the tag already exists and its changelog entry is
yours to add. Only the dispatched and auto paths own the version.

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
