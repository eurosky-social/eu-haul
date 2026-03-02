#!/bin/bash
# Gracefully restart eurosky-migration services without interrupting active migrations.
#
# This script drains Sidekiq workers (stops fetching new jobs, waits for in-flight
# jobs to finish) before restarting containers. This is especially important for
# eurosky-sidekiq-critical, which runs UpdatePlcJob — a job that modifies the PLC
# directory and must not be interrupted mid-execution.
#
# Usage:
#   ./scripts/safe-restart.sh [OPTIONS] [SERVICES...]
#
# Options:
#   -f FILE    Compose file (default: auto-detect compose.yml.production or docker-compose.yml)
#   -t SECS    Drain timeout in seconds (default: 60)
#   -y         Skip confirmation prompt
#   -h         Show this help
#
# Services (default: all):
#   all        Restart everything (web + both sidekiq workers)
#   web        Restart web only (safe anytime)
#   sidekiq    Restart both sidekiq workers (graceful drain)
#   critical   Restart sidekiq-critical only (graceful drain)
#   workers    Restart sidekiq (main) only (graceful drain)
#
# Examples:
#   ./scripts/safe-restart.sh                    # Restart all services
#   ./scripts/safe-restart.sh web                # Restart web only (instant, safe)
#   ./scripts/safe-restart.sh critical           # Restart critical worker only
#   ./scripts/safe-restart.sh -t 120 sidekiq     # Drain with 2min timeout
#   ./scripts/safe-restart.sh -f docker-compose.yml all  # Use dev compose file

set -euo pipefail

# Defaults
COMPOSE_FILE=""
DRAIN_TIMEOUT=60
SKIP_CONFIRM=false
SERVICES="all"

usage() {
  sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
  exit 0
}

# Parse options
while getopts "f:t:yh" opt; do
  case $opt in
    f) COMPOSE_FILE="$OPTARG" ;;
    t) DRAIN_TIMEOUT="$OPTARG" ;;
    y) SKIP_CONFIRM=true ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

# Remaining args are services
if [ $# -gt 0 ]; then
  SERVICES="$1"
fi

# Auto-detect compose file
if [ -z "$COMPOSE_FILE" ]; then
  if [ -f "compose.yml.production" ] && docker compose -f compose.yml.production ps --quiet 2>/dev/null | head -1 | grep -q .; then
    COMPOSE_FILE="compose.yml.production"
  elif [ -f "docker-compose.yml" ]; then
    COMPOSE_FILE="docker-compose.yml"
  else
    echo "Error: No compose file found. Use -f to specify one."
    exit 1
  fi
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Error: Compose file not found: $COMPOSE_FILE"
  exit 1
fi

DC="docker compose -f $COMPOSE_FILE"

echo "Using compose file: $COMPOSE_FILE"
echo "Drain timeout: ${DRAIN_TIMEOUT}s"
echo "Services: $SERVICES"
echo ""

# --- Helper functions ---

# Check if a service container is running
is_running() {
  $DC ps --status running "$1" 2>/dev/null | grep -q "$1"
}

# Check for active migrations at dangerous stages
check_dangerous_migrations() {
  local web_container
  web_container=$($DC ps --quiet eurosky-web 2>/dev/null | head -1)

  if [ -z "$web_container" ]; then
    echo "Warning: Web container not running, cannot check migration states"
    return
  fi

  local dangerous
  dangerous=$(docker exec "$web_container" rails runner '
    dangerous = Migration.where(status: ["pending_plc", "pending_activation"])
    if dangerous.any?
      dangerous.each do |m|
        puts "  #{m.token} — #{m.status} — #{m.did}"
      end
    end
  ' 2>/dev/null) || true

  if [ -n "$dangerous" ]; then
    echo "WARNING: Migrations at critical stages:"
    echo "$dangerous"
    echo ""
    echo "These migrations are at or near the PLC update (point of no return)."
    echo "The drain process will wait for their jobs to finish, but be aware."
    echo ""
  else
    echo "No migrations at critical stages (pending_plc/pending_activation)."
    echo ""
  fi
}

# Send TSTP to quiet a Sidekiq container, then wait for jobs to drain
graceful_drain() {
  local service="$1"
  local label="$2"

  if ! is_running "$service"; then
    echo "[$label] Not running, skipping drain."
    return
  fi

  echo "[$label] Sending TSTP (quiet) — stopping new job fetches..."
  $DC kill -s TSTP "$service" 2>/dev/null || true

  echo "[$label] Waiting up to ${DRAIN_TIMEOUT}s for in-flight jobs to finish..."

  local elapsed=0
  local interval=3
  while [ $elapsed -lt "$DRAIN_TIMEOUT" ]; do
    # Check if Sidekiq has any busy threads by looking at logs for activity
    # The most reliable method is checking if the container's Sidekiq process
    # reports 0 busy threads. We use the Sidekiq process title for this.
    local busy
    busy=$(docker exec "$($DC ps --quiet "$service" | head -1)" \
      bash -c 'ps aux | grep -o "sidekiq.*\[.*of.*busy\]" | grep -oP "\d+(?= of)" || echo "0"' 2>/dev/null) || busy="0"

    if [ "$busy" = "0" ]; then
      echo "[$label] All jobs finished (0 busy)."
      return
    fi

    echo "[$label] ${busy} job(s) still running... (${elapsed}s / ${DRAIN_TIMEOUT}s)"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "[$label] Drain timeout reached. Proceeding with stop (Sidekiq will push unfinished jobs back to Redis)."
}

# Stop and start a service
restart_service() {
  local service="$1"
  local label="$2"

  echo "[$label] Stopping..."
  $DC stop "$service"

  echo "[$label] Starting..."
  $DC start "$service"

  echo "[$label] Restarted."
}

# --- Main ---

# Determine which services to restart
RESTART_WEB=false
RESTART_WORKERS=false
RESTART_CRITICAL=false

case "$SERVICES" in
  all)
    RESTART_WEB=true
    RESTART_WORKERS=true
    RESTART_CRITICAL=true
    ;;
  web)
    RESTART_WEB=true
    ;;
  sidekiq)
    RESTART_WORKERS=true
    RESTART_CRITICAL=true
    ;;
  critical)
    RESTART_CRITICAL=true
    ;;
  workers)
    RESTART_WORKERS=true
    ;;
  *)
    echo "Error: Unknown service group '$SERVICES'. Use: all, web, sidekiq, critical, workers"
    exit 1
    ;;
esac

# Check for dangerous migrations if we're restarting critical workers
if [ "$RESTART_CRITICAL" = true ]; then
  check_dangerous_migrations
fi

# Confirm
if [ "$SKIP_CONFIRM" = false ]; then
  targets=""
  [ "$RESTART_WEB" = true ] && targets="${targets}web "
  [ "$RESTART_WORKERS" = true ] && targets="${targets}sidekiq(main) "
  [ "$RESTART_CRITICAL" = true ] && targets="${targets}sidekiq(critical) "

  read -rp "Restart ${targets}? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Cancelled."
    exit 0
  fi
  echo ""
fi

# Phase 1: Quiet all Sidekiq processes that will be restarted (in parallel)
if [ "$RESTART_CRITICAL" = true ] || [ "$RESTART_WORKERS" = true ]; then
  echo "=== Phase 1: Quieting Sidekiq workers ==="
  [ "$RESTART_CRITICAL" = true ] && is_running eurosky-sidekiq-critical && \
    $DC kill -s TSTP eurosky-sidekiq-critical 2>/dev/null || true
  [ "$RESTART_WORKERS" = true ] && is_running eurosky-sidekiq && \
    $DC kill -s TSTP eurosky-sidekiq 2>/dev/null || true
  echo ""
fi

# Phase 2: Wait for drains
if [ "$RESTART_CRITICAL" = true ]; then
  echo "=== Phase 2: Draining Sidekiq workers ==="
  graceful_drain eurosky-sidekiq-critical "critical"
  echo ""
fi
if [ "$RESTART_WORKERS" = true ]; then
  [ "$RESTART_CRITICAL" = false ] && echo "=== Phase 2: Draining Sidekiq workers ==="
  graceful_drain eurosky-sidekiq "workers"
  echo ""
fi

# Phase 3: Restart services
echo "=== Phase 3: Restarting services ==="
[ "$RESTART_CRITICAL" = true ] && restart_service eurosky-sidekiq-critical "critical"
[ "$RESTART_WORKERS" = true ] && restart_service eurosky-sidekiq "workers"
[ "$RESTART_WEB" = true ] && restart_service eurosky-web "web"

echo ""
echo "Done. All requested services have been restarted."

# Quick status check
echo ""
echo "=== Current status ==="
$DC ps
