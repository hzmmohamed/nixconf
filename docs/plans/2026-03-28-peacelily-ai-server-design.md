# Peacelily — AI Server Host Design

## Overview

Headless NixOS server on the LAN serving AI models (LLM inference, speech-to-text,
TTS, wake word detection) and vector search via Qdrant. All services exposed over
the network for other machines (butternut, maple, main) to consume.

## Hardware

- **CPU:** Intel Core Ultra 5 245K
- **GPU:** NVIDIA RTX 5060 Ti 16GB (CUDA inference)
- **Role:** Headless server, no display manager or compositor

## Architecture

Follows the existing repo patterns. New reusable feature modules composed by the host.

### New files

| File | Purpose |
|------|---------|
| `modules/nixos/features/nvidia.nix` | Reusable NVIDIA driver module (modesetting, CUDA, container toolkit) |
| `modules/nixos/features/ai-server.nix` | llama-swap, Wyoming services, Qdrant |
| `modules/nixos/hosts/peacelily/configuration.nix` | Host config composing modules |
| `modules/nixos/hosts/peacelily/hardware-configuration.nix` | Auto-generated hardware |
| `modules/nixos/hosts/peacelily/disko.nix` | Disk layout |

### Host module composition

```
peacelily imports:
  base, general          -- user, shell, nix config
  nvidia                 -- GPU drivers + CUDA
  ai-server              -- llama-swap, Wyoming, Qdrant
  tailscale              -- remote access
  sops                   -- secrets management
  doas                   -- sudo replacement
  powersave              -- power management
  (no desktop, no WM, no fonts, no browsers)
```

## Services

All bound to `0.0.0.0` for LAN access.

| Service | Port | Purpose |
|---------|------|---------|
| llama-swap | 9292 | OpenAI-compatible LLM proxy (auto model swap) |
| Wyoming Faster Whisper | 10300 | Speech-to-text, English, CUDA accelerated |
| Wyoming Piper | 10200 | Text-to-speech, CUDA |
| Wyoming OpenWakeWord | 10400 | Wake word detection |
| Qdrant | 6333 | Vector database for RAG |
| SSH | 7654 | Remote management |

## Model Configuration

### llama-swap models (via llama.cpp)

Only one large model loaded at a time. llama-swap auto-swaps on request.
1 hour TTL before unloading idle models. 10 minute health check timeout
for first-time model downloads.

| Model | Repo | Quant | VRAM | Use case |
|-------|------|-------|------|----------|
| Qwen3.5-9B | `unsloth/Qwen3.5-9B-GGUF` | UD-Q4_K_XL | ~6.5GB | General chat, thinking mode |
| Qwen3.5-35B-A3B | `unsloth/Qwen3.5-35B-A3B-GGUF` | UD-Q4_K_XL | ~22GB (MoE, CPU offload) | Complex reasoning, coding |
| Qwen3.5-4B | `unsloth/Qwen3.5-4B-GGUF` | Q8_0 | ~5.5GB | Lightweight, fast responses |
| EmbeddingGemma-300M | `ggml-org/embeddinggemma-300M-GGUF` | - | ~0.3GB | Embeddings for RAG (persistent) |

### Key notes

- Qwen3.5 GGUFs don't work with Ollama (separate mmproj vision files) — llama-swap is required
- Qwen3.5 Small models (4B, 9B) have thinking disabled by default; enable via `--chat-template-kwargs '{"enable_thinking":true}'`
- Larger models (27B, 35B-A3B) have thinking enabled by default
- All models use `--jinja` for proper chat template handling

### Recommended inference settings

**Thinking mode (general tasks):** temp=1.0, top_p=0.95, top_k=20, min_p=0.0
**Thinking mode (coding):** temp=0.6, top_p=0.95, top_k=20, min_p=0.0
**Non-thinking (general):** temp=0.7, top_p=0.8, top_k=20, min_p=0.0

### Embedding model

EmbeddingGemma-300M runs persistently alongside any other model via llama-swap
groups. It uses minimal VRAM and provides embeddings for Qdrant RAG workflows.

## NVIDIA module (`nvidia.nix`)

Reusable by peacelily and potentially main host later.

- NVIDIA driver with modesetting
- Open kernel module
- Power management
- CUDA support
- nvidia-container-toolkit
- 32-bit graphics compatibility
- Environment variables for Wayland compatibility (when used on desktop hosts)

## Voice services

Wyoming services share the GPU with llama-swap. Whisper and Piper only use VRAM
briefly during inference, so they coexist fine with a loaded LLM.

- **Faster Whisper large-v3** for English STT (CUDA)
- **Piper en-us-ryan-high** for TTS (CUDA)
- **OpenWakeWord** for wake detection (CPU)

## Networking

- Static IP or DHCP with hostname `peacelily`
- SSH on port 7654 (consistent with other hosts)
- Firewall opens: 9292, 10200, 10300, 10400, 6333, 7654
- Tailscale for remote access outside LAN

## Implementation order

1. Create nvidia.nix feature module
2. Create ai-server.nix feature module (llama-swap config, Wyoming, Qdrant)
3. Create peacelily host (configuration.nix, hardware-configuration.nix, disko.nix)
4. Test build (`nix build .#nixosConfigurations.peacelily.config.system.build.toplevel`)
5. Install on hardware
6. Verify services are accessible from other hosts
