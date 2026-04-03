# llama-server Features Guide for Peacelily

A personal reference for understanding llama-server capabilities, their impact on a consumer GPU setup, and what to adopt.

## Your Current Setup

You're running **llama-swap** as an OpenAI-compatible proxy on peacelily (a headless NixOS server with a consumer NVIDIA GPU, ~10-24GB VRAM). llama-swap manages multiple llama-server instances, loading and unloading models on demand so they share the single GPU.

Your current models:
- **qwen3.5:9b** and **qwen3.5:9b-nothinker** — general chat (thinking on/off)
- **qwen3.5:35b-a3b** — larger MoE model for harder tasks
- **qwen3.5:4b** — lightweight, used for LibreChat conversation titles
- **embeddinggemma:300m** — persistent embedding model for Qdrant

Each model launches with: `-hf`, `--port`, `--ctx-size 16384`, `--batch-size`, `--ubatch-size`, `--threads`, `--gpu-layers 99`, `--jinja`.

The client is **LibreChat** on port 3080, talking to llama-swap on port 9292.

## Performance Features

These flags make inference faster or reduce VRAM usage. Since you have a single consumer GPU, VRAM is your bottleneck — every MB saved means room for larger context or bigger models.

### Flash Attention (`-fa`)

**What it does:** Replaces the standard attention computation with an optimized algorithm that processes attention in tiles rather than materializing the full attention matrix in memory.

**Impact:**
- Reduces VRAM usage during inference (the attention matrix is the biggest memory consumer after the model weights and KV cache)
- Makes inference faster, especially at longer context lengths
- Required for some newer model architectures that use sliding window attention (SWA)

**Default:** `auto` — llama-server will enable it if your GPU supports it. Explicitly passing `-fa` forces it on. On CUDA with modern GPUs (Turing/RTX 20 series and newer), it should always work.

**Recommendation:** Add `-fa` to every model command. There's no downside on supported hardware.

### KV Cache Quantization (`-ctk`, `-ctv`)

**What it does:** The KV cache stores the attention keys and values for every token in your context. By default it uses `f16` (16-bit float). Quantizing it to `q8_0` (8-bit) or `q4_0` (4-bit) cuts its memory footprint.

**Impact on VRAM:** For a 9B model at 16384 context, the KV cache in f16 can use ~2-4GB. Switching to q8_0 roughly halves that. q4_0 quarters it.

**Impact on quality:**
- `q8_0` — negligible quality loss for most tasks. Safe default.
- `q4_0` — noticeable degradation, especially for **tool calling** and structured output. The docs explicitly warn against this.
- `q5_0` / `q5_1` — middle ground if q8_0 isn't enough savings.

**Recommendation:** Add `-ctk q8_0 -ctv q8_0` to all chat models. For the embedding model, f16 is fine (small model, no KV pressure).

### Parallel Slots (`-np`)

**What it does:** Allows a single llama-server instance to handle multiple concurrent requests. Each "slot" gets its own KV cache and can process a different conversation simultaneously.

**Impact:**
- `-np 1` (default) — one request at a time, others queue
- `-np 2` — two concurrent conversations, but each slot reserves KV cache memory, so VRAM usage roughly doubles for the cache portion
- Continuous batching (`-cb`, on by default) makes this efficient by interleaving token generation across slots

**Trade-off:** More slots = more VRAM for KV caches = less room for model weights or context length. On a consumer GPU, `-np 2` is usually the max before you start running out of VRAM.

**Recommendation:** If you're the only user, `-np 1` is fine. If you want LibreChat to handle a second request while one is streaming, try `-np 2` but monitor VRAM.

### No WebUI (`--no-webui`)

**What it does:** Disables the built-in web interface that llama-server serves on its port. Since your models are behind llama-swap and you use LibreChat as your frontend, nobody accesses the llama-server web UI.

**Impact:** Minor — saves a small amount of memory and startup time. Mainly reduces attack surface on a network-exposed server.

**Recommendation:** Add `--no-webui` to every model command.

## Capability Features

These aren't about speed — they unlock new things your models can do.

### Tool Calling / Function Calling

**What it does:** Lets the model request actions instead of just generating text. You define "tools" (functions with names, descriptions, and parameter schemas) in your API request. The model can then respond with a structured tool call instead of prose, and your client executes it and feeds the result back.

**Example flow:**
1. User asks: "What's the weather in Cairo?"
2. You send the request with a `tools` array containing a `get_weather` function definition
3. The model responds with: `{"name": "get_weather", "arguments": {"city": "Cairo"}}`
4. Your client calls the actual weather API, gets the result
5. You send the result back to the model
6. The model writes a natural language answer using the data

**How it works in llama-server:** The `--jinja` flag (which you already use) enables the Jinja template engine that formats tool definitions into the model's chat template. Qwen models have native tool-call support, meaning the model was trained to produce structured tool calls — it's not a hack or prompt trick.

**What you need on the client side:** This is the key part. llama-server only handles the model's side — generating tool call responses. **The client (LibreChat) must implement the tool execution loop.** LibreChat supports this through its "Plugins" system and custom endpoint configuration. You'd configure plugins for the specific tools you want (web search, code execution, etc.).

**Web search specifically:** There is no built-in web search in llama-server. Llama 3.x models have a built-in concept of `brave_search` / `web_search` tools, but Qwen models handle it generically. Either way, the actual searching is done by the client. LibreChat has a web search plugin that can use Google, Bing, or SearXNG as a backend.

**Impact on your setup:** You already have `--jinja` on every model. Tool calling is technically ready on the llama-server side. The work is in configuring LibreChat plugins and choosing which tools to expose. No changes needed to your Nix config for this.

**Recommendation:** If you want tool calling, the next step is LibreChat plugin configuration, not llama-server flags.

### Structured Output / JSON Mode

**What it does:** Forces the model to produce output that conforms to a specific format — either valid JSON, JSON matching a schema, or text matching a BNF grammar. This uses constrained decoding: at each token, the model can only pick tokens that keep the output valid.

**How to use it:**
- **Per-request (API):** Send `response_format: {"type": "json_object"}` for any valid JSON, or `response_format: {"type": "json_schema", "schema": {...}}` for schema-constrained output
- **Server-wide default (CLI):** `--json-schema '{}'` forces all output to be JSON. Not useful for chat, but good for a dedicated extraction endpoint.

**Impact:** This is powerful for building applications on top of your models — data extraction, API response generation, form filling. It guarantees parseable output, which plain prompting can't.

**Recommendation:** No flags needed. This is available by default through the API. Use it from client code when you need structured responses.

### Multimodal / Vision (`--mmproj`)

**What it does:** Lets the model process images alongside text. You send an image (as a URL or base64) in the chat message, and the model can describe, analyze, or answer questions about it.

**How it works:** Vision models have two parts — the language model (LLM) and a multimodal projector (mmproj) that converts image features into tokens the LLM understands. You need both files. When using `-hf` to download a model, llama-server auto-downloads the matching mmproj if available (`--mmproj-auto`, on by default).

**Which models:** You need a model trained for vision. Your current Qwen 3.5 models are text-only. To use vision, you'd add a separate model entry in llama-swap using something like `Qwen2.5-VL`, `Gemma 3`, or `Llava`.

**VRAM cost:** The projector adds ~200-500MB. The bigger cost is that vision models tend to be larger and images consume many tokens (hundreds to thousands per image).

**Recommendation:** Worth adding as a separate model in llama-swap if you want image understanding. Doesn't affect your existing models. Example entry:
```
"qwen2.5-vl:7b" = {
  cmd = "llama-server -hf Qwen/Qwen2.5-VL-7B-Instruct-GGUF --port ${PORT} --ctx-size 8192 -fa --gpu-layers 99 --jinja --no-webui";
};
```

## Speculative Decoding and Speed Tricks

### Speculative Decoding

**What it does:** Normally, a language model generates one token at a time — each token requires a full forward pass through the model. Speculative decoding uses a cheap source of "guesses" to draft multiple tokens ahead, then the main model verifies them all in a single pass. Correct guesses are free; wrong ones get discarded and regenerated normally.

**Why it matters:** On a GPU, verifying 8 tokens in one batch takes almost the same time as generating 1 token. So if the draft source guesses 6 out of 8 tokens correctly, you've generated 6 tokens for nearly the cost of 1. Real-world speedups range from 1.5x to 3x depending on the task.

### Option A — Draft Model (`-md`)

Uses a smaller model from the same family to generate guesses. The draft model must share the same tokenizer as the main model.

Example for Qwen 3.5:
```
llama-server -hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL \
  -md /path/to/qwen3.5-0.6b.gguf \
  --draft-max 16 --draft-p-min 0.75
```

**Trade-offs:**
- The draft model uses additional VRAM (a 0.5-1B model adds ~500MB-1GB)
- On a consumer GPU where VRAM is tight, this might force you to reduce context size
- Best speedup when the text is predictable (code, structured output, long prose). Less benefit for creative or reasoning-heavy text.
- Both models must be loaded simultaneously, which conflicts with llama-swap's model-swapping design — the draft model must always be co-loaded with the main model

### Option B — N-gram Lookup (`--spec-type ngram-simple`)

Instead of a draft model, this uses patterns from the text generated so far to predict upcoming tokens. No extra VRAM, no extra model files.

```
llama-server --spec-type ngram-simple \
  --spec-ngram-size-n 12 --spec-ngram-size-m 48
```

**Trade-offs:**
- Zero VRAM cost — just CPU memory for the n-gram table
- Lower accuracy than a draft model, so smaller speedup (typically 1.2-1.5x)
- Works best on repetitive or structured content
- Easy to add to any model without worrying about compatibility or VRAM budget

**Recommendation:** Start with `--spec-type ngram-simple` on your chat models. It's free and always helps a little. Draft model speculative decoding is more impactful but harder to set up with llama-swap since both models must fit in VRAM simultaneously.

### Prompt Caching (`--cache-prompt`)

**What it does:** When two requests share the same prefix (e.g. the same system prompt, or a conversation where each new message adds to the history), llama-server reuses the KV cache from the previous request instead of reprocessing all the prior tokens.

**Impact:** In a chat conversation, each new message only needs to process the new user message, not the entire conversation history. This can cut time-to-first-token from seconds to milliseconds for long conversations.

**Default:** Already enabled. You're getting this benefit without any extra flags.

**Caveat with llama-swap:** llama-swap can unload a model after `ttl` seconds of inactivity (you have `ttl: 3600`). When a model is unloaded and reloaded, the KV cache is lost. This is the expected trade-off with model swapping on limited VRAM.

## Remaining Features

### LoRA Adapters (`--lora`)

**What it does:** LoRA (Low-Rank Adaptation) files are small "patches" to a base model that modify its behavior without replacing the full weights. They're typically 10-100MB and are the output of fine-tuning. You can load one or more LoRA adapters on top of a base model to specialize it — for example, making it better at a specific language, coding style, or domain.

**How to use:**
```
llama-server -hf base-model --lora /path/to/adapter.gguf
```

Multiple adapters with scaling:
```
--lora-scaled adapter1.gguf:0.8,adapter2.gguf:0.5
```

llama-server also supports hot-swapping LoRA adapters per request through the API, so different conversations can use different fine-tunes on the same base model.

**Impact:** Minimal VRAM overhead. The adapter modifies weights in-place during computation.

**Recommendation:** Only relevant if you fine-tune models yourself or find community LoRA adapters that match your needs. No action needed now, but good to know it's available if you want to specialize a model later.

### Reranking (`--reranking`)

**What it does:** Reranking takes a query and a list of text passages, then scores how relevant each passage is to the query. This is different from embeddings (which produce a vector you compare with cosine similarity) — a reranker uses cross-attention between the query and each passage, which is more accurate but slower.

**Typical use:** In a RAG (retrieval-augmented generation) pipeline:
1. User asks a question
2. You retrieve 20 candidate passages from Qdrant using embedding similarity (fast, rough)
3. You rerank those 20 passages with a reranker model (slow, accurate)
4. You feed the top 5 to your chat model as context

**How to use:** Requires a dedicated reranker model (e.g. `BAAI/bge-reranker-v2-m3`) loaded with `--reranking --embeddings --pooling rank`.

**Impact on your setup:** You already have Qdrant + embeddinggemma for vector search. Adding a reranker would be a second-stage filter that improves retrieval quality. It would be a separate model entry in llama-swap.

**Recommendation:** Worth exploring if you're doing RAG and finding that retrieved context is sometimes irrelevant. Not urgent — embedding search alone is often good enough for personal use.

### Sleep on Idle (`--sleep-idle-seconds`)

**What it does:** After N seconds with no requests, llama-server unloads the model from RAM (not just VRAM). The next request triggers a reload.

**Impact:** Frees system RAM when models aren't in use. However, reloading takes seconds to tens of seconds depending on model size.

**Relevance to your setup:** llama-swap already handles load/unload at the process level with its `ttl` setting (you have `ttl: 3600`). This flag is for standalone llama-server deployments. **Not useful with llama-swap** — it would conflict with llama-swap's own lifecycle management.

**Recommendation:** Skip this. llama-swap handles it.

### API Key Authentication (`--api-key`)

**What it does:** Requires an `Authorization: Bearer <key>` header on all API requests. Without it, anyone who can reach port 9292 can use your models.

**Your current state:** You use `"sk-no-key-required"` in LibreChat, meaning no auth. Your server is accessible to anyone on your network (or Tailscale network).

**Recommendation:** If peacelily is only accessible via Tailscale (private network), this is low priority. If it's exposed to a broader network, add `--api-key` to llama-swap or use firewall rules to restrict access.

## Summary: Recommended Changes

Here's what to add to your model commands, ordered by impact:

| Change | Impact | Effort |
|--------|--------|--------|
| Add `-fa` | Free speed + VRAM savings | One flag per model |
| Add `-ctk q8_0 -ctv q8_0` | ~50% KV cache VRAM savings | One flag per model |
| Add `--no-webui` | Cleaner headless operation | One flag per model |
| Add `--spec-type ngram-simple` | ~1.2-1.5x speed, no VRAM cost | One flag per model |
| Configure LibreChat plugins | Enables tool calling (web search, etc.) | LibreChat config, not Nix |
| Add a vision model entry | Image understanding | New model in llama-swap |
| Add a reranker model entry | Better RAG retrieval | New model in llama-swap |

The first four are safe to add to all chat models today. The last three are new capabilities that require more setup beyond llama-server flags.

## Speech: STT and TTS

You already have Wyoming Faster Whisper (STT) and Wyoming Piper (TTS) running on peacelily. The question is: should speech processing happen on peacelily, on the client device, or a mix of both?

### Speech-to-Text (STT): Do It on the Client

STT is a strong candidate for client-side processing. Here's why:

**Privacy:** Your voice never leaves your device. No audio streaming over the network.

**Latency:** On-device STT is near-instant. Server-side STT adds network round-trip time plus the overhead of streaming audio to peacelily, waiting for transcription, and getting text back. For a conversational feel, that latency matters.

**Quality:** Modern on-device STT is very good:
- **Browser Web Speech API** — built into Chrome/Edge/Safari. Free, zero setup, works with any web app including LibreChat. Uses the browser's built-in speech recognition (Google's engine on Chrome, Apple's on Safari). Supports many languages including Arabic.
- **Android/iOS built-in** — the keyboard's voice typing. Works in any text field, including a browser tab running LibreChat.
- **Whisper.cpp on your laptop** — if you want offline STT with Whisper quality, you can run whisper.cpp locally. It runs fine on CPU for real-time transcription of short utterances.

**When server-side STT makes sense:** If you're building a voice assistant pipeline (like Home Assistant + Wyoming), the audio comes from a satellite device (smart speaker, ESP32) that can't run Whisper locally. That's what your Wyoming Faster Whisper setup is for. For chatting with LibreChat from your laptop or phone, client-side STT is simpler and better.

**Arabic STT:** Whisper (both server and local) supports Arabic well — it was trained on a large multilingual dataset. The `large-v3` model you're running on peacelily is the best for Arabic accuracy. If you go client-side with Whisper.cpp, use at least the `medium` model for Arabic (the `small` and `base` models drop quality significantly for non-English).

**Custom dictionaries for STT:** This is a limitation. Whisper doesn't support custom vocabularies or dictionaries — you can't tell it "always transcribe X as Y." There are workarounds:
- **Initial prompt / prompt conditioning:** Whisper accepts an `initial_prompt` parameter where you list unusual words, names, or terms. This biases the model toward recognizing them. Not guaranteed, but helps.
- **Post-processing:** Run a find-and-replace on the transcribed text for known mis-transcriptions (e.g. if it always writes "Hazem" as "Hazim", correct it after the fact).
- **Fine-tuning:** You can fine-tune Whisper on your own audio + transcription pairs. This is the nuclear option — high effort, best results.

**Recommendation:** Use the browser's built-in Web Speech API or your device's voice keyboard for STT with LibreChat. Keep the Wyoming Faster Whisper service on peacelily for Home Assistant / voice satellite use cases only.

### Text-to-Speech (TTS): Server vs Client

TTS is more nuanced. Unlike STT (where the input is your voice and stays private regardless), TTS input is the model's text response — which is already on the server. The question is about quality and latency.

#### Option 1: Server-Side TTS (Piper on Peacelily)

You already have Wyoming Piper running with the `en-us-ryan-high` voice on CUDA.

**Pros:**
- High-quality neural TTS with GPU acceleration — fast synthesis
- Piper has many voices and languages available as downloadable models
- One setup serves all your client devices

**Cons:**
- Audio must stream from peacelily to your client — adds latency
- Requires the server to be on and reachable
- Wyoming protocol is designed for Home Assistant, not for generic HTTP clients. LibreChat doesn't natively talk to Wyoming Piper. You'd need a bridge (an HTTP endpoint that accepts text, calls Piper, returns audio).

**Arabic TTS with Piper:** Piper does have Arabic voice models, but the selection is limited compared to English. Quality varies. Check the [Piper voice samples](https://rhasspy.github.io/piper-samples/) for available Arabic voices. If the available voices don't meet your needs, alternatives like Coqui TTS (XTTS) offer Arabic with voice cloning, but are heavier on VRAM.

#### Option 2: Client-Side TTS (Browser / OS)

**Browser Web Speech API (`speechSynthesis`):** Built into all modern browsers. Zero setup.

**Pros:**
- Instant — no network latency, no server dependency
- Works offline
- Modern OS voices are decent quality (especially on macOS and iOS)

**Cons:**
- Quality varies by platform. macOS/iOS voices are good. Linux voices (espeak) sound robotic unless you install additional voice packages. Windows voices are middling.
- Limited voice selection on some platforms
- Arabic support depends on your OS having Arabic voices installed

**Recommendation for Linux clients:** Browser TTS on Linux is weak out of the box. You could install Piper locally on your laptop as a system TTS engine — it runs fine on CPU for single sentences. But this is extra setup per device.

#### Option 3: Hybrid — Client STT, Server TTS

This is likely the best fit for your setup:
- **STT on client** — use browser/OS voice input, private and instant
- **TTS on server** — Piper on peacelily with GPU, high quality, consistent across devices

The missing piece is getting LibreChat to call Piper for TTS. LibreChat's TTS support is focused on OpenAI's `/v1/audio/speech` API endpoint. You would need either:
1. A thin HTTP wrapper around Piper that exposes an OpenAI-compatible `/v1/audio/speech` endpoint
2. A different chat frontend that has native Piper/Wyoming support

#### Alternative Chat Frontends

**ChatterUI** is a mobile chat app designed for local LLMs. It connects to OpenAI-compatible APIs (so it works with llama-swap), and does client-side STT using the device's built-in speech recognition. It also supports client-side TTS. This avoids the server TTS question entirely for mobile use — your phone handles both speech directions locally.

**Open WebUI** is another popular frontend (like LibreChat) that has built-in TTS/STT support with configurable backends, including OpenAI-compatible speech endpoints.

#### Custom Dictionaries for TTS

Piper supports **phoneme-level control** through its eSpeak-ng backend. You can override pronunciation of specific words:
- Piper uses eSpeak-ng for grapheme-to-phoneme conversion. eSpeak-ng supports custom dictionary files where you define word-to-phoneme mappings.
- For Arabic, this means you can ensure proper pronunciation of names, technical terms, or transliterated words that the default model might mispronounce.
- The dictionary file format is simple: `word  phonemes` per line.

This is more practical than custom STT dictionaries — TTS pronunciation is deterministic and overridable, while STT is probabilistic.

### Summary: Speech Recommendations

| Component | Where | Why |
|-----------|-------|-----|
| STT for LibreChat | Client (browser/OS) | Private, instant, good enough |
| STT for Home Assistant | Server (Wyoming Whisper) | Satellite devices can't run Whisper |
| TTS for LibreChat | Server (Piper) or Client | Server = better quality; Client = simpler |
| TTS for Home Assistant | Server (Wyoming Piper) | Already set up and working |
| Arabic STT | Whisper large-v3 (server or local) | Best multilingual accuracy |
| Arabic TTS | Piper (limited voices) or Coqui XTTS | Check available voice quality |
| Custom pronunciation | Piper eSpeak-ng dictionaries | Deterministic, easy to configure |
| Custom STT vocabulary | Whisper initial_prompt hack | Probabilistic, not guaranteed |
| Mobile chat with voice | ChatterUI + llama-swap | Client-side STT/TTS, OpenAI-compatible |
