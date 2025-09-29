# Minimal known-good launcher (no extra flags) replicating the command you confirmed works.
# Env overrides:
#   MODEL=openai/gpt-oss-20b
#   IMAGE=docker.io/vllm/vllm-openai:gptoss
#   PORT=8000
#   QUANT=mxfp4 (or none)
#   CACHE_DIR=/path/to/cache   (optional: if set, will mount at /data and use --download-dir)

set -euo pipefail

MODEL="${MODEL:-openai/gpt-oss-20b}"
IMAGE="${IMAGE:-docker.io/vllm/vllm-openai:gptoss}"
PORT="${PORT:-8000}"
QUANT="${QUANT:-mxfp4}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"  # default lower than 131072 to reduce memory footprint
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.90}"     # passed only if set
EAGER_FLAG=""
if [[ "${EAGER:-0}" == "1" ]]; then
	EAGER_FLAG="--enforce-eager"
fi

# Optional pre-download of model weights if PRE_DOWNLOAD=1
if [[ "${PRE_DOWNLOAD:-0}" == "1" ]]; then
	if [[ -z "${CACHE_DIR:-}" ]]; then
		CACHE_DIR="$(pwd)/model-cache"
		export CACHE_DIR
		echo "[Pre-download] CACHE_DIR not set; using default ${CACHE_DIR}";
	fi
	mkdir -p "${CACHE_DIR}"
	echo "[Pre-download] Fetching weights for ${MODEL} into ${CACHE_DIR} (resume enabled)";
	set +e
	podman run --rm \
		-v "${CACHE_DIR}:/data" \
		-e HF_HOME=/data/hf -e TRANSFORMERS_CACHE=/data/hf \
		-e HF_HUB_ENABLE_HF_TRANSFER=1 \
		"${IMAGE}" \
		bash -c "command -v huggingface-cli >/dev/null 2>&1 && huggingface-cli download '${MODEL}' --local-dir /data --local-dir-use-symlinks False --resume-download || python - <<'PYDL'\nimport os,sys\nfrom huggingface_hub import snapshot_download\nmodel='${MODEL}'\nprint('[Pre-download:fallback] snapshot_download', model)\ntry:\n    snapshot_download(repo_id=model, local_dir='/data', local_dir_use_symlinks=False, resume_download=True)\n    print('[Pre-download:fallback] Done.')\nexcept Exception as e:\n    print('[Pre-download:fallback] ERROR', e)\n    sys.exit(1)\nPYDL"
	PRE_RC=$?
	set -e
	if [[ $PRE_RC -ne 0 ]]; then
		echo "[Pre-download] WARNING: encountered errors (rc=$PRE_RC); continuing to server startup.";
	else
		echo "[Pre-download] Completed successfully.";
	fi
fi

MOUNT_ARGS=()
DL_ARGS=()
if [[ -n "${CACHE_DIR:-}" ]]; then
	mkdir -p "${CACHE_DIR}"
	echo "Using cache dir: ${CACHE_DIR}"
	MOUNT_ARGS+=( -v "${CACHE_DIR}:/data" )
	# Only set HF vars if cache is mounted
	MOUNT_ARGS+=( -e HF_HOME=/data/hf -e TRANSFORMERS_CACHE=/data/hf )
	DL_ARGS+=( --download-dir /data )
fi

echo "Launching model=${MODEL} quant=${QUANT} image=${IMAGE} port=${PORT}"
echo "Max model len=${MAX_MODEL_LEN} gpu_mem_util=${GPU_MEM_UTIL} eager=${EAGER:-0}"

podman run --rm --device nvidia.com/gpu=all \
	-p "${PORT}:8000" --ipc=host \
	-e VLLM_DISABLE_SINKS=1 -e VLLM_ATTENTION_BACKEND=TRITON_ATTN_VLLM_V1 \
	"${MOUNT_ARGS[@]}" \
	"${IMAGE}" \
	--model "${MODEL}" \
	--quantization "${QUANT}" \
	--max-model-len "${MAX_MODEL_LEN}" \
	--gpu-memory-utilization "${GPU_MEM_UTIL}" \
	${EAGER_FLAG} \
	"${DL_ARGS[@]}"