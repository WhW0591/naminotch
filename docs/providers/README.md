---
summary: "The registration contract: every surface a provider has to touch, which of them a test holds you to, and which are conventions."
read_when:
  - Adding a provider, or renaming one
  - Removing a provider, or a feature it owned
  - Wondering why a new provider's mark, row or setting is missing
---

# Adding a provider

NamiNotch's providers are registered by hand, in several places, and nothing
about a provider's identity is derived from its type. Adding one is therefore a
list, and this is it — collected from the eight files the DeepSeek Harness
provider touched when it was added, plus the surfaces that were checked
afterwards.

The two entries marked **guarded** are enforced by
`Tests/ProviderRegistryTests.swift`. The rest are conventions: a test cannot see
them, so they are the ones that get forgotten.

## The list

| # | Surface | What goes there |
|---|---|---|
| 1 | `Sources/Providers/<Name>Provider.swift` | The provider itself. `nonisolated static let providerID` when the id is fixed, `nonisolated let id` when it is per instance (profiles). `displayName`, `glyph`, `fidelity`, and `signInRoute` if it needs one |
| 2 | `Sources/App/AppDelegate.swift` | Append to `allProviders`, in the position it should take in the cell order. If it reports agent sessions, also `monitors[providerID]`. `allProviders` is what feeds `preferences.reconcile(discoveredIDs:)` and the `UsageStore`, so a provider missing here exists and is never read |
| 3 | `Sources/Providers/ProviderGlyph.swift` | A `case`, unless it reuses a vendor mark. **guarded** in the sense below: a case whose `outline` is empty needs artwork |
| 4 | `Sources/Assets.xcassets/glyph-<rawValue>.imageset/` | The artwork. `ProviderGlyph.assetName` is `"glyph-\(rawValue)"`, with `ollamaLocal` the one exception — it draws `glyph-ollama`. **guarded** |
| 5 | `Sources/Settings/Preferences.swift` | `isDefaultOnFamily` when it should be on for a fresh install; a `Keys` entry and an `init` line for any setting of its own. `reconcile` only ever *adds*, so a provider that becomes default-on appears for new installs and never for existing ones |
| 6 | `Sources/Providers/ProviderAccount.swift` | A `SignInRoute` — `.modal`, `.openApp`, `.guidance` or `.command` — when the account can be reached or switched from here |
| 7 | `Sources/Features/TooltipCard.swift` | A section, only when the shared rows cannot say it. `LimitWindowRow`, `MoneyBreakdownView` and `SessionList` cover most providers; the DeepSeek card's "Today" row is the kind of thing that needs its own |
| 8 | `Sources/Localizable.xcstrings` | Every new user-facing string, with a `zh-Hans` translation. The project ships English and Simplified Chinese |
| 9 | `README.md` | A row in the provider table under *What it reads*, saying where the credential comes from and what the numbers mean |
| 10 | `docs/providers/<id>.md` | A note, when the behaviour is not obvious from the code — a wire quirk, a boundary, a credential rule. **guarded**: every document declares `summary` and `read_when` front matter, and every one is named in `TASKS.md` |
| 11 | `Tests/` | Tests for the parsing and the boundary cases. A provider whose wire format has a quirk should pin the quirk |

## Order

`allProviders` is the cell order, so where a provider is appended is where its
ring appears. A provider that is added to the end of the list is at the bottom of
the stack on every machine that has it.

`Preferences.isDefaultOnFamily` decides a *fresh* install only. Existing installs
keep whatever they had, because `reconcile` adds and never removes — a provider
that should be on for everybody needs saying so, not assuming.

## Removing a provider

The same list, backwards, and one extra thing: a provider leaves its reading in
`UsageArchive` and its id in `Preferences.connectedProviders`. Neither is cleaned
up by deleting the type, so a removed provider leaves a ring-less entry in the
on-list and a snapshot nothing reads. `Preferences.disconnectedIDs` is the place
that reconciles ids that no longer exist; check it after a removal.

## What a test holds you to

Three things, in `Tests/ProviderRegistryTests.swift`:

- every document under `docs/` opens with `summary` and `read_when` front matter;
- every document is named from `TASKS.md`, so nothing routes to a note nobody
  can find;
- every `ProviderGlyph` whose `outline` is empty has an `imageset` on disk,
  because those cases have no vector fallback and would draw nothing.

Everything else on the list above is a convention. If you find yourself adding a
provider and forgetting one of these, that is the signal to make it guarded —
a check derived from the code, not a line in a document.
