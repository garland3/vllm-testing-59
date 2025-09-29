#!/usr/bin/env bash
# cleanup_space.sh - Guided cleanup for reclaiming root filesystem space.
# Usage: sudo ./cleanup_space.sh [--auto] [--dry-run] [--move-large /external/sd1/bulk]
#
# Features:
#  - Summarize large known hogs (Docker, Podman, Ollama, libvirt, caches, downloads)
#  - Optionally prune Docker & Podman unused objects
#  - Move large single files (ISOs, VM images, model blobs) to another filesystem
#  - Trim journal, APT cache, old kernels (safe removal logic)
#  - Report reclaimed space
#
# This script is intentionally verbose and interactive (unless --auto or --dry-run are passed)
# to give the user control over destructive operations.  Each logical block is wrapped in a
# `section` call which prints a header; the comments below explain the intent of each block.
#
set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# Configuration flags (set via command‑line arguments)
# ----------------------------------------------------------------------
AUTO=0               # If set to 1, skips all prompts (non‑interactive mode)
DRY_RUN=0            # If set to 1, commands are shown but not executed
MOVE_TARGET=""       # Destination directory for moving large files (if provided)
LOG=/tmp/cleanup_space_$(date +%Y%m%d-%H%M%S).log   # Log file for all output

# ----------------------------------------------------------------------
# Color definitions for pretty‑printing
# ----------------------------------------------------------------------
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG" >&2; }
err(){ echo -e "${RED}[ERR ]${NC} $*" | tee -a "$LOG" >&2; }
ok(){ echo -e "${GREEN}[OK  ]${NC} $*" | tee -a "$LOG"; }

# ----------------------------------------------------------------------
# Helper: display usage information
# ----------------------------------------------------------------------
usage(){ cat <<EOF
cleanup_space.sh [options]
  --auto                 Run non-destructive prunes + safe cleanups without prompts
  --dry-run              Show what would be done, no changes
  --move-large DIR       Move identified large standalone files to DIR (must exist)
  -h|--help              Show this help
EOF
}

# ----------------------------------------------------------------------
# Parse command‑line arguments
# ----------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --move-large) MOVE_TARGET="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 1;;
  esac
done

# ----------------------------------------------------------------------
# Ensure script is run as root (required for some operations)
# ----------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "Run with sudo for full cleanup (docker/podman/journal/kernels)."; exit 2
fi

# ----------------------------------------------------------------------
# Capture initial free space (bytes) for later reporting
# ----------------------------------------------------------------------
start_df=$(df -B1 / | awk 'NR==2{print $4}')

# ----------------------------------------------------------------------
# Prompt helper: returns true if AUTO mode or user confirms
# ----------------------------------------------------------------------
prompt(){ local q="$1"; (( AUTO )) && return 0; read -rp "$q [y/N]: " ans; [[ $ans =~ ^[Yy]$ ]]; }

# ----------------------------------------------------------------------
# Execute command unless in dry‑run mode
# ----------------------------------------------------------------------
do_cmd(){ if (( DRY_RUN )); then info "DRY‑RUN: $*"; else eval "$*"; fi }

# ----------------------------------------------------------------------
# Print a formatted section header
# ----------------------------------------------------------------------
section(){ echo; info "==== $* ===="; }

# ----------------------------------------------------------------------
# SECTION: Summary before cleanup
# Show current root usage before any actions are taken.
# ----------------------------------------------------------------------
section "Summary before cleanup"
root_used=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')
info "Root usage: $root_used"

# ----------------------------------------------------------------------
# SECTION: Large directories
# Lists disk usage for a set of known large directories to give context.
# ----------------------------------------------------------------------
section "Large directories"
for d in /var/lib /usr/share/ollama/.ollama/models /home /var/lib/libvirt/images /usr /var/log /home/*/Downloads; do
  [[ -e $d ]] || continue
  du -sh "$d" 2>/dev/null | tee -a "$LOG"
done

# ----------------------------------------------------------------------
# SECTION: Top 20 large files (>=1G)
# Finds the biggest files on the system for potential manual review.
# ----------------------------------------------------------------------
section "Top 20 large files (>=1G)"
find / -xdev -type f -size +1G -printf '%s %p\n' 2>/dev/null | sort -nr | head -n 20 | awk '{printf "%10.1f GB  %s\n", $1/1024/1024/1024, $2}' | tee -a "$LOG"

# ----------------------------------------------------------------------
# SECTION: Docker prune
# Optionally removes all unused Docker resources.
# ----------------------------------------------------------------------
section "Docker prune"
if command -v docker >/dev/null; then
  docker system df || true
  if prompt "Prune ALL unused Docker data (images, containers, build cache)?"; then
    do_cmd "docker system prune -af"
  fi
else
  info "Docker not installed or not in PATH."
fi

# ----------------------------------------------------------------------
# SECTION: Podman prune
# Optionally removes all unused Podman resources.
# ----------------------------------------------------------------------
section "Podman prune"
if command -v podman >/dev/null; then
  if prompt "Prune ALL unused Podman data?"; then
    do_cmd "podman system prune -af"
  fi
fi

# ----------------------------------------------------------------------
# SECTION: Journal cleanup
# Vacuum systemd journal logs to free space.
# ----------------------------------------------------------------------
section "Journal cleanup"
journalctl --disk-usage || true
if prompt "Vacuum journals to 500M?"; then
  do_cmd "journalctl --vacuum-size=500M"
fi

# ----------------------------------------------------------------------
# SECTION: APT cache cleanup
# Clears the apt package cache if the user agrees.
# ----------------------------------------------------------------------
section "APT cache"
if [[ -d /var/cache/apt/archives ]]; then
  du -sh /var/cache/apt/archives | tee -a "$LOG"
  if prompt "Clean APT package cache?"; then
    do_cmd "apt-get clean"
  fi
fi

# ----------------------------------------------------------------------
# SECTION: Old kernel images
# Detects and optionally removes old kernels, keeping the current and the two newest.
# ----------------------------------------------------------------------
section "Old kernel images"
current_kernel=$(uname -r | sed 's/-generic//')
mapfile -t kernels < <(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/{print $2}' | grep -E 'linux-image-[0-9]')
if (( ${#kernels[@]} > 2 )); then
  printf 'Installed kernels:\n' | tee -a "$LOG"
  printf '%s\n' "${kernels[@]}" | tee -a "$LOG"
  if prompt "Auto-remove unused kernels (keeps current + latest two)?"; then
    keep=$(printf '%s\n' "${kernels[@]}" | tail -n2)
    for k in "${kernels[@]}"; do
      if ! grep -q "$k" <<< "$keep"; then
        do_cmd "apt-get -y purge $k" || true
      fi
    done
    do_cmd "apt-get -y autoremove"
  fi
fi

# ----------------------------------------------------------------------
# SECTION: Move large files
# Moves large ISO/IMG/VMDK/etc files (or HF temporary blobs) to a user‑specified location.
# ----------------------------------------------------------------------
section "Move large files"
if [[ -n "$MOVE_TARGET" ]]; then
  if [[ ! -d "$MOVE_TARGET" ]]; then
    err "MOVE_TARGET $MOVE_TARGET missing"
  else
    info "Will move: ISO/IMG/VDI/7z >2G and HF tmp >1G"
    mapfile -t bigfiles < <(find /home /var/lib/libvirt/images /usr/share/ollama/.ollama/models -maxdepth 4 -type f \
      \( -iname '*.iso' -o -iname '*.img' -o -iname '*.vdi' -o -iname '*.7z' \) -size +2G 2>/dev/null)
    # Include HF temp large blobs
    mapfile -t hf_tmp < <(find /home -path '*/.cache/huggingface/*' -type f -size +1G 2>/dev/null)
    for f in "${hf_tmp[@]}"; do bigfiles+=("$f"); done
    if (( ${#bigfiles[@]} )); then
      printf 'Candidates (%d):\n' ${#bigfiles[@]} | tee -a "$LOG"
      printf '%s\n' "${bigfiles[@]}" | tee -a "$LOG"
      if prompt "Move these files to $MOVE_TARGET (preserve names)?"; then
        for f in "${bigfiles[@]}"; do
          base=$(basename "$f")
          dest="$MOVE_TARGET/$base"
          if (( DRY_RUN )); then
            info "DRY‑RUN: mv '$f' '$dest'"
          else
            mv "$f" "$dest" && ok "Moved $f -> $dest" || warn "Failed move $f"
          fi
        done
      fi
    else
      info "No candidate large files found."
    fi
  fi
else
  info "Skipping file moves (no --move-large specified)."
fi

# ----------------------------------------------------------------------
# SECTION: HuggingFace cache temporary cleanup
# Removes temporary HuggingFace cache directories (>1G) if the user agrees.
# ----------------------------------------------------------------------
section "HuggingFace cache temp cleanup"
if prompt "Remove HF tmp* directories (>1G) inside ~/.cache/huggingface?"; then
  mapfile -t hf_tmpdirs < <(find /home -path '*/.cache/huggingface/tmp*' -type d 2>/dev/null)
  for d in "${hf_tmpdirs[@]}"; do
    do_cmd "rm -rf '$d'"
  done
fi

# ----------------------------------------------------------------------
# SECTION: Ollama models
# Reports model storage usage; manual removal is recommended via the Ollama CLI.
# ----------------------------------------------------------------------
section "Ollama models"
if [[ -d /usr/share/ollama/.ollama/models ]]; then
  du -sh /usr/share/ollama/.ollama/models | tee -a "$LOG"
  warn "Manual removal recommended via ollama CLI to keep index consistency."
fi

# ----------------------------------------------------------------------
# FINAL REPORT
# Calculates and displays the amount of space reclaimed.
# ----------------------------------------------------------------------
section "Post-cleanup space"
end_df=$(df -B1 / | awk 'NR==2{print $4}')
saved=$(( (end_df - start_df) / 1024 / 1024 ))
info "Approx reclaimed: ${saved} MB (rough estimate)"
root_used_after=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')
ok "Root usage now: $root_used_after"

info "Log saved to: $LOG"
# End of script: logs actions and, if dry-run, informs that no changes were made.
(( DRY_RUN )) && warn 'This was a dry run. No changes applied.'
