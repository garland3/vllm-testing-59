#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# vLLM run helper for Podman + NVIDIA (CDI) environment
# ------------------------------------------------------------
# Features added:
#  * Auto-detect available GPU count (nvidia-smi, CDI spec, or /proc)
#  * Prevent over-requesting tensor parallel size (adjust or abort)
#  * Optional quantization + extra args via env/flags
#  * Port + model configurable via flags or env vars
#  * Optional --pull flag passthrough
#  * Dry-run mode to just show final command
#  * Simple help output
#
# Examples:
#   ./run.sh                         # defaults (20B)
#   MODEL=openai/gpt-oss-20b ./run.sh -t 1
#   ./run.sh -m openai/gpt-oss-20b -t auto -q mxfp4 -- --max-model-len 65536
#   ./run.sh --no-flash -t 1                 # disable flash attention (debug)
#   ./run.sh --safe -t 1 --dtype bfloat16    # conservative fallback
#   ./run.sh --preflight                     # only run GPU capability test inside image
#   ./run.sh --force-no-quant -m openai/gpt-oss-20b -t 1  # override automatic mxfp4
#   PULL=always ./run.sh --dry-run
#
# Environment overrides:
#   IMAGE, MODEL, TP_SIZE, PORT, QUANTIZATION, EXTRA_ARGS, PULL
# ------------------------------------------------------------

# Fully-qualified image to avoid Podman short-name resolution errors.
IMAGE=${IMAGE:-"docker.io/vllm/vllm-openai:gptoss"}

# Defaults (overridable by env or flags)
MODEL=${MODEL:-"openai/gpt-oss-20b"}
TP_SIZE=${TP_SIZE:-"2"}          # or "auto" to match GPU count
PORT=${PORT:-"8000"}
QUANTIZATION=${QUANTIZATION:-""} # e.g. mxfp4, awq, fp8; empty = none
DTYPE=${DTYPE:-""}               # e.g. bfloat16, float16, auto
DISABLE_FLASH=1                   # set via --no-flash or --safe
SAFE_MODE=0                       # implies flash off + no quant + dtype=bfloat16
FORCE_NO_QUANT=0                  # pass --quantization none explicitly
PREFLIGHT_ONLY=0                  # run test program then exit
EXTRA_ARGS=${EXTRA_ARGS:-""}
PULL=${PULL:-""}                 # set to 'always' for --pull=always
DRY_RUN=0

print_help() {
  cat <<EOF
Usage: $0 [options] [-- <extra vLLM args>]
Options:
  -m, --model NAME          Model identifier (default: $MODEL)
  -t, --tp SIZE|auto        Tensor parallel size (default: $TP_SIZE)
  -p, --port PORT           Host port to expose API (default: $PORT)
  -q, --quant NAME          Quantization (e.g. mxfp4) (default: none)
  --dtype TYPE              Set model dtype override (e.g. bfloat16, float16)
  --no-flash                Disable FlashAttention (adds --disable-flash-attn + env)
  --safe                    Convenience: disable flash attn + unset quant + dtype=bfloat16
  --force-no-quant          Add --quantization none even if model repo suggests one
  --preflight               Run a CUDA + torch sanity test inside the image then exit
  --pull[=always|missing]   Override pull policy (default: env PULL or none)
  --dry-run                 Show resolved command and exit
  -h, --help                Show this help

Environment variables:
  IMAGE, MODEL, TP_SIZE, PORT, QUANTIZATION, EXTRA_ARGS, PULL

Any args after '--' are appended verbatim to the vLLM command.
EOF
}

EXTRA_AFTER_DASHDASH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model) MODEL="$2"; shift 2;;
    -t|--tp) TP_SIZE="$2"; shift 2;;
    -p|--port) PORT="$2"; shift 2;;
  -q|--quant|--quantization) QUANTIZATION="$2"; shift 2;;
  --dtype) DTYPE="$2"; shift 2;;
  --no-flash) DISABLE_FLASH=1; shift;;
  --safe) SAFE_MODE=1; DISABLE_FLASH=1; shift;;
  --force-no-quant) FORCE_NO_QUANT=1; shift;;
  --preflight) PREFLIGHT_ONLY=1; shift;;
    --pull) PULL="always"; shift;;
    --pull=*) PULL="${1#*=}"; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) print_help; exit 0;;
    --) shift; EXTRA_AFTER_DASHDASH=("$@"); break;;
    *) echo "Unknown argument: $1" >&2; print_help; exit 1;;
  esac
done

# GPU detection
detect_gpu_count() {
  local count
  if command -v nvidia-smi >/dev/null 2>&1; then
    count=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)
    if [[ -n "$count" && "$count" -gt 0 ]]; then echo "$count"; return 0; fi
  fi
  # Try CDI spec
  if [[ -f /etc/cdi/nvidia.yaml ]]; then
    count=$(grep -c 'device:' /etc/cdi/nvidia.yaml || true)
    if [[ -n "$count" && "$count" -gt 0 ]]; then echo "$count"; return 0; fi
  fi
  # Fallback /proc enumeration
  if [[ -d /proc/driver/nvidia/gpus ]]; then
    count=$(find /proc/driver/nvidia/gpus -maxdepth 1 -type d -name '[0-9]*' | wc -l)
    if [[ "$count" -gt 0 ]]; then echo "$count"; return 0; fi
  fi
  echo 0
}

GPU_COUNT=$(detect_gpu_count)
if [[ "$GPU_COUNT" -eq 0 ]]; then
  echo "[WARN] Could not detect any NVIDIA GPUs. Continuing; container may fall back to CPU or fail." >&2
fi

if [[ "$TP_SIZE" == "auto" ]]; then
  if [[ "$GPU_COUNT" -gt 0 ]]; then
    TP_SIZE="$GPU_COUNT"
  else
    TP_SIZE=1
  fi
fi

if [[ "$TP_SIZE" =~ ^[0-9]+$ ]] && [[ "$GPU_COUNT" -gt 0 ]] && [[ "$TP_SIZE" -gt "$GPU_COUNT" ]]; then
  echo "[WARN] Requested tensor-parallel-size=$TP_SIZE but only $GPU_COUNT GPU(s) detected." >&2
  echo "       Adjusting TP_SIZE -> $GPU_COUNT." >&2
  TP_SIZE="$GPU_COUNT"
fi

if ! [[ "$TP_SIZE" =~ ^[0-9]+$ ]] || [[ "$TP_SIZE" -lt 1 ]]; then
  echo "[ERROR] Invalid tensor parallel size: $TP_SIZE" >&2
  exit 1
fi

PULL_FLAG=""
if [[ -n "$PULL" ]]; then
  case "$PULL" in
    always|missing|newer) PULL_FLAG="--pull=$PULL";;
    *) echo "[WARN] Unknown pull policy '$PULL' ignored." >&2;;
  esac
fi

CMD_ARGS=("--model" "$MODEL" "--tensor-parallel-size" "$TP_SIZE")
if (( SAFE_MODE )); then
  QUANTIZATION=""
  [[ -z "$DTYPE" ]] && DTYPE="bfloat16"
fi

if (( FORCE_NO_QUANT )); then
  QUANTIZATION="none"
fi

if [[ -n "$QUANTIZATION" ]]; then
  CMD_ARGS+=("--quantization" "$QUANTIZATION")
fi

if [[ -n "$DTYPE" ]]; then
  CMD_ARGS+=("--dtype" "$DTYPE")
fi

if (( DISABLE_FLASH )); then
  # We'll try to add the CLI flag only if the image supports it; otherwise rely on env vars.
  SUPPORTS_FLASH_FLAG=0
  if command -v podman >/dev/null 2>&1; then
    if podman run --rm --device nvidia.com/gpu=all --entrypoint bash "$IMAGE" -c 'python -m vllm.entrypoints.openai.api_server --help 2>&1 | grep -q -- --disable-flash-attn' >/dev/null 2>&1; then
      SUPPORTS_FLASH_FLAG=1
    fi
  fi
  if [[ $SUPPORTS_FLASH_FLAG -eq 1 ]]; then
    CMD_ARGS+=("--disable-flash-attn")
  else
    echo "[INFO] Image does not expose --disable-flash-attn flag; using env-only disable." >&2
  fi
fi

# Support EXTRA_ARGS env and args after '--'
if [[ -n "$EXTRA_ARGS" ]]; then
  # shellcheck disable=SC2206
  EXTRA_SPLIT=( $EXTRA_ARGS )
  CMD_ARGS+=("${EXTRA_SPLIT[@]}")
fi
if [[ ${#EXTRA_AFTER_DASHDASH[@]} -gt 0 ]]; then
  CMD_ARGS+=("${EXTRA_AFTER_DASHDASH[@]}")
fi

echo "Image:             $IMAGE"
echo "Model:             $MODEL"
echo "Detected GPUs:     $GPU_COUNT"
echo "Tensor Parallel:   $TP_SIZE"
echo "Quantization:      ${QUANTIZATION:-none}" 
echo "DType:             ${DTYPE:-auto}" 
echo "FlashAttention:    $([[ $DISABLE_FLASH -eq 1 ]] && echo disabled || echo enabled)"
echo "Safe Mode:         $([[ $SAFE_MODE -eq 1 ]] && echo yes || echo no)"
echo "Force No Quant:    $([[ $FORCE_NO_QUANT -eq 1 ]] && echo yes || echo no)"
echo "Preflight Only:    $([[ $PREFLIGHT_ONLY -eq 1 ]] && echo yes || echo no)"
echo "Port:              $PORT"
echo "Pull Policy:       ${PULL:-none}" 
echo "Extra vLLM args:   ${CMD_ARGS[*]}"
[[ $DRY_RUN -eq 1 ]] && { echo "(dry run) Exiting before container start."; exit 0; }

if (( PREFLIGHT_ONLY )); then
  echo "Running preflight CUDA/torch test inside image..."
  set -x
  podman run --rm --device nvidia.com/gpu=all --entrypoint python \
    "${IMAGE}" - <<'EOF'
import os, torch, json, sys
print('Torch version:', torch.__version__)
print('CUDA available:', torch.cuda.is_available())
try:
    dc = torch.cuda.device_count()
    print('Device count:', dc)
    if dc:
        print('Device 0 name:', torch.cuda.get_device_name(0))
        print('Capability:', torch.cuda.get_device_capability(0))
except Exception as e:
    print('CUDA init error:', repr(e))
    sys.exit(42)
EOF
  set +x
  exit 0
fi

echo "Starting vLLM container..."
set -x
podman run --rm \
  --device nvidia.com/gpu=all \
  -p "${PORT}:8000" \
  --ipc=host \
  ${PULL_FLAG} \
  -e VLLM_USE_FLASH_ATTENTION=$((DISABLE_FLASH?0:1)) \
  -e VLLM_DISABLE_FLASH_ATTENTION=$((DISABLE_FLASH?1:0)) \
  "${IMAGE}" \
  "${CMD_ARGS[@]}"
set +x

# Notes:
#  If Ray still reports insufficient GPUs: confirm host sees expected GPUs with `nvidia-smi`.
#  To force a specific subset, set NVIDIA_VISIBLE_DEVICES env before running (if using legacy hook).
#  For CDI, you can enumerate devices via /etc/cdi/nvidia.yaml and selectively use them with
#     --device nvidia.com/gpu=0 --device nvidia.com/gpu=1

# Short-name usage guidance (optional):
# Add to /etc/containers/registries.conf or ~/.config/containers/registries.conf:
#   unqualified-search-registries = ["docker.io", "quay.io", "ghcr.io"]
# Or a short-name alias file /etc/containers/registries.conf.d/999-vllm-shortname.conf:
#   [[short-name-aliases]]
#     name="vllm/vllm-openai"
#     aliases=["docker.io/vllm/vllm-openai"]

