#!/usr/bin/env bash
set -euo pipefail

# Host paths
MODEL_ID="openai/gpt-oss-20b"
USE_REMOTE=${USE_REMOTE:-1}   # 1 = use repo ID directly (no pre-download), 0 = force local snapshot download
# Where to place the (fully materialized) snapshot
MODEL_DIR="/external/sd1/my-cache-2/gpt-oss-20b"
# (Optional) global HF cache – not strictly needed when using --local-dir
HF_CACHE="/external/sd1/my-cache-2"

# Network and GPU
HOST_PORT=8000
CONTAINER_PORT=8000
GPUS="nvidia.com/gpu=all"

echo "Preparing model directory at ${MODEL_DIR}"
mkdir -p "${MODEL_DIR}"
mkdir -p "${HF_CACHE}"

# 1) Download model files locally (weights + tokenizer/config)
# Requires: pip install -U "huggingface_hub[cli]"
if [[ "$USE_REMOTE" -eq 0 ]]; then
  echo "Downloading ${MODEL_ID} to ${MODEL_DIR} (fully materialized, no symlinks) ..."

# Fast path: if shards already exist, skip download unless FORCE_DOWNLOAD=1
  if ls "${MODEL_DIR}"/model-*-of-*.safetensors >/dev/null 2>&1 && [[ "${FORCE_DOWNLOAD:-0}" != "1" ]]; then
    echo "[Skip] Weight shards already present. Export FORCE_DOWNLOAD=1 to force re-download." 
  else

# Newer huggingface_hub exposes the 'hf' CLI. If it's missing, fallback to the legacy 'huggingface-cli'.
download_cmd=""
if command -v hf >/dev/null 2>&1; then
  download_cmd="hf download"
elif command -v huggingface-cli >/dev/null 2>&1; then
  download_cmd="huggingface-cli download"
else
  echo "[ERROR] Neither 'hf' nor 'huggingface-cli' command found. Install with: pip install -U 'huggingface_hub[cli]'" >&2
  exit 1
fi

# The previous script only included files inside an 'original/' subdir, which excluded the actual weight shards
# located at the root of the snapshot (model-0000X-of-XXXXX.safetensors). We broaden the include patterns.
# We also fetch index + tokenizer + config artifacts. Add chat_template + special_tokens_map (useful for chat formatting).

set -x
SYMLINK_FLAG=""
if ${download_cmd} --help 2>&1 | grep -q -- '--local-dir-use-symlinks'; then
  SYMLINK_FLAG="--local-dir-use-symlinks False"
else
  echo "[INFO] This version of ${download_cmd} does not support --local-dir-use-symlinks; proceeding (may create symlinks)." >&2
fi

    if ! ${download_cmd} "${MODEL_ID}" \
    --local-dir "${MODEL_DIR}" \
    ${SYMLINK_FLAG} \
    --repo-type model \
    --include "model-*.safetensors" \
    --include "model.safetensors.index.json" \
    --include "*.json" \
    --include "tokenizer.json" \
    --include "tokenizer_config.json" \
    --include "special_tokens_map.json" \
    --include "generation_config.json" \
    --include "chat_template.jinja"; then
  echo "[ERROR] Download command failed (rc=$?)." >&2
  set +x
  exit 1
    fi
    set +x
  fi
fi

if [[ "$USE_REMOTE" -eq 0 ]]; then
  echo "Verifying weight shard presence..."
  shopt -s nullglob
  shards=("${MODEL_DIR}"/model-*-of-*.safetensors)
  if (( ${#shards[@]} == 0 )); then
  echo "[WARN] Filtered include download produced no weight shards. Attempting diagnostics and fallback..." >&2
  echo "[Diag] Current contents:" >&2
  ls -al "${MODEL_DIR}" >&2 || true
  echo "[Diag] Listing repo files via CLI (may be truncated)..." >&2
  if ${download_cmd} --help 2>&1 | grep -q 'filenames'; then
    # Use filenames listing by attempting a narrow download of model.safetensors.index.json first (already done) then fallback
    :
  fi
  echo "[Fallback 1] Retrying without any --include filters (full snapshot)." >&2
  set -x
    if ! ${download_cmd} "${MODEL_ID}" --local-dir "${MODEL_DIR}" ${SYMLINK_FLAG} --repo-type model; then
    echo "[Fallback 1] Full snapshot retry failed (rc=$?). Proceeding to Python API fallback." >&2
    fi
    set +x
EXIT_ON_FAILURE=0
    shards=("${MODEL_DIR}"/model-*-of-*.safetensors)
  fi

  if (( ${#shards[@]} == 0 )); then
  echo "[Fallback 2] Using Python snapshot_download API with allow_patterns." >&2
  python - <<'PYDL' || true
import os, sys, json
from huggingface_hub import snapshot_download, list_repo_files
model = os.environ.get('MODEL_ID','openai/gpt-oss-20b')
target = os.environ.get('MODEL_DIR')
print('[snapshot_download] Listing repo files...')
files = list_repo_files(model)
print(f"[snapshot_download] {len(files)} files in repo")
allow = [
  'model-*.safetensors', 'model.safetensors.index.json',
  'config.json','tokenizer.json','tokenizer_config.json',
  'generation_config.json','special_tokens_map.json','chat_template.jinja'
]
print('[snapshot_download] allow_patterns:', allow)
try:
    snapshot_download(repo_id=model, local_dir=target, local_dir_use_symlinks=False,
                      resume_download=True, allow_patterns=allow)
except TypeError:
    # older hub version may not support allow_patterns/local_dir_use_symlinks
    print('[snapshot_download] Older huggingface_hub; attempting broad download then manual prune')
    snapshot_download(repo_id=model, local_dir=target, resume_download=True)
print('[snapshot_download] Done.')
PYDL
    shards=("${MODEL_DIR}"/model-*-of-*.safetensors)
  fi

  if (( ${#shards[@]} == 0 )); then
  echo "[ERROR] Still no weight shards after all fallbacks. Manual intervention required." >&2
  echo "Potential causes:"
  echo "  * Repo name incorrect (current: ${MODEL_ID})"
  echo "  * Network / auth issue (need HF token export HF_TOKEN=...)"
  echo "  * Model gated and requires license acceptance"
  echo "  * Older huggingface_hub missing needed features (pip install -U huggingface_hub)"
  exit 3
  fi

  echo "Found ${#shards[@]} shard file(s). Example: ${shards[0]}"
  du -h "${MODEL_DIR}" | tail -n 1 || true
  echo "Download complete. To launch vLLM with this local path you could run for example:"
  echo "  podman run --rm --device nvidia.com/gpu=all -p 8000:8000 --ipc=host \\
    -v ${MODEL_DIR}:${MODEL_DIR}:Z vllm/vllm-openai:gptoss --model ${MODEL_DIR} --quantization mxfp4"
fi

# 2) Run vLLM with local model path (uncommented)
QUANTIZATION="${QUANTIZATION:-mxfp4}"
IMAGE="${IMAGE:-vllm/vllm-openai:gptoss}"
if [[ "$USE_REMOTE" -eq 1 ]]; then
  MODEL_ARG="${MODEL_ID}"
  OFFLINE_ENV=(-e HF_HOME=/root/.cache/huggingface -e TRANSFORMERS_CACHE=/root/.cache/huggingface)
  LOCAL_MOUNTS=(-v "${HF_CACHE}:/root/.cache/huggingface:Z")
  echo "Starting vLLM (remote model id=${MODEL_ID}) on port ${HOST_PORT} quant=${QUANTIZATION}"
else
  MODEL_ARG="${MODEL_DIR}"
  OFFLINE_ENV=(-e TRANSFORMERS_OFFLINE=1 -e HF_HOME=/root/.cache/huggingface)
  LOCAL_MOUNTS=(-v "${MODEL_DIR}:${MODEL_DIR}:Z" -v "${HF_CACHE}:/root/.cache/huggingface:Z")
  echo "Starting vLLM (local model path=${MODEL_DIR}) on port ${HOST_PORT} quant=${QUANTIZATION}"
fi
if ! command -v podman >/dev/null 2>&1; then
  echo "[ERROR] podman command not found. Install Podman first." >&2
  exit 10
fi

set -x
podman run --rm \
  --device "${GPUS}" \
  --ipc=host \
  -p "${HOST_PORT}:${CONTAINER_PORT}" \
  -e VLLM_DISABLE_SINKS=1 \
  -e VLLM_ATTENTION_BACKEND=TRITON_ATTN_VLLM_V1 \
  -e VLLM_USE_FLASH_ATTENTION=0 \
  "${OFFLINE_ENV[@]}" \
  "${LOCAL_MOUNTS[@]}" \
  "${IMAGE}" \
  --model "${MODEL_ARG}" \
  --quantization "${QUANTIZATION}"
set +x
