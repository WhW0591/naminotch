import SwiftUI

/// Every provider Codenotch can read, as data.
///
/// The list was implicit until now: a case in `ProviderGlyph`, a line in
/// `AppDelegate.allProviders`, a row in the README, a note under `docs/`, and a
/// `Preferences` family check, none of which knew about the others. Adding a
/// provider meant remembering all of them, and nothing failed when one was
/// missed — a provider absent from `allProviders` is a type that exists and is
/// never read, which looks exactly like a provider with no data.
///
/// So the ids live here, and `ProviderRegistryTests` holds the other surfaces to
/// this list. It is still hand-maintained, because it has to be — the point is
/// not that a list exists, but that **drift from it fails a test** rather than
/// going unnoticed.
///
/// Not every provider appears. Two families are per instance rather than per
/// kind — a custom endpoint and a web-session site — and their ids are minted
/// from the thing they came from (`Sites.deepSeek`, an endpoint's own id). They
/// are marked `perInstance` with the token their registration is anchored to, so
/// the tests can still check that the family is wired without pretending to
/// enumerate members that do not exist until somebody adds one.
enum ProviderCatalog {
    struct Entry {
        /// The id the provider publishes, or the family's prefix.
        let id: String
        /// The type `AppDelegate.allProviders` has to name, or nil for a family
        /// registered wholesale (`+ webProviders`).
        let type: String?
        /// The label the README's provider table uses for it.
        let label: String
        /// The mark its cell draws.
        let glyph: ProviderGlyph
        /// Its note under `docs/providers/`, when its behaviour needs one.
        let note: String?
        /// True for a family whose members are not known until one is added.
        var perInstance = false
    }

    static let all: [Entry] = [
        Entry(id: ClaudeProfile.defaultID, type: "ClaudeOAuthProvider",
              label: "Claude Code", glyph: .claude, note: "docs/providers/claude-resets.md"),
        Entry(id: CodexProfile.defaultID, type: "CodexLocalProvider",
              label: "Codex", glyph: .openai, note: nil),
        Entry(id: "cursor", type: "CursorLocalProvider",
              label: "Cursor", glyph: .cursor, note: nil),
        Entry(id: AntigravityProfile.defaultID, type: "AntigravityProvider",
              label: "Antigravity", glyph: .antigravity, note: nil),
        Entry(id: "copilot", type: "GitHubCopilotProvider",
              label: "GitHub Copilot", glyph: .copilot, note: nil),
        Entry(id: "opencode", type: "OpenCodeProvider",
              label: "OpenCode", glyph: .opencode, note: nil),
        Entry(id: "commandcode", type: "CommandCodeProvider",
              label: "Command Code", glyph: .commandcode, note: nil),
        Entry(id: "grok", type: "GrokLocalProvider",
              label: "Grok", glyph: .grok, note: nil),
        Entry(id: "kimi", type: "KimiProvider",
              label: "Kimi", glyph: .kimi, note: nil),
        Entry(id: "kiro", type: "KiroProvider",
              label: "Kiro", glyph: .kiro, note: nil),
        Entry(id: "kilo", type: "KiloProvider",
              label: "Kilo", glyph: .kilo, note: nil),
        Entry(id: "devin", type: "DevinLocalProvider",
              label: "Devin", glyph: .devin, note: nil),
        Entry(id: "glm", type: "GLMProvider",
              label: "GLM", glyph: .glm, note: nil),
        Entry(id: "minimax", type: "MiniMaxProvider",
              label: "MiniMax", glyph: .minimax, note: nil),
        Entry(id: "amp", type: "AmpProvider",
              label: "Amp", glyph: .amp, note: "docs/providers/amp.md"),
        Entry(id: "apify", type: "ApifyProvider",
              label: "Apify", glyph: .apify, note: "docs/providers/apify.md"),
        Entry(id: "gemini-api", type: "GeminiAPIProvider",
              label: "Gemini API", glyph: .geminiSpark, note: nil),
        Entry(id: DSHProvider.providerID, type: "DSHProvider",
              label: "DeepSeek Harness", glyph: .deepseek, note: "docs/providers/dsh.md"),
        Entry(id: "ollama", type: "OllamaProvider",
              label: "Ollama", glyph: .ollama, note: nil),
        Entry(id: "ollama-local", type: "OllamaLocalProvider",
              label: "Ollama (Local)", glyph: .ollamaLocal, note: nil),
        Entry(id: LMStudioMetrics.providerID, type: "LMStudioLocalProvider",
              label: "LM Studio", glyph: .lmstudio, note: nil),
        Entry(id: "web", type: nil,
              label: "DeepSeek Platform", glyph: .deepseek, note: nil, perInstance: true),
        Entry(id: "custom", type: "CustomEndpointProvider",
              label: "Custom Endpoints", glyph: .third, note: nil, perInstance: true)
    ]
}
