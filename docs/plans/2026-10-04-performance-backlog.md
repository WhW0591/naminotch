# Codenotch — performance & size backlog

Opened 2026-10-04, out of the evaluation of the finished project. Items 1-3 are
deliberately deferred; item 4 records the decision not to act. The rest of that
review is done and committed in `main`.

Evidence for all of this was taken from the running Debug build on the
maintainer's Mac: `sample`/`footprint`/vmmap, a `CGWindowListCopyWindowInfo`
benchmark, and the real `Application Support/NamiNotch/costs` databases.

## 1. Replace SwiftNIO with Network.framework

**Status:** deferred, awaiting a decision on scheduling.

SwiftNIO is pulled in by exactly one file,
`Sources/Sessions/OllamaRelayServer.swift`, which is a loopback HTTP relay used
only while "Ollama metrics" is switched on. It brings four SwiftPM packages
(`swift-nio`, `swift-atomics`, `swift-collections`, `swift-system`).

- `Package.resolved` / `project.yml` pin them.
- A clean build materialises **~121 MB** under
  `DerivedData/SourcePackages` (31 MB checkouts + 90 MB repositories) and
  compiles NIO from source.
- Release binary size is smaller but real.

`Network.framework` (`NWListener`/`NWConnection`) ships with macOS and is the
natural replacement for a localhost proxy. The relay's job is: accept an HTTP
request, forward it to the real Ollama port, stream the response back, and tap
the SSE body for thinking/performance. A rewrite is self-contained but needs a
regression pass over the thinking-stream and performance parsers.

**Open question:** worth it now, or once the binary/bundle size matters?

## 2. Cost database: sample dedup, retention, WAL checkpoint

**Status:** deferred, to discuss.

`CostStore.recordSample` inserts a row on **every** usage publication, even when
the percentage has not moved, and nothing is ever pruned. On the maintainer's
machine the Codex account had:

| table | rows |
|---|---|
| `usage_event` | 6,729 |
| `quota_sample` | **15,458** |
| `attribution` | 130 |

`agentcost-codex.sqlite` was 3.4 MB with a **2.4–3.2 MB WAL** that never
truncates. Left running, this grows without bound. `CostModel.reload()` then
re-runs full-table aggregates (`allWeights()`, `tokenUsage()`) over a table that
only gets bigger.

Notes already applied in the same review that make this cheaper: `snapshots`
publication is deduped, so the *rate* of inserts dropped; `PRAGMA cache_size` is
capped at 512 KiB.

**Proposed:** skip the insert when `pct` is unchanged; add a retention window
(e.g. 90 days) for `quota_sample`/`attribution`/`parse_error`; checkpoint WAL on
close / periodically.

**Open question:** how much history does the Activity timeline want to keep?

## 3. DeepSeek holiday list is never refreshed

**Status:** deferred, to discuss (functional bug, found while auditing timers).

`DeepSeekHolidays.start()` is **never called** anywhere in `Sources`. So the
60-second `isPeak` recompute and the network fetch of
`cdn.jsdelivr.net/.../holiday-cn` never run. The list is only whatever was in
`UserDefaults` (`deepSeekHolidayDays`), which on a fresh install is empty, so
Chinese statutory holidays are billed at the peak rate.

The class comment says the announcement "updates it daily by CI" and cannot be
derived — which reads as "once a year, plus the source's daily re-publication".
So the fix is probably: call `start()` from the app (e.g. in `AppDelegate`), or
make it observable-driven by `ProviderGlyphView`, and confirm the cache TTL is
the intended one year.

**Open question:** was `start()` dropped on purpose (to avoid a background
fetch), or is this a regression?

## 4. Git history still carries the release DMGs (~180 MB)

**Status:** decided 2026-10-04 — history kept as it is; the purge was not done.

`.git` is **202 MB**, of which **179.8 MB** is 19 committed
`site/Codenotch*.dmg` release binaries (12.5 MB / 12.4 MB / 11.9 MB ... down to
5.5 MB). They are in history only; the working tree has no `site/` directory and
no `.dmg` is tracked today. `git gc` cannot drop them because they are
reachable from old commits and tags.

Why this is not a mechanical `rm`:

- The clone is **shallow** — `.git/shallow` lists `6e8b0f8`, which is itself one
  of the DMG-appcast commits. A rewrite of `main` therefore crosses the shallow
  boundary.
- Two remotes: `origin` = `WhW0591/naminotch` (the fork), `upstream` =
  `vinzdg/codenotch`. Local `main` is level with `origin/main` and 48 commits
  ahead of `upstream/main`.
- **22 tags** (`v1.5.0` … `v1.20.0`, plus `preview`, `known-good-2026-10-04`,
  `pre-upstream-picks`) point into the DMG-bearing history. Rewriting or deleting
  released-version tags breaks anything that pin them.

A durable purge therefore means, in order:

```sh
git fetch --unshallow                    # a shallow rewrite is not reliable
git filter-repo --path site --invert-paths   # or BFG; rewrites main + tags
git push --force origin main
git push --force origin --tags           # destructive for anyone who has cloned
```

**Decision (2026-10-04):** keep the history. The releases are already published
on GitHub, the fork carries an `upstream` remote and 22 tags, and rewriting all
of them would diverge the fork permanently for a one-time ~180 MB saving. The
local clone keeps its full history so `pull`/`push` behave normally; the ~180 MB
is part of the shared history, not a disposable cache. Only genuinely disposable
local artefacts were removed (build products, caches, scratch), about 1.15 GB.

