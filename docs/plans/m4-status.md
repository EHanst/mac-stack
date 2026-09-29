# M4 status — "Agent surface": safe tool ecosystem (source of truth, updated after every step)

Branch: `m4-agent` (from main after PR #5) · Started 2026-09-29 · Plan: `docs/plans/2026-09-28-next-phase-plan.md` (#18 guardrails, #17 MCP client, #16 multi-workspace).
Exit criteria: **0 unconfirmed write/exec after untrusted content** (injection corpus test); MCP client tools appear in `tools/list` and in model calls.

## Working rules
- Update this file after every step; commit per step; merge/push/PR only when asked. Verify in the real app where possible.

## Queue
1. [x] **M4.1 Prompt-injection guardrails (#18)** — DONE (`StackCore/Security/UntrustedContent.swift`, `StackMCP/Agent/ToolCallGuard.swift`; 5 tests incl. a 6-payload corpus).
2. [ ] **M4.2 MCP client (#17)**: connect to user-approved external MCP servers; their tools appear to the model and in our `tools/list`; their output is untrusted.
3. [ ] **M4.3 Multi-workspace (#16)**: more than one project at once; workspace picker; tools take a workspace.
4. [ ] **M4.4 Real-app verification**: fetch→write chain prompts; corpus against the running app.

## Done
- **M4.1** Found on the way: the in-app chat loop ran write/build tools with **no approval at all**, alongside web fetch. Now one `ToolCallGuard` serves the chat and every MCP connection: output of untrusted tools (`web_fetch`, `web_search`; later MCP-client tools) is fenced in `<untrusted source=…>` (closing tag neutralised) and taints the conversation; while tainted, write/exec **always ask**, saved "Always allow" is ignored and "Always allow this" is not offered or remembered; the sheet says which outside sources are in the conversation; a new conversation clears the taint; the system prompt tells the model not to follow instructions inside `<untrusted>`. Outside MCP apps behave as before (write/exec always ask unless remembered) plus the taint rule. A clean in-app conversation runs its tools without prompts as before. Not verified in the running app yet (M4.4).
