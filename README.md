# Scripts for vLLM Setup

## Overview

This repository contains scripts for setting up vLLM with various models, focusing on tool calling and vision capabilities using Podman.

* I was trying to get the gpt-oss 20b model working but could not get tool calling to work with it.
* Switched to Qwen3-8B and it worked right away, but not able to get Podman working as a service yet.
* Playing with the Qwen2.5-VL-7B-Instruct vision model now.

## Setup for Qwen3-8B

Download the model from Hugging Face:

```bash
huggingface-cli download Qwen/Qwen3-8B
```

Serve the model with vLLM (direct command, commented out):

```bash
# vllm serve Qwen/Qwen3-8B \
#   --enable-auto-tool-choice \
#   --tool-call-parser hermes
```

Run with Podman:

```bash
podman run -v /mnt/data/huggingface:/root/.cache/huggingface/hub \
  --rm --device nvidia.com/gpu=all \
  -p 8000:8000 --ipc=host \
  docker.io/vllm/vllm-openai:latest \
  --model Qwen/Qwen3-8B \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --gpu_memory_utilization 0.95
```

## Podman Service Setup

Replace "my-container" with your container name:

```bash
# podman generate systemd --new --name busy_montalcini -f
```

Still having a hard time getting this to work with quadlets.

## Setup for Qwen2.5-VL-7B-Instruct (Vision Model)

Download the model:

```bash
huggingface-cli download Qwen/Qwen2.5-VL-7B-Instruct
```

Run with Podman:

```bash
podman run -v /mnt/data/huggingface:/root/.cache/huggingface/hub \
  --rm --device nvidia.com/gpu=all \
  -p 8000:8000 --ipc=host \
  docker.io/vllm/vllm-openai:latest \
  --model Qwen/Qwen2.5-VL-7B-Instruct \
  --gpu_memory_utilization 0.95 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --max-model-len 50000
