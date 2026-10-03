<div align="center">

# NamiNotch

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black)
![Swift](https://img.shields.io/badge/swift-5-orange)
![License](https://img.shields.io/badge/license-MIT-green)

**A small black notch pinned to a screen edge, showing how much of each coding
assistant's usage limit has been burned — and whether it is still working, done,
or waiting on you.**

</div>

## What this one changes

A personal edit of [Codenotch](https://github.com/vinzdg/codenotch), kept for one
person's use rather than offered back, so it removes as much as it adds. Every
decision behind a change — including the ones tried and then reverted — is in
[TASKS.md](TASKS.md).

**Removed.** The Windows port, the website, the release chain and its appcast, the
phone link, and the what's-new sheet. Every language but English and Simplified
Chinese.

**Renamed.** NamiNotch, with the bundle identifier `com.whw0591.naminotch`, and a
first-launch migration that carries an existing install's preferences, support
directory and endpoint tokens across — so the rename is not a fresh start.

**In Chinese.** The whole interface, including the parts that had never been
translated.

**Appearance.** The settings window follows the Mac, with a three-way choice of
its own. The notch keeps the two glass styles and drops the opaque black one.

**Sessions and sound.** Codex and the Harness finish with different sounds, and a
session that stopped to ask something rings however it got there.

**DeepSeek.** The mark turns over while the platform is at its peak rate —
09:00–12:00 and 14:00–18:00 Beijing time, Monday to Friday, excluding the
statutory holidays read from
[holiday-cn](https://github.com/NateScarlet/holiday-cn).

## What it reads

Signs in nowhere of its own: every reading comes from a sign-in already on the
Mac, from an endpoint the provider publishes, or from a local runtime's own
socket. Nothing is typed into NamiNotch except the tokens it has to be given, and
those go in the keychain.

**Through a CLI that is already signed in.** Claude Code, Codex, Cursor (or
`cursor-agent`), Gemini API (via CLI, OpenCode or Hermes), Grok,\1GLM, Kimi, Kiro, OpenCode,
Command Code, GitHub Copilot (`gh`), Amp, Apify, Kilo.

**Through a sign-in of its own, in a NamiNotch window.** DeepSeek Platform,
MiniMax, QianwenAI — the session lives in the app and nothing is read from a
browser's cookies.

**From a local runtime.** Ollama (Local) and LM Studio, including loaded models, memory,
context and generation speed.

**From this Mac's files or endpoints.** Claude Desktop's cached response,
Antigravity's language server or quota endpoint, Devin's `GetUserStatus`, and the
balances DeepSeek Harness files in `~/.dsh/.credentials.yaml`.

**Whatever you add yourself.** Custom Endpoints: any OpenAI-compatible API, local
runtime or proxy, given a usage URL and a unit — spend, tokens or credits — and
read on its own terms.

Per-provider detail — what each one shows and where the figure comes from — is
under [docs/providers](docs/providers).

## Running it

```sh
PATH="$PWD/../tools/xcodegen/bin:$PATH" make build   # compiles
PATH="$PWD/../tools/xcodegen/bin:$PATH" make test    # compiles and runs the suite
PATH="$PWD/../tools/xcodegen/bin:$PATH" make run     # builds and launches
```

`make gen` regenerates the Xcode project from `project.yml`; the project itself is
generated and should not be edited. [AGENTS.md](AGENTS.md) has the flag set that
keeps every write inside the working directory, which is what the commands above
assume.

## Where to look

| | |
|---|---|
| [FEATURES.md](FEATURES.md) | Everything the app does, and what must not stop working |
| [TASKS.md](TASKS.md) | Why things are the way they are, and what has already been broken once |
| [docs/providers](docs/providers) | Detail for the providers that have it, and the contract for adding one |
| [docs/design](docs/design) | The notch's geometry, the card's layout, the provider artwork |

Build and test instructions live in the workspace's `AGENTS.md`, one directory
above this repository — it is not part of the project and does not travel with it.

## Licence

MIT. See [LICENSE](LICENSE).
