#!/usr/bin/env bash
# verify_podman_gpu.sh - Diagnose & verify NVIDIA GPU availability inside Podman (rootless or root)
# Usage: bash verify_podman_gpu.sh [--pull] [--verbose]
# Requirements: NVIDIA driver installed, nvidia-container-toolkit (with CDI or OCI hook), Podman >=4.6 for --device nvidia.com/gpu

set -euo pipefail
IFS=$'\n\t'
PULL=0
VERBOSE=0
IMAGE_BASE="nvidia/cuda:12.4.0-base-ubuntu22.04"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull) PULL=1; shift;;
    --verbose|-v) VERBOSE=1; shift;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

log(){ echo -e "[INFO] $*"; }
warn(){ echo -e "[WARN] $*" >&2; }
err(){ echo -e "[ERR ] $*" >&2; }
run(){ [[ $VERBOSE -eq 1 ]] && echo "+ $*"; eval "$*"; }

log "Podman version: $(podman --version 2>/dev/null || echo 'podman missing')"

log "Checking /dev/nvidia* device nodes"
if ls /dev/nvidia* >/dev/null 2>&1; then
  ls -l /dev/nvidia* | sed 's/^/  /'
else
  err "No /dev/nvidia* devices found. Install NVIDIA driver & reboot."; exit 2
fi

log "Groups for user: $(id -nG)"
if ! id -nG | grep -qw video; then
  warn "User not in 'video' group. GPU access may fail rootless. Fix: sudo usermod -aG video $(id -un); then log out/in.";
fi

log "Checking for NVIDIA container toolkit binaries"
if command -v nvidia-container-cli >/dev/null 2>&1; then
  nvidia-container-cli --version | sed 's/^/  /'
else
  warn "nvidia-container-cli not found. Install nvidia-container-toolkit.";
fi

log "Looking for CDI (Container Device Interface) specs"
CDI_DIRS=(/etc/cdi "$HOME"/.config/cdi)
FOUND_CDI=0
for d in "${CDI_DIRS[@]}"; do
  if ls "$d"/nvidia*.yaml >/dev/null 2>&1; then
    log "  Found: $d/nvidia*.yaml"; FOUND_CDI=1
  fi
done
if [[ $FOUND_CDI -eq 0 ]]; then
  warn "No NVIDIA CDI spec found. If using Podman >=4.6 you can generate one: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml";
fi

log "Inspecting OCI hook directories (legacy method)"
for d in /usr/share/containers/oci/hooks.d /etc/containers/oci/hooks.d; do
  if [[ -d $d ]]; then
    echo "  $d:"; ls -1 "$d" | sed 's/^/    /'
  fi
done

if [[ $PULL -eq 1 ]]; then
  log "Pulling test CUDA image $IMAGE_BASE"
  run podman pull "$IMAGE_BASE"
fi

TEST_CMD_GPU=(podman run --rm --device nvidia.com/gpu=all "$IMAGE_BASE" nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)

log "Attempting GPU query with CDI flag ( --device nvidia.com/gpu=all )"
if OUTPUT=$("${TEST_CMD_GPU[@]}" 2>&1); then
  log "SUCCESS: GPU(s) visible:"; echo "$OUTPUT" | sed 's/^/  /'
  exit 0
else
  warn "CDI style failed: $OUTPUT"
fi

# Fallback: try legacy OCI hook (just run without special flags; hook should inject libs)
LEGACY_CMD=(podman run --rm "$IMAGE_BASE" nvidia-smi -L)
log "Attempting legacy hook invocation (no --device flag)"
if OUTPUT2=$("${LEGACY_CMD[@]}" 2>&1); then
  if grep -qi 'GPU 0' <<<"$OUTPUT2"; then
    log "SUCCESS via legacy OCI hook:"; echo "$OUTPUT2" | sed 's/^/  /'
    warn "Consider migrating to CDI: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
    exit 0
  else
    warn "Legacy run did not show GPUs: $OUTPUT2"
  fi
else
  warn "Legacy attempt failed: $OUTPUT2"
fi

err "GPU not accessible in container. Checklist:\n 1. Driver installed (nvidia-smi works host)\n 2. nvidia-container-toolkit installed\n 3. CDI spec generated (nvidia-ctk cdi generate) OR OCI hook present\n 4. User in 'video' group (relogin after change)\n 5. Podman >= 4.6 (check podman --version)"
exit 3
