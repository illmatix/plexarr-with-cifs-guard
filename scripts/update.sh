#!/usr/bin/env bash
set -euo pipefail

# Resolve this script's directory even if called via symlink
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_PATH" ]; do
  DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"

# Repo root = parent of ./scripts
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Compose file is now absolute and safe
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

cd "$(dirname "$0")"

# --- Config (override via env or flags) ---------------------------------------
COMPOSE_FILE="${COMPOSE_FILE:-./docker-compose.yml}"
REQUIRE_MOUNT="${REQUIRE_MOUNT:-/mnt/nas}"     # set to "" to skip the mount check
PRUNE="${PRUNE:-true}"                         # false to skip prune
ONLY="${ONLY:-}"                               # comma-separated services to include
EXCEPT="${EXCEPT:-}"                           # comma-separated services to exclude
RUNNING_ONLY="${RUNNING_ONLY:-false}"          # true = only update currently running services
ROLLING="${ROLLING:-true}"                     # true = no 'down'; do rolling 'up -d'
FORCE_RECREATE="${FORCE_RECREATE:-false}"      # true = --force-recreate on up
DRY_RUN="${DRY_RUN:-false}"                    # true = print actions, do nothing

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Options:
  -f, --file FILE            Compose file (default: ${COMPOSE_FILE})
  -o, --only s1,s2           Only update these services
  -x, --except s1,s2         Exclude these services
  -r, --running              Only update services currently running
  -n, --no-prune             Skip docker prune at the end
  -d, --dry-run              Show what would happen, do nothing
  --no-rolling               Use 'compose down' then 'up -d' (downtime)
  --force-recreate           Force container recreate on 'up -d'
  --no-mount-check           Skip checking ${REQUIRE_MOUNT}
  -h, --help                 Show help

Environment overrides are supported for all caps variables above.
EOF
}

# --- Parse args ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)            COMPOSE_FILE="$2"; shift 2;;
    -o|--only)            ONLY="$2"; shift 2;;
    -x|--except)          EXCEPT="$2"; shift 2;;
    -r|--running)         RUNNING_ONLY="true"; shift;;
    -n|--no-prune)        PRUNE="false"; shift;;
    -d|--dry-run)         DRY_RUN="true"; shift;;
    --no-rolling)         ROLLING="false"; shift;;
    --force-recreate)     FORCE_RECREATE="true"; shift;;
    --no-mount-check)     REQUIRE_MOUNT=""; shift;;
    -h|--help)            usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

# --- Preflight -----------------------------------------------------------------
command -v docker >/dev/null || { echo "docker not found"; exit 1; }
COMPOSE_CMD=(docker compose -f "$COMPOSE_FILE")

# Ensure compose file is readable
[[ -r "$COMPOSE_FILE" ]] || { echo "Compose file not found: $COMPOSE_FILE" >&2; exit 1; }

# Optional: ensure NAS is mounted to avoid binding empty dirs
if [[ -n "${REQUIRE_MOUNT}" ]]; then
  if ! findmnt -rn --target "$REQUIRE_MOUNT" >/dev/null 2>&1; then
    echo "ERROR: Required mount '$REQUIRE_MOUNT' is not mounted. Aborting to avoid empty binds." >&2
    exit 1
  fi
fi

# --- Discover services ----------------------------------------------------------
mapfile -t ALL_SERVICES < <("${COMPOSE_CMD[@]}" config --services)

# Apply filters
filter_list() {
  local -n in_arr=$1 out_arr=$2
  local only="$3" except="$4" running_only="$5"
  local keep declare IFS=,
  local only_set=() except_set=() run_set=()

  # ONLY set
  if [[ -n "$only" ]]; then read -r -a only_set <<< "$only"; fi
  # EXCEPT set
  if [[ -n "$except" ]]; then read -r -a except_set <<< "$except"; fi
  # RUNNING set
  if [[ "$running_only" == "true" ]]; then
    mapfile -t run_set < <("${COMPOSE_CMD[@]}" ps --services --status=running)
  fi

  for s in "${in_arr[@]}"; do
    keep=1
    if [[ ${#only_set[@]} -gt 0 ]]; then
      keep=0
      for o in "${only_set[@]}"; do [[ "$s" == "$o" ]] && keep=1; done
    fi
    if [[ $keep -eq 1 && ${#except_set[@]} -gt 0 ]]; then
      for x in "${except_set[@]}"; do [[ "$s" == "$x" ]] && keep=0; done
    fi
    if [[ $keep -eq 1 && ${#run_set[@]} -gt 0 ]]; then
      local found=0
      for r in "${run_set[@]}"; do [[ "$s" == "$r" ]] && found=1; done
      [[ $found -eq 1 ]] || keep=0
    fi
    [[ $keep -eq 1 ]] && out_arr+=("$s")
  done
}

SERVICES=()
filter_list ALL_SERVICES SERVICES "$ONLY" "$EXCEPT" "$RUNNING_ONLY"

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  echo "No services matched filters. All services in file: ${ALL_SERVICES[*]}" >&2
  exit 1
fi

echo "Services to update: ${SERVICES[*]}"

# --- Actions -------------------------------------------------------------------
run() { echo "+ $*"; [[ "$DRY_RUN" == "true" ]] || eval "$@"; }

# Always pull images first
run "${COMPOSE_CMD[*]} pull ${SERVICES[*]}"

if [[ "$ROLLING" == "true" ]]; then
  # Rolling: recreate changed containers without stopping the whole stack
  UP_FLAGS=(up -d --remove-orphans)
  [[ "$FORCE_RECREATE" == "true" ]] && UP_FLAGS+=(--force-recreate)
  # If your compose supports it, uncomment the next to always pull on up:
  # UP_FLAGS+=(--pull always)
  run "${COMPOSE_CMD[*]} ${UP_FLAGS[*]} ${SERVICES[*]}"
else
  # Downtime path: stop everything, then start
  run "${COMPOSE_CMD[*]} down"
  UP_FLAGS=(up -d --remove-orphans)
  [[ "$FORCE_RECREATE" == "true" ]] && UP_FLAGS+=(--force-recreate)
  run "${COMPOSE_CMD[*]} ${UP_FLAGS[*]}"
fi

# Optional cleanup
if [[ "$PRUNE" == "true" ]]; then
  run "docker image prune -f"
  # Uncomment to be more aggressive:
  # run "docker system prune -af --volumes"
fi

echo "Update complete."
