# Model Style Facts: Pasted-Text Prompting Guide

**Research date:** 2026-10-01  
**Scope:** Delimiters, reasoning cues, output-format placement, length/verbosity for pasted-text prompts only.

---

## Claude

- **Delimiters:** XML tags strongly preferred (`<instructions>`, `<context>`, `<examples>`, custom descriptive tag names). Markdown headers and lists also work. No canonical "best" tag names; descriptive names recommended. _Source: [Use XML tags to structure your prompts](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/use-xml-tags), accessed 2026-10-01_
- **Reasoning cue:** [unverified] Claude responds well to explicit step-by-step reasoning requests when needed; no evidence of aversion to asking for reasoning.
- **Output format placement:** Put format specification in the pasted prompt itself (use XML tags or explicit wording). Example: "Write the prose sections of your response in `<smoothly_flowing_prose_paragraphs>` tags." _Source: [Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices), accessed 2026-10-01_
- **Length/verbosity:** Latest Claude models are concise and direct by default. Request more detail explicitly if needed: "Provide a quick summary of the work you've done." _Source: [Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices), accessed 2026-10-01_

## GPT

- **Delimiters:** Markdown headers, lists, and XML tags in combination. "Markdown headers and lists can be helpful to mark distinct sections of a prompt, and to communicate hierarchy to the model." _Source: [Prompt engineering](https://developers.openai.com/api/docs/guides/prompt-engineering), accessed 2026-10-01_
- **Reasoning cue:** GPT models benefit from very precise, explicit instructions; no explicit guidance against asking for reasoning. _Source: [Prompt engineering](https://developers.openai.com/api/docs/guides/prompt-engineering), accessed 2026-10-01_
- **Output format placement:** Describe results, not steps. "Start with the result, not a detailed list of steps." Include audience or format when those details change what the model should produce. _Source: [Prompt engineering best practices for ChatGPT](https://help.openai.com/en/articles/10032626-prompt-engineering-best-practices-for-chatgpt), accessed 2026-10-01_
- **Length/verbosity:** [unverified] No specific guidance on length preference in pasted-text prompts; recommend explicit constraints if brevity is required.

## Gemini

- **Delimiters:** Conversational language preferred over structural delimiters. "Write prompts like you're talking with a person." Documentation does not specify particular delimiters or rigid structural formats. _Source: [Write better prompts for Gemini in Google Cloud](https://docs.cloud.google.com/gemini/docs/discover/write-prompts), accessed 2026-10-01_
- **Reasoning cue:** Chain-of-thought prompting recommended: "Leverage chain-of-thought prompting by encouraging step-by-step reasoning and asking the model to explain its reasoning process." _Source: [Overview of prompting strategies](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/prompts/prompt-design-strategies), accessed 2026-10-01_
- **Output format placement:** Specify format explicitly and early in the prompt. Acceptable formats: JSON, table, Markdown, paragraph, bulleted list. "Define the desired length and format of the output." _Source: [Write better prompts for Gemini in Google Cloud](https://docs.cloud.google.com/gemini/docs/discover/write-prompts), accessed 2026-10-01_
- **Length/verbosity:** Context limit 4,000 characters. Include as much specific detail as possible within that bound; break complex tasks into separate prompts. _Source: [Write better prompts for Gemini in Google Cloud](https://docs.cloud.google.com/gemini/docs/discover/write-prompts), accessed 2026-10-01_

## Reasoning Models (OpenAI o-series, DeepSeek-R1)

### OpenAI o3-mini
- **Delimiters:** Use delimiters like markdown, XML tags, and section titles to indicate distinct parts. _Source: [Reasoning best practices](https://developers.openai.com/api/docs/guides/reasoning), accessed 2026-10-01_
- **Reasoning cue:** Do NOT ask for step-by-step reasoning or chain-of-thought. "A developer should not try to induce additional reasoning before each function call by asking the model to plan more extensively. Asking a reasoning model to reason more may actually hurt the performance." _Source: [Reasoning best practices](https://developers.openai.com/api/docs/guides/reasoning), accessed 2026-10-01_
- **Output format placement:** "Explicitly outline those constraints in the prompt. Try to give very specific parameters for a successful response." _Source: [Reasoning best practices](https://developers.openai.com/api/docs/guides/reasoning), accessed 2026-10-01_
- **Length/verbosity:** Give clear goal, strong constraints, and explicit output contract without prescribing every intermediate step. _Source: [Reasoning best practices](https://developers.openai.com/api/docs/guides/reasoning), accessed 2026-10-01_

### DeepSeek-R1
- **Delimiters:** Uses `<think>` tags for internal reasoning, `<answer>` tags for final result. "Leverage the model's preferred output structure with `<think>` tags for reasoning and `<answer>` tags for the final result." Enforce start with `<think>\n` if thorough reasoning is required. _Source: [DeepSeek-R1 README](https://github.com/deepseek-ai/DeepSeek-R1/blob/main/README.md), accessed 2026-10-01_
- **Reasoning cue:** [unverified] Documentation emphasizes enforcing `<think>` tags to ensure thorough reasoning; no explicit guidance on asking vs. avoiding reasoning.
- **Output format placement:** For mathematical problems, include directive: "Please reason step by step, and put your final answer within \\boxed{}." _Source: [DeepSeek-R1 README](https://github.com/deepseek-ai/DeepSeek-R1/blob/main/README.md), accessed 2026-10-01_
- **Length/verbosity:** "Avoid adding a system prompt; all instructions should be contained within the user prompt. Write your instructions in plain language, clearly stating what you want. Complex, lengthy prompts often lead to less effective results." Set temperature 0.5–0.7 (0.6 recommended). _Source: [DeepSeek-R1 README](https://github.com/deepseek-ai/DeepSeek-R1/blob/main/README.md), accessed 2026-10-01_

## Local Small Models

- **Delimiters:** [unverified] No consistent guidance across Llama, Qwen, Phi. Likely model-specific chat templates; descriptive delimiters or roles recommended as general practice.
- **Reasoning cue:** "Guide the model to break the task into smaller, manageable steps." Step-by-step reasoning guidance appears safe. _Source: [Prompt Engineering for Small LLMs](https://maliknaik.medium.com/prompt-engineering-for-small-llms-llama-3b-qwen-4b-and-phi-3-mini-de711d38a002), accessed 2026-10-01_
- **Output format placement:** [unverified] No official guidance on format placement; infer from local deployment notes (e.g., Qwen system prompt can control verbosity).
- **Length/verbosity:** Write concise, clear, specific instructions; avoid excessive or conflicting goals. "Adding too many instructions or conflicting goals can confuse the model and result in unexpected output." Assign a role. Provide contextual background. _Source: [Prompt Engineering for Small LLMs](https://maliknaik.medium.com/prompt-engineering-for-small-llms-llama-3b-qwen-4b-and-phi-3-mini-de711d38a002), accessed 2026-10-01_

---

## Review notes (apply before encoding in Task 3)

- **Gemini:** the cited pages are Gemini for Google Cloud (an assistant product), not the Gemini model API guide. The 4,000-character limit does not apply to us. Only encode "state the output format early" and "chain-of-thought is fine"; re-source from ai.google.dev before using more.
- **Reasoning family is two sources that disagree.** OpenAI o-series: avoid step-by-step cues (sourced). DeepSeek-R1: its README asks for "reason step by step" on math and says no system prompt. The `.reasoning` profile's `reasoningCue: .avoid` is supported for o-series only; do not claim it for R1.
- **Local models:** the only source is a blog, not vendor docs. Its "assign a role" tip conflicts with the repo's no-persona rule; do not encode it. Keep `.localSmall` as it is.
- **Claude / GPT reasoning cue and GPT verbosity:** unverified; leave at defaults.

## Unreachable Sources

None reported. Unconfirmed claims are marked `[unverified]`.
