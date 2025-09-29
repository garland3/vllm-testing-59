#!/usr/bin/env bash
# collect_vllm_diagnostics.sh
# Helper to gather status + logs + GPU + container environment info for a running (or failed) vLLM container under Podman.
# Usage:
#   ./collect_vllm_diagnostics.sh                # auto-detect container (by image/name heuristics)
#   ./collect_vllm_diagnostics.sh vllm           # explicit container name or ID
#   CONTAINER=vllm ./collect_vllm_diagnostics.sh
#
# Output is printed to stdout; you can redirect to a file for support:
#   ./collect_vllm_diagnostics.sh > vllm_diag_$(date +%Y%m%d_%H%M%S).log 2>&1
#
set -euo pipefail

TARGET=${1:-${CONTAINER:-}}

header(){ echo -e "\n===== $* ====="; }

# 1. Identify container if not provided
if [[ -z $TARGET ]]; then
  # Try by common names first
  for guess in vllm vllm-api llm; do
    if podman ps -a --format '{{.Names}}' | grep -qx "$guess"; then TARGET=$guess; break; fi
  done
fi

if [[ -z $TARGET ]]; then
  # Try by image ancestor heuristics
  CANDIDATES=$(podman ps -a --format '{{.ID}} {{.Image}} {{.Names}}' | grep -E 'vllm/.*/vllm-openai|vllm-openai' || true)
  if [[ -n $CANDIDATES ]]; then
    TARGET=$(echo "$CANDIDATES" | head -n1 | awk '{print $1}')
    echo "[INFO] Auto-selected container: $TARGET" >&2
  else
    echo "[ERROR] Could not auto-detect a vLLM container. Pass a container name/ID." >&2
    exit 1
  fi
fi

# Confirm it exists
if ! podman ps -a --format '{{.ID}} {{.Names}}' | grep -q "$TARGET"; then
  echo "[ERROR] Container $TARGET not found." >&2
  exit 1
fi

header "BASIC PODMAN STATE";
podman ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}' | grep -E "(ID|$TARGET)" || true

header "INSPECT (filtered)";
podman inspect "$TARGET" --format '{{json .State}}' | jq . || true

header "RESOURCE USAGE (top 5 lines)";
podman top "$TARGET" -l 5 2>/dev/null || echo "(podman top not available for exited container)"

header "LAST 200 LOG LINES";
podman logs --tail 200 "$TARGET" || echo "(no logs)"

header "GPU INSIDE CONTAINER (nvidia-smi)";
if podman exec "$TARGET" which nvidia-smi >/dev/null 2>&1; then
  podman exec "$TARGET" nvidia-smi -L || true
else
  echo "nvidia-smi not found inside container"
fi

header "PYTORCH CUDA TEST";
if podman exec "$TARGET" python - <<'EOF'
try:
    import torch
    print('Torch version:', torch.__version__)
    print('CUDA available:', torch.cuda.is_available())
    print('CUDA device count:', torch.cuda.device_count())
    if torch.cuda.is_available():
        print('Device 0 name:', torch.cuda.get_device_name(0))
        print('Capability:', torch.cuda.get_device_capability(0))
except Exception as e:
    import traceback; traceback.print_exc()
EOF
then
  :
else
  echo "(PyTorch test failed)"
fi

header "ENV VARS (vLLM-related subset)";
podman exec "$TARGET" env | grep -E 'VLLM_|CUDA|NVIDIA|HF_|TRANSFORMERS_' || true

header "MOUNTED NVIDIA LIBS";
podman exec "$TARGET" bash -c 'ls -1 /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.* 2>/dev/null || true'

header "CDI SPEC (host excerpt)";
grep -E 'EGL_nvidia|libcuda|device:' /etc/cdi/nvidia.yaml 2>/dev/null | head -n 40 || echo "(no /etc/cdi/nvidia.yaml)"

header "HOST DRIVER SUMMARY";
nvidia-smi | head -n 10 || true

header "SUGGESTED NEXT STEPS";
cat <<'STEPS'
- Check for earlier stack trace in full logs: podman logs CONTAINER | less
- If CUDA device count is 0 inside container but host sees GPU: regenerate CDI (sudo nvidia-ctk cdi generate)
- If PyTorch test passes yet engine hangs: suspect kernel compilation / model weight download latency
- Try smaller model: run.sh -m openai/gpt-oss-7b --force-no-quant -t 1
- Try disabling compilation: add --enforce-eager to args
STEPS

exit 0
