# What this app does

An inventory, for anyone — or any session — about to change it. The point of the
list is that nothing on it may quietly stop working, and that nothing under
"Deliberately absent" may quietly come back.

**Read first, in this order:**

1. `AGENTS.md` — how to build and test here without writing outside the
   directory. The commands matter: `make test` compiles in the sandbox but its
   *run* needs one approval, and a plain `xcodebuild` fails.
2. `TASKS.md` — why things are the way they are. Its Tripwires section lists
   constraints that have already been broken once, each with the failure rather
   than the rule.
3. `docs/providers/README.md` — the eleven surfaces a new provider has to touch,
   and which of them a test holds you to.
4. This file — what exists, so that an optimisation does not remove it.

## The surfaces

### The notch

A borderless panel pinned to a screen edge, over the bezel. `Sources/Notch/`.

- **Folded and expanded.** It sits as a bar, and opens on hover into a tray of
  provider cells. Motion is `NotchViewModel`'s; the geometry is `NotchLayout`.
- **Every edge works** — top, bottom, left, right — and the hardware notch, where
  the Mac has one, merges with it. On that edge the cutout sets the size and the
  size controls do nothing, which the Appearance pane says out loud.
- **Three surfaces**: two glass styles and one opaque. Reduce Transparency
  overrides all of them.
- **The move handle** carries the notch to another edge by drag, and the settings
  disc opens the settings window.
- **A running session is a way back to its window.** Clicking a provider's cell
  raises the terminal or app its session runs in — the one blocked on you first,
  then the one working — the same jump a session row makes from the card. A cell
  with nothing running keeps the plain re-read, and never launches anything.
- **Cell budget.** How many cells fit is `NotchLayout.sessionsFitting`, and the
  card's height is bounded by the screen. See the Tripwires before touching
  either; both have been broken already.

### The hover card

`Sources/Features/TooltipCard.swift`, `UsageResetCard.swift`.

- **A ring per provider**, with its limit windows and when they reset, plus the
  percentage, the pace ring, and the weekly headline where a provider has one.
- **Session rows**: what each session is doing — working, done, or waiting on
  you — and, for Codex, what share of today's tokens it has used.
- **Today's tokens and money** where the account publishes a cost series, with
  the hours the day covers in brackets.
- **The reset card** appears for a while after a limit rolls over.
- **It is content, not chrome.** It is painted as a card; only the notch, the
  handles and the settings disc take glass. This was tried the other way round
  and reverted — see `TASKS.md`, "The glass surface".

### The menu bar

`Sources/App/StatusItemController.swift`. A menu of every provider with its
readings, a refresh, the quick toggles, and a way into Settings. The title can
carry a chosen provider's five-hour limit.

### Settings

`Sources/Settings/`, `SettingsWindowController.swift`. Eight panes:

| Pane | What it governs |
|---|---|
| Accounts | Which providers are read, and each account's name and sign-in |
| Ollama | Models running in Ollama on this Mac |
| LM Studio | Models loaded in LM Studio |
| Custom Endpoints | OpenAI-compatible APIs, local runtimes and proxies |
| Appearance | The notch's size, edge, surface, the theme, the day boundary |
| Notifications | Both channels, the sounds, and per-provider finished sounds |
| Costs | Billing per account, prices, exchange rate, plans, subscriptions |
| General | Launch at login, language, updates, erasing data |

### Notifications

`Sources/Model/NotificationChannel.swift`, `ThresholdNotifier.swift`. Two
channels — a peek in the notch, or a banner in Notification Center — and two
events that mean different things: a turn finished, and a session waiting on you.
The second rings however the session arrived at it.

### The activity window

`Sources/Costs/ActivityWindow.swift`. Turns, active time and estimated cost per
day, week, month or all time, per account or across all of them.

## The providers

Twenty-three, catalogued in `Sources/Providers/ProviderCatalog.swift` — the single
place their ids, labels and notes live. Each reads from a sign-in already on the
Mac, an endpoint the provider publishes, or a local runtime.

The README's "What it reads" section groups them by that, and is checked: no
provider may be missing from it. `ProviderCatalog.Entry.note`, where a provider
has one, names a file under `docs/providers/` — four providers have that much
detail written down (Amp, Apify, the Claude resets, the Harness) and the rest do
not, so the README and the code are the only description they have.

Adding one means touching eleven surfaces. `Tests/ProviderRegistryTests.swift`
holds several of them, including that the README names every catalogued provider.

## Invariants

Things that are load-bearing and not obvious from the code that uses them:

- **A day starts at 06:00 and can be moved.** `UsageDay` is the single definition
  and `Preferences` is the only thing that writes it. The local ledger and the
  cost log are read side by side; two boundaries would put two numbers under one
  word.
- **DeepSeek's peak windows are Beijing time, always** — `DeepSeekPricing`, with
  the statutory holidays read from `holiday-cn`. Reading them off the local clock
  puts a reader in Sydney two hours out.
- **Renaming is an identity change.** `AppIdentity` holds the old names because
  `migrateIfNeeded()` needs them: the bundle id decides which `UserDefaults`
  domain is read, the support directory holds the accounts and prices, and the
  keychain service holds the endpoint tokens. Changing any of them without the
  migration loses an existing install's data in silence.
- **The module is still called `Codenotch`.** It is internal, and renaming it
  would touch every `@testable import`, the scheme and the Makefile.
- **The card's size is bounded by the screen.** `Design.tooltipScale` is at its
  ceiling: 1.097 is where the four-window card stops fitting a 13-inch Air, and
  1.09 is there for the margin. Raising it empties the session list.
- **Nothing is typed in twice.** Every reading is borrowed from a sign-in that
  already exists; the only secrets the app holds are the ones it is given, and
  those go in the keychain.

## Deliberately absent

Removed on purpose. A merge from upstream brings all of them back — which is why
this fork does not merge from upstream.

- The Windows port, and the `windows/` tree.
- The website, the release chain and its appcast, and the update checker.
- The phone link.
- The what's-new sheet.
- Every language but English and Simplified Chinese.
- The opaque black notch surface, from the picker. The case survives as the
  fallback for a Mac without `glassEffect`.

## Verifying a change

```sh
cd notch
PATH="$PWD/../tools/xcodegen/bin:$PATH" make build   # compiles
PATH="$PWD/../tools/xcodegen/bin:$PATH" make test    # compiles and runs the suite
PATH="$PWD/../tools/xcodegen/bin:$PATH" make run     # builds and launches
```

The suite is the contract: 121 test files, ~2070 tests. It is the only thing that
notices most of what this file lists — so a change that leaves it green has not
broken anything the tests know about, which is not the same as having broken
nothing.

**Two things the suite cannot see**, and they are where the damage has been done
before:

- **Anything that is only visible.** A colour that reads correctly in dark mode
  and not in light, a button whose label and fill are both black, a card drawn
  over the wrong layer. Every one of those passed the suite.
- **Anything removed.** No test asserts that a feature is still there. The
  "Deliberately absent" list above is the mirror of that: it is the only record of
  what was taken out on purpose, and it is why a merge is not a safe operation
  here.
