# Model Style Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the Model dropdown (`BriefPane` Picker bound to `TargetProfile.modelFamily`) reflect real per-family prompt style.

**Architecture:** `ModelPromptProfile` becomes the typed source of per-family style facts (distilled once from vendor docs, no runtime dependencies). `PromptLint` gains deterministic per-family checks. The optimizer's rewriter guidance and `BriefCompiler` item rendering consume the typed fields. System prompts stay fixed.

**Tech Stack:** Swift, XCTest (`swift test`). Tests live in `Tests/KokoroTests/`.

**Spec:** the chat discussion of 2026-10-01 (dropdown audit). Current state: 4 families (`claude`, `gpt`, `local`, `generic`) in `Sources/StackCore/Prompts/ModelPromptProfile.swift`, mapped in `TargetProfile.swift`, picker at `Sources/Kokoro/UI/Briefs/BriefPane.swift:147`.

## Global Constraints
- Test first; smallest edit per pass; don't reword prompts you aren't fixing (CLAUDE.md).
- No persona, voice or greeting text.
- System prompts fixed; per-request style text goes in the user turn.
- `PromptPrinciples.rules` and `PromptPrinciples.wordLimit` untouched.
- Prefer deterministic checks (lint) to more prompt wording.
- Not adopted, by decision: LiteLLM, HF chat templates, Instructor, Outlines (they cover API roles, special tokens and JSON schema, not pasted-text prompts).
- Commit, push, PR only when asked.

## Review Focus
- Existing saved briefs with `modelFamily` values `claude`/`gpt`/`local`/`generic` still load and compile identically (tests must pin it).
- Unknown or legacy family string falls back to `.generic`, not a crash.
- A local model whose id contains `deepseek` or `r1` resolves to `.localSmall`, not `.reasoning`.
- Lint rules don't fire on empty text and don't false-positive on prose that merely contains `<` (e.g. "a < b").
- Compiled output for the existing four families is byte-identical unless a field was deliberately changed.

---

### Task 1: Facts file (research, no code)
**Files:** Create `docs/plans/model-style-facts.md`
**Interfaces:** Produces the verified values used in tasks 2–4.

- [ ] **Step 1:** One section per family: Claude, GPT, Gemini, reasoning (o-series, DeepSeek-R1), local. Cover only pasted-text style: delimiters, whether to ask for reasoning, output-format placement, length.
- [ ] **Step 2:** Each claim gets source URL and access date. Sources: Anthropic prompt-engineering docs, OpenAI cookbook/prompting guides, Gemini prompting guide, DeepSeek-R1 README.
- [ ] **Step 3:** Mark anything not confirmed in a source `[unverified]`. Do not encode `[unverified]` claims in tasks 2–4.

### Task 2: Typed fields on `ModelPromptProfile`
**Files:** Modify `Sources/StackCore/Prompts/ModelPromptProfile.swift`; Create `Tests/KokoroTests/ModelPromptProfileTests.swift`
**Interfaces:** Produces `ReasoningCuePolicy`, `Verbosity`, new init params (all defaulted), `rewriterGuidance: String`. Reuses existing `Structure` (no second delimiter enum).

- [ ] **Step 1: Failing test**
```swift
import XCTest
@testable import StackCore

final class ModelPromptProfileTests: XCTestCase {
    func testLegacyInitStillCompilesWithDefaults() {
        let p = ModelPromptProfile(family: "t", displayName: "T", structure: .xmlTags,
                                   maxUsefulTokens: 100, guidance: "G")
        XCTAssertEqual(p.reasoningCue, .allow)
        XCTAssertEqual(p.verbosity, .normal)
        XCTAssertEqual(p.rewriterGuidance, "G")
    }

    func testRewriterGuidanceAppendsTypedFields() {
        let p = ModelPromptProfile(family: "r", displayName: "R", structure: .plainNumbered,
                                   maxUsefulTokens: 100, guidance: "G",
                                   reasoningCue: .avoid, outputFormatWording: "End with the format.",
                                   verbosity: .concise)
        XCTAssertTrue(p.rewriterGuidance.contains("Do not ask the model to think step by step."))
        XCTAssertTrue(p.rewriterGuidance.contains("End with the format."))
        XCTAssertTrue(p.rewriterGuidance.contains("Keep the prompt short."))
    }
}
```
- [ ] **Step 2:** `swift test --filter ModelPromptProfileTests` → FAIL (members missing).
- [ ] **Step 3: Implement** (defaults keep the four existing statics byte-identical: `.allow`, empty wording, `.normal`)
```swift
public enum ReasoningCuePolicy: String, Sendable, Equatable { case allow, avoid }
public enum Verbosity: String, Sendable, Equatable { case concise, normal }

// inside ModelPromptProfile
public let reasoningCue: ReasoningCuePolicy
public let outputFormatWording: String
public let verbosity: Verbosity

public init(family: String, displayName: String, structure: Structure, maxUsefulTokens: Int,
            guidance: String, reasoningCue: ReasoningCuePolicy = .allow,
            outputFormatWording: String = "", verbosity: Verbosity = .normal) {
    self.family = family; self.displayName = displayName; self.structure = structure
    self.maxUsefulTokens = maxUsefulTokens; self.guidance = guidance
    self.reasoningCue = reasoningCue; self.outputFormatWording = outputFormatWording
    self.verbosity = verbosity
}

/// `guidance` plus the typed style rules, for the rewriter.
public var rewriterGuidance: String {
    var parts = [guidance]
    if reasoningCue == .avoid { parts.append("Do not ask the model to think step by step.") }
    if !outputFormatWording.isEmpty { parts.append(outputFormatWording) }
    if verbosity == .concise { parts.append("Keep the prompt short.") }
    return parts.joined(separator: " ")
}
```
- [ ] **Step 4:** `swift test` → all pass.
- [ ] **Step 5:** Commit (when asked): `feat: typed style fields on ModelPromptProfile`.

### Task 3: New families, Claude Code surface variant, picker
**Files:** Modify `ModelPromptProfile.swift`, `TargetProfile.swift`, `BriefPane.swift` (picker ~147–152); Test `Tests/KokoroTests/ModelPromptProfileTests.swift`, `TargetProfileTests.swift`
**Interfaces:** Consumes Task 2 init. Produces `.gemini`, `.reasoning`, `.claudeCode`; `TargetProfile.make` unchanged signature. Values come from Task 1 facts file — the strings below are placeholders to replace with verified wording, not final copy.

- [ ] **Step 1: Failing tests**
```swift
func testProviderMapping() {
    XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "gemini-2.5-pro").family, "gemini")
    XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "o3-mini").family, "reasoning")
    XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "deepseek-r1").family, "reasoning")
    XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "local:deepseek-r1-distill").family, "local")
}

func testLegacyFamiliesUnchangedAndUnknownFallsBack() {
    XCTAssertEqual(TargetProfile.make(modelFamily: "gpt", surface: .other).model, .gpt)
    XCTAssertEqual(TargetProfile.make(modelFamily: "nonsense", surface: .other).model, .generic)
}

func testClaudeCodeSurfaceIsConcise() {
    let t = TargetProfile.make(modelFamily: "claude", surface: .claudeCode)
    XCTAssertEqual(t.model.verbosity, .concise)
    XCTAssertEqual(t.model.structure, .xmlTags)
    XCTAssertEqual(TargetProfile.make(modelFamily: "claude", surface: .claudeDesktop).model, .claude)
}
```
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: Implement**
```swift
public static let gemini = ModelPromptProfile(
    family: "gemini", displayName: "Gemini", structure: .markdown, maxUsefulTokens: 30_000,
    guidance: "The target is Gemini. Use a short Markdown brief: a one-line goal, short bullets, then the exact output format.",
    outputFormatWording: "Repeat the required output format as the last line.")
public static let reasoning = ModelPromptProfile(
    family: "reasoning", displayName: "Reasoning model", structure: .plainNumbered, maxUsefulTokens: 10_000,
    guidance: "The target is a reasoning model. State the problem, the constraints and the required output.",
    reasoningCue: .avoid, outputFormatWording: "End with the required output format.", verbosity: .concise)
public static let claudeCode = ModelPromptProfile(
    family: "claude", displayName: "Claude Code", structure: .xmlTags, maxUsefulTokens: 12_000,
    guidance: "The target is Claude Code, which reads the repo itself. Reference files by path and state what done looks like.",
    verbosity: .concise)
```
`profile(forProviderID:)`: keep the `local:`/bonsai/qwen/mlx line **first**, then add `gemini`, then reasoning (`hasPrefix("o1")`, `hasPrefix("o3")`, `contains("deepseek-r1")`), then the existing claude and gpt lines. (Do not match bare `"r1"`.)

`TargetProfile`: add `case "gemini": .gemini`, `case "reasoning": .reasoning`; make `model` surface-aware:
```swift
public var model: ModelPromptProfile {
    modelFamily == "claude" && surface == .claudeCode ? .claudeCode : Self.profile(forFamily: modelFamily)
}
```
and have `make` use `.model`-equivalent logic for `tokenBudget` (build the `TargetProfile` first, then read `.model.maxUsefulTokens`). Picker: add `Text("Gemini").tag("gemini")` and `Text("Reasoning").tag("reasoning")` beside the existing options (confirm the exact ForEach/Text structure in `BriefPane.swift:147`).
- [ ] **Step 4:** `swift test` → pass. Open the app (`run-kokoro` skill) and confirm the dropdown lists the new options.
- [ ] **Step 5:** Commit (when asked).

### Task 4: Per-family lint rules
**Files:** Modify `Sources/StackCore/Prompts/PromptLint.swift` (Rule enum line 8, Context lines 16–23, `check` line 25); Test `Tests/KokoroTests/PromptLintTests.swift`; wire `modelFamily` at the existing call sites of `PromptLint.check` (grep for them).
**Interfaces:** Produces `Rule.unbalancedXML`, `.chainOfThought`, `.goalNotFirst`; `Context.modelFamily: String?` (defaulted, so existing calls compile).

- [ ] **Step 1: Failing tests** (append to the existing file, match its style)
```swift
func testClaudeUnbalancedXML() {
    let c = PromptLint.Context(modelFamily: "claude")
    XCTAssertTrue(PromptLint.check("Fix this. <task>do the thing", context: c).contains { $0.rule == .unbalancedXML })
    XCTAssertFalse(PromptLint.check("Fix this. <task>do the thing</task>", context: c).contains { $0.rule == .unbalancedXML })
    XCTAssertFalse(PromptLint.check("Return nil when a < b in Parser.swift", context: c).contains { $0.rule == .unbalancedXML })
}
func testReasoningFlagsChainOfThought() {
    let c = PromptLint.Context(modelFamily: "reasoning")
    XCTAssertTrue(PromptLint.check("Fix the parser. Think step by step.", context: c).contains { $0.rule == .chainOfThought })
    XCTAssertFalse(PromptLint.check("Fix the parser in Parser.swift.", context: c).contains { $0.rule == .chainOfThought })
}
func testGPTGoalFirst() {
    let c = PromptLint.Context(modelFamily: "gpt")
    XCTAssertTrue(PromptLint.check("- return nil\n- add tests for Parser.swift", context: c).contains { $0.rule == .goalNotFirst })
    XCTAssertFalse(PromptLint.check("Add tests for Parser.swift.\n- return nil", context: c).contains { $0.rule == .goalNotFirst })
}
func testNoFamilyRulesWithoutFamily() {
    XCTAssertTrue(PromptLint.check("Think step by step <a>", context: .init()).allSatisfy {
        ![.unbalancedXML, .chainOfThought, .goalNotFirst].contains($0.rule) })
}
```
- [ ] **Step 2:** `swift test --filter PromptLintTests` → FAIL.
- [ ] **Step 3: Implement.** Add rule cases; `public var modelFamily: String?` plus init param; before `return out` in `check`:
```swift
switch context.modelFamily {
case "claude" where unbalancedTags(trimmed):
    out.append(.init(rule: .unbalancedXML, message: "A tag is opened but not closed.", suggestion: nil))
case "reasoning" where containsAny(lower, ["step by step", "show your reasoning", "think aloud", "chain of thought"]):
    out.append(.init(rule: .chainOfThought, message: "This model reasons on its own. Drop the reasoning instruction.", suggestion: nil))
case "gpt" where !startsWithGoal(trimmed):
    out.append(.init(rule: .goalNotFirst, message: "Open with a one-line goal before the list.", suggestion: nil))
default: break
}
```
Helpers (only well-formed names count as tags, so `a < b` is ignored):
```swift
private static func unbalancedTags(_ text: String) -> Bool {
    let regex = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9_-]*)[^<>]*>")
    var stack: [String] = []
    let ns = text as NSString
    for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let closing = ns.substring(with: m.range(at: 1)) == "/"
        let name = ns.substring(with: m.range(at: 2))
        if closing { guard stack.last == name else { return true }; stack.removeLast() }
        else { stack.append(name) }
    }
    return !stack.isEmpty
}
private static func startsWithGoal(_ text: String) -> Bool {
    guard let first = text.split(separator: "\n").first else { return true }
    return !["-", "*", "#", ">", "`"].contains { first.hasPrefix($0) }
}
```
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Pass `modelFamily: brief.target.modelFamily` at the call sites (confirm they exist in `Sources/Kokoro/App/`).
- [ ] **Step 6:** Commit (when asked).

### Task 5: Use the new fields in the rewriter and item rendering
**Files:** Modify `Sources/StackCore/Prompts/PromptOptimizer.swift:320` (`lines.append(context.profile.guidance)` → `.rewriterGuidance`); optionally `BriefCompiler.swift:177–191` only if Task 1 shows a delimiter difference worth encoding. Test `Tests/KokoroTests/BriefCompilerTests.swift` and the optimizer tests that assert the guidance line.
**Interfaces:** Consumes `rewriterGuidance`.

- [ ] **Step 1:** Read the optimizer tests that assert the guidance text; add a failing test that a `.reasoning` profile's request contains "Do not ask the model to think step by step." and a `.claude` profile's request is byte-identical to before.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Swap `guidance` → `rewriterGuidance` at line 320. Do not add a "target style" line to compiled output (it would pollute the pasted prompt).
- [ ] **Step 4:** `swift test` → pass; confirm `PromptPrinciples` word-limit test still passes.
- [ ] **Step 5:** Commit (when asked).

### Task 6: Verification
- [ ] `swift test` (all pass).
- [ ] Task 5 changes rewriter input, so run the optimizer eval before and after on the same drafts:
```bash
swift run -c release KokoroBench --optimizer-eval --modes improve,expand,adapt --repeats 3 --eval-json before.json
```
Run once on `main`, once on the branch (`after.json`); report fidelity, acceptance and token numbers. Skip configs already measured worse. If Task 5 is dropped, report the eval as not run.
- [ ] Open the app and confirm the dropdown shows the new families and lint messages appear for a claude/reasoning/gpt target.
