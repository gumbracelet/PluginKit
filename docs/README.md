# PluginKit documentation

| Guide | Read it when |
|---|---|
| [Getting started](getting-started.md) | Adding PluginKit to an app, declaring a first extension point, running a first plugin. |
| [Architecture](architecture.md) | Choosing where your code goes, or before changing PluginKit itself. |
| [Extension points](extension-points.md) | Designing the vocabulary your app publishes, and versioning it over time. |
| [Plugin development](plugin-development.md) | Writing a plugin. Manifest reference, bundle layout, the authoring loop. |
| [Capabilities and trust](capabilities.md) | Deciding what plugins may do, and what your permission UI should honestly claim. |
| [Lifecycle](lifecycle.md) | Understanding phases, activation triggers, failure handling, and diagnostics. |
| [Configuration and storage](configuration.md) | Plugin settings, managed profiles, per-plugin containers. |
| [Testing](testing.md) | Testing a plugin without a host, or a host without real plugins. |
| [Distribution](distribution.md) | Versioning policy, cutting a release, packaging plugin bundles, code signing. |
| [Troubleshooting](troubleshooting.md) | Something is wrong. Symptom → cause → fix. |

## The short version

PluginKit rests on four rules. Each one has a specific failure attached to breaking it,
which is what [troubleshooting.md](troubleshooting.md) indexes.

1. **Everything the host needs in order to *decide* is declarative data.** Identity,
   dependencies, contract versions, contribution metadata, and requested permissions all
   live in `plugin.json` and are validated before any plugin code is mapped into the
   process. Sixty installed plugins boot as sixty *resolved* and zero *loaded*.

2. **The host owns the vocabulary.** PluginKit ships no domain extension points. Your app
   declares its own in a small package that depends on `PluginKitCore` and nothing else.
   The framework provides declaration, discovery, ordering, versioning, and lazy
   resolution — and never learns a domain concept.

3. **The manifest is authoritative.** A plugin cannot contribute to a point, request a
   capability, or publish a service it did not declare. Undeclared registrations are
   *refused*, not warned about. That is a drift check for the honest case and a
   containment boundary for the dishonest one.

4. **No ambient authority.** A plugin's entire reach arrives through one `PluginContext`,
   scoped to its identity. There is no `PluginKit.shared` and no global registry, which is
   what makes "what can this plugin do?" a question with an answer.

## Reading order

**Integrating PluginKit into an app:**
[Getting started](getting-started.md) → [Extension points](extension-points.md) →
[Capabilities and trust](capabilities.md).

**Writing a plugin for someone else's app:**
[Plugin development](plugin-development.md) → [Testing](testing.md). You do not need the
host's source; `pluginkit describe --host /Applications/TheApp.app` tells you what it
publishes.

**Changing PluginKit itself:** [Architecture](architecture.md) first. The three-layer split
is what keeps hosts and plugins from dragging each other's code around, and most mistakes
are one layer doing another layer's job.

## A note on honesty

One claim in this documentation is repeated deliberately, because getting it wrong would be
the most damaging thing a plugin framework could do:

> **In-process, a capability grant is policy and disclosure — not a security boundary.**

Native code sharing an address space with your app can call any API your app can, ignore
the broker entirely, and take the process down with it. Capabilities become real
enforcement only out-of-process, where a child's sandbox profile is derived from the
granted set. `PluginRecord.trustSummary` reflects which one a given plugin is getting, and
your permission UI should too. See [capabilities.md](capabilities.md#the-honest-part).
