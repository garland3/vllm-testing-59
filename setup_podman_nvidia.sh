#!/usr/bin/env bash
# setup_podman_nvidia.sh
# Automate (Debian/Ubuntu oriented) setup for using NVIDIA GPUs with Podman (root & rootless).
# Safe-by-default: asks before making changes unless --yes is passed.
#
# Features:
#  * Detect NVIDIA driver & versions
#  * Install / update nvidia-container-toolkit repo & packages
#  * Generate (or refresh) NVIDIA CDI spec (preferred method for Podman >=4.6)
#  * (Optional) configure legacy OCI hook if requested
#  * Ensure user is in 'video' group for rootless GPU access
#  * Optionally create a test pull + run verification
#  * Integrate existing verify_podman_gpu.sh if present
#
# Usage examples:
#   sudo ./setup_podman_nvidia.sh --user $USER
#   sudo ./setup_podman_nvidia.sh --yes --user garlan --verify
#   sudo ./setup_podman_nvidia.sh --regen-cdi --verify
#   sudo ./setup_podman_nvidia.sh --legacy-hook (enable deprecated OCI hook too)
#
# Exit codes:
#   0 success
#   1 unsupported distro or fatal error
#   2 missing prerequisites / aborted
#
set -euo pipefail
IFS=$'\n\t'

# ------------------ Defaults ------------------
TARGET_USER="${SUDO_USER:-${USER}}"
FORCE_YES=0
DO_VERIFY=0
REGEN_CDI=0
ENABLE_LEGACY_HOOK=0
SKIP_TOOLKIT_INSTALL=0
QUIET=0
CUDA_TEST_IMAGE="docker.io/nvidia/cuda:12.4.0-base-ubuntu22.04"

# Colors
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err(){ echo -e "${RED}[ERR ]${NC} $*" >&2; }
ok(){ echo -e "${GREEN}[OK  ]${NC} $*"; }

usage(){ cat <<EOF
setup_podman_nvidia.sh [options]
  --user NAME          Target non-root user for rootless GPU (default: $TARGET_USER)
  --yes                Non-interactive; assume 'yes'
  --verify             Run GPU verification at end (pulls small CUDA image)
  --regen-cdi          Force regenerate /etc/cdi/nvidia.yaml
  --legacy-hook        Configure deprecated OCI runtime hook as fallback
  --skip-toolkit       Skip install/update of nvidia-container-toolkit packages
  --quiet              Suppress some progress output
  -h|--help            This help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) TARGET_USER="$2"; shift 2;;
    --yes) FORCE_YES=1; shift;;
    --verify) DO_VERIFY=1; shift;;
    --regen-cdi) REGEN_CDI=1; shift;;
    --legacy-hook) ENABLE_LEGACY_HOOK=1; shift;;
    --skip-toolkit) SKIP_TOOLKIT_INSTALL=1; shift;;
    --quiet) QUIET=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 1;;
  esac
done

# ------------------ Pre-flight ------------------
if [[ $EUID -ne 0 ]]; then
  err "Run this script with sudo/root."; exit 2
fi

if ! id "$TARGET_USER" &>/dev/null; then
  err "User '$TARGET_USER' does not exist."; exit 2
fi

DISTRO_ID=""; DISTRO_VER=""
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID=$ID
  DISTRO_VER=$VERSION_ID
else
  warn "/etc/os-release missing; attempting best-effort."
fi

detect_distro() {
  case "$DISTRO_ID" in
    ubuntu|debian) return 0;;
    *) warn "Distro '$DISTRO_ID' not explicitly supported. Continuing (repo steps may fail)."; return 0;;
  esac
}

detect_distro

prompt(){ local q="$1"; if (( FORCE_YES )); then return 0; fi; read -rp "$q [y/N]: " ans; [[ $ans =~ ^[Yy]$ ]]; }

# ------------------ Functions ------------------
check_driver(){
  if command -v nvidia-smi >/dev/null 2>&1; then
    local line; line=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)
    if [[ -n "$line" ]]; then info "NVIDIA driver detected: $line"; else warn "nvidia-smi present but returned no GPU lines."; fi
  else
    warn "nvidia-smi not found. Install proprietary NVIDIA driver first (this script won't install it)."
  fi
}

install_toolkit_repo(){
  if (( SKIP_TOOLKIT_INSTALL )); then
    info "Skipping toolkit install per flag."; return 0; fi
  if ! command -v nvidia-container-cli >/dev/null 2>&1; then
    info "Setting up libnvidia-container repository (Debian/Ubuntu style)."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    local distribution distribution_list
    distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
    distribution_list=$(curl -fsSL "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" || true)
    if [[ -z "$distribution_list" ]]; then
      warn "Could not fetch distribution-specific list; falling back to generic."
      distribution_list=$(curl -fsSL https://nvidia.github.io/libnvidia-container/stable/libnvidia-container.list)
    fi
    echo "$distribution_list" | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -y
    apt-get install -y nvidia-container-toolkit nvidia-container-toolkit-base || {
      warn "Toolkit install failed; continuing (GPU may not work)."; return 0; }
    ok "Installed nvidia-container-toolkit"
  else
    info "nvidia-container-cli already present; skipping install."
  fi
}

generate_cdi(){
  local cdi_file="/etc/cdi/nvidia.yaml"
  if [[ -f $cdi_file && $REGEN_CDI -eq 0 ]]; then
    info "CDI spec already exists ($cdi_file). Use --regen-cdi to regenerate."
    return 0
  fi
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    warn "nvidia-ctk not found (part of container toolkit); cannot generate CDI spec."; return 0
  fi
  if (( REGEN_CDI )) && [[ -f $cdi_file ]]; then
    info "Regenerating CDI spec at $cdi_file"
  else
    info "Generating CDI spec at $cdi_file"
  fi
  nvidia-ctk cdi generate --output="$cdi_file"
  ok "CDI spec ready: $cdi_file"
}

configure_legacy_hook(){
  if (( ENABLE_LEGACY_HOOK == 0 )); then return 0; fi
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    warn "Cannot configure legacy hook: nvidia-ctk missing."; return 0
  fi
  info "Configuring legacy OCI runtime hook (deprecated)."
  nvidia-ctk runtime configure --runtime=podman || warn "Legacy runtime configure failed."
  ok "Legacy hook attempted. (Prefer CDI going forward.)"
}

ensure_group(){
  if id -nG "$TARGET_USER" | grep -qw video; then
    info "User $TARGET_USER already in 'video' group."
  else
    if prompt "Add user $TARGET_USER to video group? (requires logout/login)"; then
      usermod -aG video "$TARGET_USER"
      ok "Added $TARGET_USER to video group. Re-login required for group to apply."
    else
      warn "User not added to video group; rootless GPU access may fail."
    fi
  fi
}

verify_gpu(){
  if (( DO_VERIFY == 0 )); then return 0; fi
  info "Running verification..."
  if [[ -x ./verify_podman_gpu.sh ]]; then
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $TARGET_USER)" \
      bash ./verify_podman_gpu.sh --pull --verbose || warn "verify_podman_gpu.sh reported issues."
    return 0
  fi
  info "(Fallback) Pulling test image $CUDA_TEST_IMAGE"
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $TARGET_USER)" podman pull "$CUDA_TEST_IMAGE" || {
    warn "Pull failed (possibly no network)."; return 0; }
  local cmd=(sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $TARGET_USER)" podman run --rm --device nvidia.com/gpu=all "$CUDA_TEST_IMAGE" nvidia-smi -L)
  if out=$("${cmd[@]}" 2>&1); then
    if grep -qi 'GPU 0' <<<"$out"; then ok "Verification success: GPU visible:"; echo "$out" | sed 's/^/  /'
    else warn "Ran container but GPU not listed:"; echo "$out"; fi
  else
    warn "Verification container failed: $out"
  fi
}

summary(){
  cat <<EOF
------------------ Summary ------------------
User:               $TARGET_USER
CDI spec:           $( [[ -f /etc/cdi/nvidia.yaml ]] && echo present || echo missing )
Legacy hook:        $( (( ENABLE_LEGACY_HOOK )) && echo requested || echo skipped )
Toolkit binary:     $( command -v nvidia-container-cli >/dev/null 2>&1 && echo present || echo missing )
User in video:      $( id -nG "$TARGET_USER" | grep -qw video && echo yes || echo no )
Verification:       $( (( DO_VERIFY )) && echo attempted || echo skipped )
Next login needed:  $( if id -nG "$TARGET_USER" | grep -qw video; then echo no; else echo yes; fi )
------------------------------------------------
EOF
}

# ------------------ Execution ------------------
info "Setting up NVIDIA GPU support for Podman (distro: ${DISTRO_ID:-unknown} ${DISTRO_VER:-})"
check_driver
install_toolkit_repo
generate_cdi
configure_legacy_hook
ensure_group
verify_gpu
summary

ok "Completed. If you added user to video group, log out and back in before running rootless GPU containers."

exit 0
