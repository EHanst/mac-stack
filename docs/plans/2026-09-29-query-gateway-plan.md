# Query Gateway plan

**Date:** 2026-09-29 · **Status:** approved by delegation ("plan, then implement without bothering me")

## Why

`chat`/`embed`/`list_models` (MCP) and `/v1/models`, `/v1/embeddings` (HTTP) each call `InferenceService` (which owns `Router`) directly. Each repeats its own input validation, size limits and error translation (`OpenAIError.from` for HTTP, `error.localizedDescription` for MCP). A new endpoint means a third copy.

## What (interpretation, stated as an assumption)

The "layer of abstraction in the endpoint that sends queries to our internal router" is a single **in-process** `QueryGateway` actor in `StackCore`. Endpoints translate their wire format to typed queries and back; the gateway owns validation, limits, routing (via `InferenceService` → `Router`), and one error contract. No HTTP or sockets between components (CLAUD.md rule 1).

Scope enforcement stays where it is (`MCPToolHost` scope check, `APIRequestContext.require`); the gateway does not duplicate it, so there is one owner.

## Interface

```swift
public actor QueryGateway {
    init(inference: InferenceService)
    func chat(_ q: ChatQuery) async throws -> ChatAnswer      // collected answer
    func embed(_ q: EmbedQuery) async throws -> EmbedAnswer
    func models() async -> [InferenceService.ModelListing]
}
struct ChatQuery  { messages, model: String?, maxTokens: Int?, origin: QueryOrigin }
struct EmbedQuery { texts, model: String?, origin }
enum QueryOrigin  { case mcp, http }          // picks scheduler priority (.api for both today)
enum QueryError: LocalizedError, Equatable    // the only error the gateway throws
  invalid(param, message) · unknownModel · blockedByPrivacy · budgetExhausted
  noModelAvailable · contextTooLarge · upstream(String) · cancelled · internal
```

Limits enforced once: `maxTokens` clamped to 1…8192 (default 1024), embed batch ≤ 256 and non-empty, chat needs ≥1 non-empty message.
Timeouts/retries: unchanged and inherited. `InferenceService` already falls back to the next provider before first output; the gateway adds none (a second retry layer would double-run GPU work).

## Alternatives considered

1. **Gateway in front of `InferenceService` (chosen).** Small, testable, keeps Router pure.
2. Fold the logic into `InferenceService`. Mixes wire-level validation into the routing actor; rejected.
3. Protocol-per-endpoint adapters. More types, no shared contract; rejected (YAGNI).

## Migration

- MCP `chat`, `embed`, `list_models` → gateway. HTTP `/v1/models`, `/v1/embeddings` → gateway. `OpenAIError.from` learns `QueryError`.
- Not migrated (follow-ups, listed so they aren't lost): HTTP `/v1/chat/completions` (streaming + usage + route headers), the app UI chat paths in `AppServices` (tools, priorities, compaction), `optimize_prompt`. Old paths keep working; nothing is shimmed because nothing is removed.

## Steps

1. `QueryError` + mapping from existing errors — tests.
2. `QueryGateway` — tests (limits, mapping, pin/unknown model, local-only privacy refusal, collected answer).
3. Migrate MCP tools; existing `MCPToolHostTests` must stay green.
4. Migrate HTTP models/embeddings; `StackAPIServerTests` stay green.
5. Full `swift test`; rebuild app; relaunch; call `list_models`, `chat`, `embed` through `vibe-mcp` for real, plus error paths (bad model, empty prompt).
6. Record standing tool-use rules in `CLAUD.md` (RAG/`search_code` only after verified; it needs a workspace attached in the app).
