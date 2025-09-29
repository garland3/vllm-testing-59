#!/usr/bin/env bash
# migrate_podman_storage.sh
# Automate moving Podman (root + rootless) storage to an external mount.
# Usage (root migration + rootless): sudo ./migrate_podman_storage.sh
#        Dry run:                    sudo ./migrate_podman_storage.sh --dry-run
#        Custom mount:               sudo ./migrate_podman_storage.sh --target-mount /external/sd1
#
# Safe to re-run; it backs up configs and only rsyncs when source exists.
# Rootless part is executed as the invoking (non-sudo) user if SUDO_USER is set.
#
# Exit codes:
#  0 success, non-zero on error.
#
set -euo pipefail
IFS=$'\n\t'

# ---------- Defaults ----------
TARGET_MOUNT="/external/sd1"          # Path where external disk is mounted
ROOT_SUBDIR="podman-storage"          # Directory under TARGET_MOUNT for root storage
ROOTLESS_SUBDIR="podman-rootless"     # Directory under TARGET_MOUNT for rootless storage
ROOTLESS_RUN_SUFFIX="-run"
DRY_RUN=0
DO_ROOT=1
DO_ROOTLESS=1
FORCE=0

# ---------- Color / logging ----------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; }
success(){ echo -e "${GREEN}[OK  ]${NC} $*"; }

usage() {
  cat <<EOF
migrate_podman_storage.sh [options]
  --target-mount PATH      External mount point (default: ${TARGET_MOUNT})
  --root-subdir NAME       Subdirectory for root storage (default: ${ROOT_SUBDIR})
  --rootless-subdir NAME   Subdirectory for rootless storage (default: ${ROOTLESS_SUBDIR})
  --no-root                Skip root storage migration
  --no-rootless            Skip rootless storage migration
  --dry-run                Show what would happen without changing anything
  --force                  Skip confirmation prompt
  -h|--help                Show this help
EOF
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-mount) TARGET_MOUNT="$2"; shift 2;;
    --root-subdir) ROOT_SUBDIR="$2"; shift 2;;
    --rootless-subdir) ROOTLESS_SUBDIR="$2"; shift 2;;
    --no-root) DO_ROOT=0; shift;;
    --no-rootless) DO_ROOTLESS=0; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --force) FORCE=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown argument: $1"; usage; exit 1;;
  esac
done

# ---------- Sanity checks ----------
if [[ ! -d "$TARGET_MOUNT" ]]; then
  err "Target mount $TARGET_MOUNT does not exist. Mount the disk first."
  exit 2
fi

if (( DO_ROOT == 0 && DO_ROOTLESS == 0 )); then
  err "Both root and rootless migrations disabled. Nothing to do."
  exit 0
fi

if (( DRY_RUN )); then
  log "DRY RUN mode - no changes will be applied."
fi

# ---------- Determine calling user for rootless ----------
CALLING_USER=${SUDO_USER:-$(id -un)}
CALLING_UID=$(id -u "$CALLING_USER")
CALLING_HOME=$(eval echo ~"$CALLING_USER")

ROOT_TARGET="$TARGET_MOUNT/$ROOT_SUBDIR"
ROOT_RUN_TARGET="$ROOT_TARGET/run"
ROOTLESS_TARGET="$TARGET_MOUNT/$ROOTLESS_SUBDIR"
ROOTLESS_RUN_TARGET="$TARGET_MOUNT/${ROOTLESS_SUBDIR}${ROOTLESS_RUN_SUFFIX}"

# ---------- Functions ----------
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local b="$f.bak.$(date +%Y%m%d-%H%M%S)"
  (( DRY_RUN )) && { log "Would back up $f -> $b"; return 0; }
  cp "$f" "$b"
  log "Backup: $b"
}

update_storage_conf() {
  local conf="$1" new_graph="$2" new_run="$3" mode="$4"
  backup_file "$conf"
  local tmp="${conf}.tmp.$$"
  if (( DRY_RUN )); then
    log "Would update $mode storage.conf graphroot=$new_graph runroot=$new_run"
    return 0
  fi
  awk -v g="$new_graph" -v r="$new_run" '
    BEGIN{gr=0; rr=0}
    /^graphroot/ {print "graphroot = \"" g "\""; gr=1; next}
    /^runroot/   {print "runroot = \"" r "\""; rr=1; next}
    {print}
    END{ if(!gr) print "graphroot = \"" g "\""; if(!rr) print "runroot = \"" r "\""; }
  ' "$conf" > "$tmp" && mv "$tmp" "$conf"
  success "$mode storage.conf updated"
}

rsync_dir() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || { warn "Source $src missing, skipping rsync"; return 0; }
  (( DRY_RUN )) && { log "Would rsync $src -> $dst"; return 0; }
  rsync -aHAX --delete "$src/" "$dst/"
  success "Rsync completed $src -> $dst"
}

ensure_dir() {
  local path="$1" perm="$2" owner="$3"
  if (( DRY_RUN )); then
    log "Would ensure dir $path perm=$perm owner=$owner"
    return 0
  fi
  mkdir -p "$path"
  chmod "$perm" "$path"
  chown "$owner" "$path"
}

confirm() {
  (( FORCE )) && return 0
  echo -n "Proceed with migration (y/N)? "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]] || { err "Aborted by user"; exit 3; }
}

print_plan() {
  cat <<EOF
Plan:
  Target mount:           $TARGET_MOUNT
  Root GraphRoot:         $ROOT_TARGET
  Root RunRoot:           $ROOT_RUN_TARGET
  Rootless GraphRoot:     $ROOTLESS_TARGET (user: $CALLING_USER)
  Rootless RunRoot:       $ROOTLESS_RUN_TARGET
  Do root:                $DO_ROOT
  Do rootless:            $DO_ROOTLESS
  Dry run:                $DRY_RUN
EOF
}

# ---------- Start ----------
print_plan
confirm

if (( DO_ROOT )); then
  log "=== Root (system) migration ==="
  CURRENT_ROOT_GRAPHROOT=$(podman info --root --format '{{ .Store.GraphRoot }}' 2>/dev/null || true)
  # Fallback to sudo if necessary
  if [[ -z "$CURRENT_ROOT_GRAPHROOT" ]]; then
    CURRENT_ROOT_GRAPHROOT=$(sudo podman info --format '{{ .Store.GraphRoot }}' 2>/dev/null || true)
  fi
  log "Current root graphroot: ${CURRENT_ROOT_GRAPHROOT:-<none>}"
  ensure_dir "$ROOT_TARGET" 0711 root:root
  ensure_dir "$ROOT_RUN_TARGET" 0700 root:root
  # Rsync only if different and existing
  if [[ -n "$CURRENT_ROOT_GRAPHROOT" && "$CURRENT_ROOT_GRAPHROOT" != "$ROOT_TARGET" ]]; then
    rsync_dir "$CURRENT_ROOT_GRAPHROOT" "$ROOT_TARGET"
  fi
  # Update storage.conf
  SYSTEM_CONF="/etc/containers/storage.conf"
  if [[ ! -f "$SYSTEM_CONF" ]]; then
    if (( DRY_RUN )); then
      log "Would create $SYSTEM_CONF"
    else
      cat > "$SYSTEM_CONF" <<EOF
[storage]
driver = "overlay"
EOF
    fi
  fi
  update_storage_conf "$SYSTEM_CONF" "$ROOT_TARGET" "$ROOT_RUN_TARGET" "Root"
  (( DRY_RUN )) || sudo podman system migrate || warn "Root migrate returned non-zero"
fi

if (( DO_ROOTLESS )); then
  log "=== Rootless (user: $CALLING_USER) migration ==="
  ensure_dir "$ROOTLESS_TARGET" 0711 "$CALLING_USER:$CALLING_USER"
  ensure_dir "$ROOTLESS_RUN_TARGET" 0700 "$CALLING_USER:$CALLING_USER"
  USER_CONF="$CALLING_HOME/.config/containers/storage.conf"
  if (( DRY_RUN )); then
    log "Would modify $USER_CONF"
  else
    mkdir -p "$(dirname "$USER_CONF")"
    if [[ ! -f "$USER_CONF" ]]; then
      cat > "$USER_CONF" <<EOF
[storage]
driver = "overlay"
EOF
    fi
    # Run rsync for rootless only if we can detect prior rootless dir
    PREV_ROOTLESS_DIR="$CALLING_HOME/.local/share/containers/storage"
    [[ -d "$PREV_ROOTLESS_DIR" && "$PREV_ROOTLESS_DIR" != "$ROOTLESS_TARGET" ]] && rsync_dir "$PREV_ROOTLESS_DIR" "$ROOTLESS_TARGET"
    update_storage_conf "$USER_CONF" "$ROOTLESS_TARGET" "$ROOTLESS_RUN_TARGET" "Rootless"
    # Execute migrate as the rootless user
    if [[ -n "${SUDO_USER:-}" ]]; then
      sudo -u "$CALLING_USER" XDG_RUNTIME_DIR="/run/user/$CALLING_UID" podman system migrate || warn "Rootless migrate returned non-zero"
    else
      podman system migrate || warn "Rootless migrate returned non-zero"
    fi
  fi
fi

log "=== Verification ==="
if (( DRY_RUN )); then
  log "Dry run complete. No verification performed."
else
  sudo podman info --format 'Root GraphRoot={{ .Store.GraphRoot }} RunRoot={{ .Store.RunRoot }}' || warn 'Cannot read root info'
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$CALLING_USER" XDG_RUNTIME_DIR="/run/user/$CALLING_UID" podman info --format 'User GraphRoot={{ .Store.GraphRoot }} RunRoot={{ .Store.RunRoot }}' || warn 'Cannot read rootless info'
  else
    podman info --format 'User GraphRoot={{ .Store.GraphRoot }} RunRoot={{ .Store.RunRoot }}' || warn 'Cannot read rootless info'
  fi
  df -h "$ROOT_TARGET" | tail -n1 || true
  df -h "$ROOTLESS_TARGET" | tail -n1 || true
fi

success "Migration script completed."
log "If satisfied, you may prune old storage: sudo podman system prune -af (CAUTION)."
