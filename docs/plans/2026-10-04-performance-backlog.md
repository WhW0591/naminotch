---
summary: "The size and idle-cost work deliberately left for later, with the evidence behind each item."
read_when:
  - Choosing what to optimise next for size or idle cost
  - Revisiting SwiftNIO, cost-database retention, the DeepSeek holidays, or the DMG history
---

# Codenotch — performance & size backlog

Opened 2026-10-04, out of the evaluation of the finished project. Items 1-3 were
done the same day; item 4 records the decision not to act. The rest of that
review is done and committed in `main`.

Evidence for all of this was taken from the running Debug build on the
maintainer's Mac: `sample`/`footprint`/vmmap, a `CGWindowListCopyWindowInfo`
benchmark, and the real `Application Support/NamiNotch/costs` databases.

## 1. Replace SwiftNIO with Network.framework

**Status:** done 2026-10-04 — replaced with `Network.framework`.

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

**Done 2026-10-04.** The relay is `NWListener` on the client side and
`NWConnection` upstream, with a small incremental HTTP/1.1 response decoder for
the three framings a local runtime uses (length-delimited, chunked, closed).
SwiftNIO is gone from `project.yml` and `Package.resolved` is empty, so
`DerivedData/SourcePackages` no longer exists and its ~121 MB is neither
downloaded nor compiled. The relay's live-socket tests were rewritten on the
same framework, so the test target does not pull NIO in behind the app.

## 2. Cost database: sample dedup, retention, WAL checkpoint

**Status:** done 2026-10-04 — two-week retention, per the review.

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

**Done 2026-10-04.** `recordSample` returns without inserting when both the
percentage and the reset time are unchanged; `prune(olderThanDays: 14)` drops
older `quota_sample`/`attribution`/`parse_error` rows and the WAL is folded back
with `wal_checkpoint(TRUNCATE)` once per launch. `usage_event` is the record and
is never pruned.

## 3. DeepSeek holiday list is never refreshed

**Status:** done 2026-10-04 — started at launch, refreshed monthly.

`DeepSeekHolidays.start()` is **never called** anywhere in `Sources`. So the
60-second `isPeak` recompute and the network fetch of
`cdn.jsdelivr.net/.../holiday-cn` never run. The list is only whatever was in
`UserDefaults` (`deepSeekHolidayDays`), which on a fresh install is empty, so
Chinese statutory holidays are billed at the peak rate.

**Done 2026-10-04.** The rules were checked against DeepSeek's current
announcement (the 2026-08-23 adjustment): peak is Monday-Friday 09:00-12:00 and
14:00-18:00 Beijing time, excluding Chinese statutory holidays; weekends are
off-peak all day, make-up workdays included; off-peak is half. `DeepSeekPricing`
already matched that and now states it. `DeepSeekHolidays` is started from
`AppDelegate`, records when it last fetched, re-checks monthly rather than never,
and backs a failed fetch off a day so an offline Mac does not ask once a minute.
The 60-second tick that turns the glyph over at a boundary is unchanged.

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

