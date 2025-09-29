
## vLLM Setup Scripts Collection

This repository is a small collection of helper scripts and examples for running a local **vLLM OpenAI-compatible API** with GPU acceleration (Podman + NVIDIA), experimenting with models (e.g. `Qwen/Qwen3-8B`, `openai/gpt-oss-*`), testing guided JSON output, and trying function / tool calling.

> These scripts are intentionally lightweight and opinionated. Feel free to copy, fork, adapt.

---
## Quick Start (One-Off Run)

Install Podman (Debian/Ubuntu):
```bash
sudo apt update && sudo apt install -y podman
```

Download (optionally) the model weights ahead of time (saves first-run latency):
```bash
huggingface-cli download Qwen/Qwen3-8B
```

Run the Qwen 8B model with tool calling enabled:
```bash
podman run \
  -v /mnt/data/huggingface:/root/.cache/huggingface/hub \
  --rm --device nvidia.com/gpu=all \
  -p 8000:8000 --ipc=host \
  docker.io/vllm/vllm-openai:latest \
  --model Qwen/Qwen3-8B \
  --enable-auto-tool-choice --tool-call-parser hermes \
  --gpu_memory_utilization 0.95
```

Test it:
```bash
curl http://localhost:8000/v1/models | jq .
```

---
## Scripts Overview

| Script | Purpose |
|-------|---------|
| `run.sh` / `run2.sh` / `run3.sh` / `run4.sh` | Variants for launching different models / quantizations. |
| `run-qwen.sh` | Current Qwen 8B example with tool-calling flags. |
| `test_vllm_api.sh` | Smoke tests against the OpenAI-compatible endpoints. |
| `test2.py` | Example: structured JSON generation (guided JSON style). |
| `test3.py` | Function / tool calling loop with fallback logic + colored logs. |
| `test4.py` / `test5.py` | Additional examples (tools + OpenAI client variant). |
| `verify_podman_gpu.sh` | Sanity check GPU visibility inside a container. |
| `cleanup_space.sh` | Remove cached model blobs to reclaim disk. |
| `collect_vllm_diagnostics.sh` | Gathers system + container diagnostics. |
| `migrate_podman_storage.sh` / `fix_rootless_podman_storage.sh` | Helpers for Podman storage tweaks. |

---
## Environment Variables

You can create a `.env` file consumed by the Python examples:
```
BASE_URL=http://localhost:8000
MODEL=Qwen/Qwen3-8B
```

Python scripts load this via `python-dotenv` (installed with `uv pip install python-dotenv`).

---
## Systemd Service (Root)

1. Copy the example unit:
   ```bash
   sudo cp vllm.service.example /etc/systemd/system/vllm.service
   ```
2. Reload + enable:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now vllm
   ```
3. Check status & logs:
   ```bash
   systemctl status vllm
   journalctl -u vllm -f
   ```
4. (Optional) Firewall:
   ```bash
   sudo ufw allow 8000/tcp
   # or firewalld
   sudo firewall-cmd --permanent --add-port=8000/tcp
   sudo firewall-cmd --reload
   ```

---
## Systemd Service (Rootless User)

1. Enable lingering so user services survive logout:
   ```bash
   sudo loginctl enable-linger "$(whoami)"
   ```
2. Install the unit:
   ```bash
   mkdir -p ~/.config/systemd/user
   cp vllm.service.example ~/.config/systemd/user/vllm.service
   systemctl --user daemon-reload
   systemctl --user enable --now vllm
   ```
3. Logs:
   ```bash
   journalctl --user -u vllm -f
   ```

> Rootless notes:
> * Make sure your user has access to the NVIDIA container runtime (check `podman info | grep -i nvidia`).
> * If GPU devices don’t appear, verify `/etc/containers/containers.conf` and driver versions.

---
## Basic API Tests

List models:
```bash
curl -s http://localhost:8000/v1/models | jq .
```

Simple chat completion:
```bash
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-8B","messages":[{"role":"user","content":"Hello"}]}' | jq .
```

Run full smoke script:
```bash
./test_vllm_api.sh
```

---
## Python Examples

Install deps (using uv):
```bash
uv pip install requests pydantic python-dotenv openai
```

Run tool-calling demo:
```bash
python test3.py
```

Generate structured variations:
```bash
python test2.py
```

---
## Disk & Cache

Models are cached under the mounted path (`/mnt/data/huggingface`). Use `cleanup_space.sh` to reclaim disk (will remove blobs—re-download later).

---
## Troubleshooting

| Symptom | Hint |
|---------|------|
| 500 errors on chat completions | Try smaller model; check GPU memory; remove unsupported flags. |
| No tool calls | Confirm `--enable-auto-tool-choice` and model supports tool calling. |
| GPU not visible | Run `podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.2.0-base nvidia-smi`. |
| Slow first request | Warm-up / model weight load; subsequent calls should improve. |
| Permission denied (rootless) | Check lingering + cgroup v2 + storage path permissions. |

---
## License

No explicit license provided—treat as personal scripts unless you add one.

---
## Disclaimer

These scripts are experimental and may change; always validate flags against the current `vllm` image documentation.

---
Happy hacking! 🚀
