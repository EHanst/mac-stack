# Model facts vs. what our code and docs assume

**Date:** 2026-09-28 · Sources fetched the same day (URLs inline). **[V]** = verified from a fetched source, **[C]** = computed by us from verified numbers, **[G]** = guess / not verified.

Nothing in `ModelCatalog` was changed: the licence fields checked out (see §5).

---

## 1. `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`

Sources: [model card](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-mlx-2bit), its `config.json`, `generation_config.json`, `chat_template.jinja`, `tokenizer_config.json`, `PACK-RUNTIME.md`, `NOTICE.txt`, `LICENSE`, `runtime/runtime.py` (all in that repo).

| Topic | Fact [V] |
|---|---|
| Lineage | Derived from `Qwen/Qwen3.8-27B` (architecture unchanged); pack `model_type: prism_hadamard_qwen35`, `base_model_type: qwen3_5`, tensor namespace `mlx-vlm-qwen3_5` |
| Size | 27.36 B params = 24.35 B language backbone (64 blocks) + 2.54 B embedding/LM head + 0.46 B vision tower. On disk **8.60 GB** = 7.67 GB language model + 0.92 GB FP16 vision tower **in the same `model.safetensors`** |
| Layers | 64: **48 `linear_attention` (Gated DeltaNet) + 16 `full_attention`**; full layers are 3, 7, 11 … 63 (`full_attention_interval: 4`) |
| Dimensions | hidden 5120 · MLP 17408 · **24 q heads, 4 KV heads, `head_dim` 256** · vocab **248,320** · rms eps 1e-6 |
| Full attention | `attn_output_gate: true`, `output_gate_type: "swish"`; **`partial_rotary_factor: 0.25` → 64 of 256 dims rotated**; **`rope_theta: 10,000,000`** (only inside `rope_parameters`; top-level `rope_theta` is `null`); `mrope_section [11,11,10]`, `mrope_interleaved: true` |
| Gated DeltaNet | 16 key heads × 128, **48 value heads × 128**, conv kernel 4, `mamba_ssm_dtype: float32`, `gdn_activation_layout: "grouped"` (PACK-RUNTIME: "do not permute them again") |
| Context | **262,144** tokens native (`max_position_embeddings`, `model_max_length`) |
| Quantization | MLX affine **2-bit, group 128**; ternary {−1,0,+1}·scale stored as codes {0,1,2} with `bias = −scale`; **Hadamard rotation block 1024, ±1 signs**, folded into the weights; activations transformed at runtime; embedding uses the *inverse* transform. Covers embeddings, attention/MLP projections **and LM head**; 26.2 M params (0.098 %) stay high precision (recurrent-state path + norms) |
| Loader contract | "Ordinary MLX loaders skip the activation transform and the inverse embedding lookup, so they return **wrong output rather than an error**." Bundled Python loader in `runtime/`; Swift integration "still requires model integration; layer support alone is insufficient". Prism ships forks: [PrismML-Eng/mlx-swift](https://github.com/PrismML-Eng/mlx-swift), [PrismML-Eng/mlx](https://github.com/PrismML-Eng/mlx); demo repo is "the source of truth for running these models" |
| Chat template | Default is **thinking on**: generation prompt = `<|im_start|>assistant\n<think>\n`. With `enable_thinking=false`: `…<think>\n\n</think>\n\n` |
| Specials | `eos_token = <|im_end|>` (id 248046); `generation_config.eos_token_id = [248046, 248044]`; `bos = pad = <|endoftext|>` (248044); `add_bos_token: false` |
| Sampling (card) | **Thinking mode:** T 1.0, top_p 0.95, top_k 20, min_p 0, presence_penalty 0, repetition 1.0. **Instruct / non-thinking mode:** **T 0.7, top_p 0.80, top_k 20, presence_penalty 1.5**. "mlx-vlm and mlx-lm do not read `generation_config.json`, so without these arguments generation is greedy." Default reasoning effort `xhigh`. Suggested system prompt: "You are a helpful assistant" |
| Benchmarks | 84.78 average (98.2 % of FP16) — **measured in thinking mode**, on H100/vLLM. No non-thinking numbers are published |
| Reference speed | llama.cpp Metal on the *GGUF* packs: M5 Pro **TG128 28.1 / PP512 387 tok/s**; M5 Max 47 / 765; M4 Pro 18.0 / 125 (earlier pre-rotation build). Decode streams ≈204 GB/s ⇒ ≈7.26 GB per token |
| Licence | **Apache-2.0**, not gated. `NOTICE.txt`: "we would appreciate attribution such as: *Created using Bonsai by Prism ML.*"; built from Qwen3.8-27B, Apache-2.0 |
| Pack-doc inconsistency | README and `config.json` (`components.vision: true`) say the pack **includes** the vision tower; `PACK-RUNTIME.md` says "Vision and MTP are not included" |

## 2. `BAAI/bge-small-en-v1.5`

Sources: [model card](https://huggingface.co/BAAI/bge-small-en-v1.5), `config.json`, `1_Pooling/config.json`, `sentence_bert_config.json`, `modules.json`, `tokenizer_config.json`.

| Topic | Fact [V] |
|---|---|
| Architecture | BERT, 12 layers, hidden **384**, 12 heads, `max_position_embeddings` 512, vocab 30,522, fp32 weights (133 MB) |
| Pooling / norm | **CLS** pooling (`pooling_mode_cls_token: true`), then **L2 Normalize** (`modules.json` module 2) |
| Max length | **512** tokens (`max_seq_length`, `model_max_length`); lower-cases input |
| Query instruction | `Represent this sentence for searching relevant passages: ` for **queries only; never for passages**. For v1.5 the card says instruction-free use is only slightly worse, "recommended for short queries"; "choose the setting that achieves better performance on your task" |
| Licence | **MIT** |

## 3. Cloud models named in our code

Our code names exactly two, as UI hint text (`ModelManagerView.swift:397`): `gpt-4o` and `claude-3-5-sonnet-20241022`. There are no built-in presets (the plan's "presets" are M3 work).

| Model | Fact | Source |
|---|---|---|
| `claude-3-5-sonnet-20241022` | **Not in the current lineup, nor in the "legacy models (still available)" list.** Current IDs: `claude-fable-5-1`, `claude-opus-5-5`, `claude-sonnet-5-5` (1M context, 128K max output), `claude-haiku-4-5-20251001` (200K context, 64K max output) | [Models overview](https://platform.claude.com/docs/en/models/overview) |
| `gpt-4o` | 128,000 context, **16,384 max output**, function calling supported | [OpenAI model page](https://developers.openai.com/api/docs/models/gpt-4o) |
| Anthropic tool format | Declare `tools: [{name, description, input_schema}]`; model replies with `stop_reason: "tool_use"` and `tool_use` content blocks (`id`, `name`, `input`); you return a **user message containing `tool_result` blocks with `tool_use_id`** | [Tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview) |
| OpenAI tool format [G — well known, not fetched] | `tools: [{type:"function", function:{name, description, parameters}}]`; reply `message.tool_calls[{id, function:{name, arguments(JSON string)}}]`; results as `role:"tool"` + `tool_call_id`; streaming delivers `delta.tool_calls` fragments | — |
| OpenAI `max_tokens` | Deprecated for Chat Completions in favour of **`max_completion_tokens`**; rejected with 400 by gpt-5 / o-series | [OpenAI API reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) (via search) |
| OpenAI data terms | API data **not used for training unless you opt in**; abuse-monitoring logs retained up to **30 days** by default (opt-in Modified Abuse Monitoring / Zero Data Retention) | [Your data](https://developers.openai.com/api/docs/guides/your-data) |
| Anthropic data terms | **Not verified** — the page I tried returned 404 | — |

## 4. Places where our code or docs contradict the facts

Severity: **A** = breaks output/requests · **B** = wrong numbers/claims · **C** = cosmetic/stale.

### Model implementation (`Sources/StackCore/Inference/Qwen35Model.swift`, `LocalMLXProvider.swift`, `ModelProvider.swift`)
| # | Sev | Where | Code assumes | Fact |
|---|---|---|---|---|
| 1 | A | `Qwen35Model.swift:263` `let Q = qkv[…0..<dInner]` | qkv split `[6144 \| 2048 \| 2048]` | `[q 2048 \| k 2048 \| v 6144]` ("grouped" layout) | **FIXED (6a88150)**
| 2 | A | `:189`, `:195`, `:309` "Mamba2-style … `in_proj_b` unused" | `S = g·S + k⊗v`; `y = q·S` | Gated DeltaNet: `β = σ(in_proj_b)`, `Δ = (v − (g·S)·k)·β`, `S = g·S + k⊗Δ`, `y = S·q` | **FIXED**
| 3 | A | `BonsaiLinearAttn` (no norm) | raw q, k | `q ← (1/Dk)·rmsNorm(q)`, `k ← (1/√Dk)·rmsNorm(k)`, no weight, eps 1e-6 | **FIXED**
| 4 | A | `:35` `rope_theta … ?? 1_000_000` | θ = 1e6 (key is `null` in `text_config`) | **θ = 1e7**, only in `rope_parameters` | **FIXED**
| 5 | A | `:114` `RoPE(dimensions: headDim …)` | rotate all 256 dims | rotate **64** (`partial_rotary_factor 0.25`) | **FIXED**
| 6 | A | `:131`, `:135` gate/q split | `[all q \| all gate]` | per head: reshape `[B,L,24,512]`, split → `q`, `gate` (`[q_h \| gate_h]`) | **FIXED**
| 7 | A/B | `:131` `silu(gate)` | swish output gate | config says `swish`, but reference Qwen3.5 (mlx-lm/mlx-swift-lm) uses **sigmoid** — unresolved; test both against a known-good top token | **Resolved: sigmoid works (' Paris' 83 %)**
| 8 | B | GDN state dtype (bf16) | bf16 | `mamba_ssm_dtype: float32` | **FIXED (fp32 state)**
| 9 | B | `ModelProvider.swift:68` default `maxTokens = 64000`; `LocalMLXProvider.swift:212` | one number = max *new* tokens **and** "context window" | native context 262,144; max new tokens ≠ context. 64,000 new tokens at ~11 tok/s ≈ 97 min; also exceeds gpt-4o's 16,384 output cap | **FIXED (default 8192; 64k is a separate context cap)**
| 10 | B | `ModelProvider.swift:68` `temperature = 0.0`; `sample()` = argmax/temperature only | greedy | non-thinking: **T 0.7, top_p 0.8, top_k 20, presence 1.5**; greedy on a non-thinking instruct model is prone to repetition. No top-p/top-k/penalty support exists | **FIXED (model-card preset; greedy only when asked)**
| 11 | B | `ChatPromptRenderer.emptyThink` (forced non-thinking) | fine per template, **but** the published quality (98.2 %) is for **thinking** mode; non-thinking quality is unreported, and thinking mode needs `<think>` parsing/hiding in the UI |
| 12 | C | `Qwen35Config.from` default `vocab_size ?? 151936` | 151,936 | 248,320 (only a fallback, but wrong) |

### Downloads, catalog, docs
| # | Sev | Where | Says | Fact |
|---|---|---|---|---|
| 13 | B | `ModelInstaller`/`ModelCatalog` | downloads all of `model.safetensors` | 0.92 GB of the 8.60 GB is a vision tower we never load: **10.7 % wasted download and disk**, no separate file exists |
| 14 | C | `PACK-RUNTIME.md` vs README (upstream) | — | contradicts itself on whether vision is included |
| 15 | B | `plan.md` L15/16/27/135 "~8 GB", "8 GB weights", "27B" | weights ≈ 8 GB | **7.67 GB** resident (7.14 GiB, matches ours); 8.60 GB on disk |
| 16 | B | `plan.md` L47 & `m0-status` "64k default context" | 64k | native 262,144; 64k is our own cap and the KV for 262K is 16 GiB (no Mac we target can hold it) |
| 17 | B | `m0-status` "prefill ceiling ≈ 94 tok/s (27B params)" and "88 % of ceiling" | 2×27 B FLOPs/token | real backbone 24.35 B ⇒ **104 tok/s** ceiling; and the 81–83 tok/s was measured on a **wrong** GDN (see §6) |
| 18 | A | `m0-status` / `m1-status` every benchmark table | speeds and memory of "the model" | measured on incorrect math (garbage output); **all TTFT/tok/s/peak-GPU/ContextBudget constants must be re-measured** after the fix |
| 19 | C | `plan.md` §5 metric "First-run download ≤ 15 min (~8 GB)" | 8 GB | 8.61 GB (incl. vision) |

### Cloud (`RemoteAPIProvider.swift`, `AppServices.swift`, onboarding/UI)
| # | Sev | Where | Code | Fact |
|---|---|---|---|---|
| 20 | A | `CredentialEntryView.swift:12` default `https://api.openai.com/v1`; `ModelManagerView` hint; `RemoteAPIProvider.swift:130,178` append `"v1/chat/completions"` | URL becomes `…/v1/v1/chat/completions` | OpenAI base is `https://api.openai.com/v1` + `/chat/completions` ⇒ **404** for the very default we show | **FIXED (`RemoteAPIProvider.endpoint`, tested)**
| 21 | A | `AppServices.swift:385` `modelIdentifier: ""` | onboarding saves a provider with **no model name** | requests send `"model": ""` ⇒ rejected | **FIXED (model required; onboarding + model manager pass it — the model-manager form was collecting the name and dropping it)**
| 22 | A | `RemoteAPIProvider.swift:185` `"max_tokens": options.maxTokens` (64,000) | — | gpt-4o max output 16,384 ⇒ 400; gpt-5/o-series reject `max_tokens` entirely | **PARTLY FIXED: `max_completion_tokens` for api.openai.com, default max tokens 8192; tool-call parsing (23) still open**
| 23 | A | `parseSSEToken` handles only `delta.content` | — | OpenAI tool calls arrive in `delta.tool_calls`; they are dropped, so the agent loop never sees a tool call from OpenAI. Anthropic path ignores `tools` entirely and doesn't emit `tool_use` |
| 24 | C | `ModelManagerView.swift:397` hint `claude-3-5-sonnet-20241022` | — | not in current or legacy-available lists | **FIXED**

### bge-small
No contradictions found: 384-dim ✓ (VectorStore default), 512-token cap ✓, CLS + normalize ✓ (library reads `1_Pooling`), query-only instruction ✓ (`embedQuery` prefixes, `embed` doesn't), MIT ✓. One refinement: the card says the instruction is *optional* for v1.5 — our bake-off used it; a no-instruction run was not compared.

## 5. Licence fields in `ModelCatalog` — verified, unchanged
- Bonsai: **Apache License 2.0** ✓ (card front-matter, `LICENSE` text, `NOTICE.txt`); attribution string matches the requested credit ✓ (could name "Qwen3.8-27B" precisely; left as is).
- bge-small: **MIT** ✓.
- `approximateBytes: 8_610_000_000` ✓ (8,595.5 MB safetensors + 12.8 MB tokenizer + small files).

## 6. Estimates redone with the real numbers

Real shapes: backbone 24.35 B params (computed 24.35 B ✓ from config: MLP 267.4 M/layer ×64, full attn 104.9 M ×16, GDN 115.8 M ×48).

| Quantity | Old assumption | **Real [C]** |
|---|---|---|
| Prefill matmul FLOPs / token | 2 × 27 B = 54 GFLOP | **2 × 24.35 B = 48.7 GFLOP** (LM head only for the last token) |
| Prefill ceiling @ 5.06 TFLOPS (measured 2-bit matmul, M3 Pro) | 94 tok/s | **≈104 tok/s** at short context; falls with length because 16 layers do quadratic attention |
| Decode ceiling | not derived | ≈7.26 GB read per token (card: 204 GB/s ÷ 28.1 tok/s). M3 Pro 150 GB/s [G: Apple spec, not fetched] ⇒ **≈20.7 tok/s** ceiling; we measured 10.5–11 (≈52 %) — on the wrong computation |
| **KV cache / token** | "≈64 KB" (estimate) | **64 KiB exactly** = 16 layers × 2 × 4 kv-heads × 256 × 2 B (bf16) |
| Recurrent state (fixed) | not modelled | **151 MB fp32** (75 MB bf16) for 48 GDN layers + 2.9 MB conv state — independent of length |
| **Snapshot size** | "KV + fork" | `64 KiB × L + ≈154 MB` |

| Context L | KV | One snapshot | Prefill work | Prefill time @ 5.06 TFLOPS (100 % eff.) | attention share |
|---|---|---|---|---|---|
| 512 | 0.03 GiB | 0.17 GiB | 25 TFLOP | 4.9 s | 0.2 % |
| 4,096 | 0.25 GiB | 0.39 GiB | 203 TFLOP | 40 s | 1.6 % |
| 8,192 | 0.50 GiB | 0.64 GiB | 412 TFLOP | 82 s | 3.2 % |
| 16,384 | 1.00 GiB | 1.14 GiB | 851 TFLOP | 168 s | 6.2 % |
| 32,768 | 2.00 GiB | 2.14 GiB | 1.81 PFLOP | 357 s (5.9 min) | 11.7 % |
| 65,536 | 4.00 GiB | 4.14 GiB | 4.04 PFLOP | 798 s (13 min) | 20.9 % |
| 262,144 | **16.0 GiB** | 16.1 GiB | 26.3 PFLOP | 5,193 s (87 min) | 51.4 % |

**Measured after the fix** (chunk 128, M3 Pro 18 GB, AC power): peak GPU over the 7.14 GiB of weights = **+1.45 / +1.57 / +1.92 / +2.46 GiB at 1,042 / 2,087 / 4,175 / 8,419 tokens**; cold prefill 82–86 tok/s (vs ≈104 ceiling); decode 10.7–11.3 tok/s (vs ≈20.7 bandwidth ceiling). The slope (≈0.13–0.17 MiB/token) matches 64 KiB KV × (1 live + 1–2 snapshot copies); the fixed part is ≈1.3 GiB, larger than the 0.3–0.5 GiB hypothesis below (prefill activations + fp32 recurrent-state snapshots + allocator overhead). Fit used by `ContextBudget`: **1.35 GiB + 155 KB/token** (predicts every measured row 1.6–5 % high). The 16k row and chunk-512 comparison were deliberately not re-run (known slow / known worse).

Consequences:
1. **262K context is not usable locally on any Mac we target**: KV alone is 16 GiB; even at 64K, KV = 4 GiB and a cold prefill is ≈13 minutes. Prefix caching (already built) is what makes long sessions viable.
2. A snapshot of a 4 k-token prefix costs ≈0.39 GiB, of an 8 k prefix ≈0.64 GiB: the 2 GiB snapshot cap holds ~3–5 snapshots at that size (the old "fixed 1.6 GiB overhead" was mostly the wrong GDN's activations).
3. Predicted memory model **after** the GDN fix [G — must be measured]: `peak ≈ weights 7.14 GiB + ≈0.3–0.5 GiB fixed + 64 KiB × L × (1 live + n snapshot copies)`. On a 16 GB Mac (working set ≈11.8 GiB if the 74 % ratio holds, ×0.85 safety ≈ 10.0 GiB; minus embedder 0.3 GiB) that leaves ≈2.2 GiB ⇒ roughly **17k tokens with one snapshot copy, ~35k with none** — vs the old model's 8.6k. Treat as a hypothesis until re-measured.
4. Decode speed shouldn't depend on context length much (only 16 layers read KV: 64 KiB × L per token; at 64K that's 4 GiB of extra reads per token — halving decode at long context).

## 7. Not verified
Anthropic data-retention terms (guessed URL 404'd); OpenAI terms beyond data usage; Apple M3 Pro memory bandwidth (used the Apple-published 150 GB/s from memory); OpenAI function-calling wire format (standard, not fetched); what Prism's own Swift fork does for `PrismHadamardConfiguration` (not read); whether `output_gate_type: swish` means silu or the reference's sigmoid (item 7).
