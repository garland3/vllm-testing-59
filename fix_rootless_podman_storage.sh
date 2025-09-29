#!/usr/bin/env bash
# fix_rootless_podman_storage.sh
# Resolve Podman rootless "database static dir ... does not match our static dir" errors.
# Two strategies:
#   1. revert    - Go back to default $HOME/.local/share/containers/storage
#   2. external  - Reinitialize a fresh store at an external path (no images preserved unless --migrate-layers)
#
# Usage examples:
#   ./fix_rootless_podman_storage.sh revert
#   ./fix_rootless_podman_storage.sh external --graphroot /external/sd1/podman-rootless --migrate-layers
#   ./fix_rootless_podman_storage.sh external --graphroot /external/sd1/podman-rootless --fresh
#
# NOTES:
#  - The mismatch happens if you copied the storage directory to a new path; the internal DB stores the original static dir and refuses mismatch.
#  - There is no supported in-place path rewrite; you must reinitialize or stay on the old path.
#  - "--migrate-layers" rsyncs image/overlay content but then REMOVES the old db so Podman recreates metadata; orphaned layers may be GC'd later.
#
set -euo pipefail
IFS=$'\n\t'

MODE=""
GRAPHROOT="/external/sd1/podman-rootless"   # default for external mode
RUNROOT_SUFFIX="-run"
MIGRATE_LAYERS=0
FRESH=0
DRY_RUN=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERR ]${NC} $*" >&2; }
ok(){ echo -e "${GREEN}[OK ]${NC} $*"; }

usage(){ cat <<EOF
fix_rootless_podman_storage.sh <mode> [options]
Modes:
  revert                Use default rootless storage (~/.local/share/containers/storage)
  external              Reinitialize at external --graphroot path
Options (external mode):
  --graphroot PATH      Destination graphroot (default: /external/sd1/podman-rootless)
  --migrate-layers      Rsync overlay data from old default store to new graphroot (best effort)
  --fresh               Do NOT copy any layers; start empty
Common:
  --dry-run             Show actions only
  -h|--help             Help
Mutual exclusion: --migrate-layers and --fresh cannot both be set.
EOF
}

[[ $# -eq 0 ]] && { usage; exit 1; }

MODE="$1"; shift || true
case "$MODE" in
  revert|external) ;;
  -h|--help) usage; exit 0;;
  *) err "Unknown mode: $MODE"; usage; exit 1;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --graphroot) GRAPHROOT="$2"; shift 2;;
    --migrate-layers) MIGRATE_LAYERS=1; shift;;
    --fresh) FRESH=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown option $1"; usage; exit 1;;
  esac
done

if (( MIGRATE_LAYERS && FRESH )); then
  err "--migrate-layers and --fresh are mutually exclusive"; exit 1
fi

UID_ACTUAL=$(id -u)
if [[ -n ${SUDO_USER:-} ]]; then
  warn "Run this script as the rootless user directly (no sudo). Rootless storage is per-user."; fi
if [[ $UID_ACTUAL -eq 0 ]]; then
  warn "You are root. This script targets ROOTLESS storage. Re-run as the normal user."; exit 2
fi

USER_HOME="$HOME"
DEFAULT_GRAPH="$USER_HOME/.local/share/containers/storage"
USER_CONF_DIR="$USER_HOME/.config/containers"
USER_STORAGE_CONF="$USER_CONF_DIR/storage.conf"

run() {
  if (( DRY_RUN )); then
    log "DRY-RUN: $*"
  else
    # Execute command safely without eval to avoid word-splitting surprises
    "$@"
  fi
}

backup_conf(){ if [[ -f "$USER_STORAGE_CONF" ]]; then run cp "$USER_STORAGE_CONF" "$USER_STORAGE_CONF.bak.$(date +%Y%m%d-%H%M%S)"; fi }

print_plan(){
  log "Mode: $MODE"
  if [[ $MODE == external ]]; then
    log "Target graphroot: $GRAPHROOT"
    log "Migrate layers: $MIGRATE_LAYERS"
    log "Fresh: $FRESH"
  else
    log "Reverting to default: $DEFAULT_GRAPH"
  fi
  log "Dry run: $DRY_RUN"
}

print_plan

# --- Early validation & debug ---
if [[ -z "${GRAPHROOT}" ]]; then
  err "GRAPHROOT resolved to empty string. Aborting to avoid destructive operations."; exit 4
fi
if [[ -z "${MODE}" ]]; then
  err "MODE empty (internal logic error)."; exit 5
fi

log "Debug: GRAPHROOT='${GRAPHROOT}' (length ${#GRAPHROOT})"
RUNROOT="${GRAPHROOT}${RUNROOT_SUFFIX}"
log "Debug: RUNROOT='${RUNROOT}'"

# Detect possible DOS line endings that could break parsing
if grep -q $'\r' "$0" 2>/dev/null; then
  warn "Script contains Windows (CRLF) line endings; consider: sed -i 's/\r$//' $0"
fi

echo -n "Proceed? (y/N): "
read -r ans
[[ $ans =~ ^[Yy]$ ]] || { err "Aborted"; exit 3; }

if [[ $MODE == revert ]]; then
  log "Reverting rootless Podman to default path"
  if [[ -f "$USER_STORAGE_CONF" ]]; then
    backup_conf
    run rm -f "$USER_STORAGE_CONF"
  fi
  # Ensure default exists
  run mkdir -p "$DEFAULT_GRAPH"
  log "Removing any partial alternative graphroot DB artifacts (non-destructive if absent)"
  run rm -f "$GRAPHROOT/db.sql" "$GRAPHROOT/storage.lock" 2>/dev/null || true
  log "Running podman system migrate"
  run podman system migrate || true
  log "podman info check"
  run podman info --format 'User GraphRoot={{ .Store.GraphRoot }}'
  ok "Revert complete."
  exit 0
fi

# External mode
log "Preparing external graphroot directories"
run mkdir -p "${GRAPHROOT}" "${RUNROOT}"
if [[ ! -d "${GRAPHROOT}" || ! -d "${RUNROOT}" ]]; then
  err "Failed to create GRAPHROOT='${GRAPHROOT}' or RUNROOT='${RUNROOT}'."; exit 6
fi
ok "Created/verified graphroot and runroot"
run chmod 711 "${GRAPHROOT}"
run chmod 700 "${RUNROOT}"

backup_conf
run mkdir -p "$USER_CONF_DIR"

# Ensure the user config directory is writable (may have become root-owned from earlier sudo runs)
if [[ ! -w "$USER_CONF_DIR" ]]; then
  err "Config directory $USER_CONF_DIR not writable by $(id -un)."
  echo "Suggested fix (run this once): sudo chown -R $(id -un):$(id -gn) $USER_CONF_DIR" >&2
  exit 7
fi

log "Writing storage.conf with new graphroot"
if (( DRY_RUN )); then
  log "DRY-RUN: would write $USER_STORAGE_CONF"
else
  cat > "$USER_STORAGE_CONF" <<EOF
[storage]
driver = "overlay"
graphroot = "$GRAPHROOT"
runroot = "$RUNROOT"
EOF
  # Double-check file ownership
  if [[ ! -w "$USER_STORAGE_CONF" ]]; then
    warn "Created $USER_STORAGE_CONF but it is not writable; check ownership (sudo chown $(id -un):$(id -gn) $USER_STORAGE_CONF)."
  fi
fi

if (( MIGRATE_LAYERS )); then
  if [[ -d "$DEFAULT_GRAPH" ]]; then
    log "Copying selected layer dirs from old store -> new"
    # Only copy overlay* and libimage to reduce size; DB will be regenerated.
    for d in overlay overlay-images overlay-layers; do
      if [[ -d "$DEFAULT_GRAPH/$d" ]]; then
        run rsync -aHAX "$DEFAULT_GRAPH/$d" "$GRAPHROOT/"
      fi
    done
  else
    warn "Default graphroot $DEFAULT_GRAPH missing; skipping layer copy"
  fi
fi

log "Removing any stale DB / libpod in new target (forces clean init)"
run rm -rf "$GRAPHROOT/db.sql" "$GRAPHROOT/libpod" 2>/dev/null || true

log "podman system migrate (expect new DB)"
run podman system migrate || true

log "Verification"
run podman info --format 'User GraphRoot={{ .Store.GraphRoot }} RunRoot={{ .Store.RunRoot }}'

ok "External reinit complete. Pull fresh images as needed."

if (( MIGRATE_LAYERS )); then
  warn "Layers copied without metadata: 'podman images' may show none until images are re-pulled; orphaned layer dirs can later be reclaimed with 'podman system prune -af'."
fi
