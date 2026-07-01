#!/usr/bin/env bash
# =============================================================================
# ping_monitor.sh
#
# Purpose:
#   Periodically pings one or more configured targets, measures round-trip
#   latency (min/avg/max) and packet loss percentage, then writes the results
#   to a PostgreSQL table for downstream analytics and alerting.
#
# Usage:
#   ./ping_monitor.sh [--target <host>] [--count <n>] [--interval <seconds>]
#
#   All flags are optional; values fall back to environment variables or the
#   hard-coded defaults defined in the CONFIGURATION section below.
#
# Environment Variables (override defaults without editing this file):
#   PING_TARGETS      Space-separated list of hosts/IPs to ping.
#                     Example: "8.8.8.8 1.1.1.1 example.com"
#   PING_COUNT        Number of ICMP packets sent per probe cycle. Default: 5
#   PING_INTERVAL     Seconds between probe cycles. Default: 60
#   DB_HOST           PostgreSQL host.           Default: localhost
#   DB_PORT           PostgreSQL port.           Default: 5432
#   DB_NAME           PostgreSQL database name.  Default: netops
#   DB_USER           PostgreSQL user.           Default: netops_user
#   DB_PASSWORD       PostgreSQL password.       (no default; must be set)
#   LOG_DIR           Directory for log files.   Default: /var/log/netops
#   LOG_LEVEL         INFO | WARN | ERROR        Default: INFO
#
# Dependencies:
#   ping, awk, psql (postgresql-client)
#
# Exit Codes:
#   0  Normal exit (SIGTERM / SIGINT received)
#   1  Missing required dependency
#   2  Invalid argument
#   3  Database connection failure on startup
#
# Cron Example (run every minute, managed externally):
#   * * * * * /opt/netops/scripts/ping_monitor.sh >> /var/log/netops/ping.log 2>&1
#
# Notes:
#   - Designed to run as a long-lived process (infinite loop) or as a
#     one-shot cron job depending on RUN_MODE (see CONFIGURATION).
#   - SIGTERM and SIGINT are trapped for graceful shutdown.
#   - All database writes use a single INSERT per probe cycle to minimise
#     connection overhead.
# =============================================================================

# Immediate fail
# -e                if any command fails, then exit all script
# -u                if non-defined variable, exit
# -o pipefail       if any error during pipelining, exit all pipelines
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION — defaults (overridden by env vars or CLI flags)
# ---------------------------------------------------------------------------
PING_TARGETS="${PING_TARGETS:-"8.8.8.8 1.1.1.1"}"
PING_COUNT="${PING_COUNT:-5}"
PING_INTERVAL="${PING_INTERVAL:-60}"       # seconds between cycles
RUN_MODE="${RUN_MODE:-loop}"               # "loop" | "once"

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-netops}"
DB_USER="${DB_USER:-netops_user}"
DB_PASSWORD="${DB_PASSWORD:-}"

LOG_DIR="${LOG_DIR:-/var/log/netops}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
# log <level> <message>
#   Writes a timestamped log line to stdout; respects LOG_LEVEL hierarchy.
log() {
    local level="$1"
    local message="$2"
    local levels=("DEBUG" "INFO" "WARN" "ERROR")
    local current_idx=1   # default: INFO

    # Resolve numeric index for the configured log level
    for i in "${!levels[@]}"; do
        [[ "${levels[$i]}" == "$LOG_LEVEL" ]] && current_idx=$i
    done
    for i in "${!levels[@]}"; do
        if [[ "${levels[$i]}" == "$level" && $i -ge $current_idx ]]; then
            printf "[%s] [%s] [%s] %s\n" \
                "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$SCRIPT_NAME" "$message"
            return
        fi
    done
}

# ---------------------------------------------------------------------------
# DEPENDENCY CHECK
# ---------------------------------------------------------------------------
check_dependencies() {
    local deps=("ping" "awk" "psql")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log "ERROR" "Required dependency not found: ${dep}"
            exit 1
        fi
    done
    log "INFO" "Dependency check passed."
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                PING_TARGETS="$2"; shift 2 ;;
            --count)
                PING_COUNT="$2"; shift 2 ;;
            --interval)
                PING_INTERVAL="$2"; shift 2 ;;
            --run-once)
                RUN_MODE="once"; shift ;;
            *)
                log "ERROR" "Unknown argument: $1"
                exit 2 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# DATABASE HELPERS
# ---------------------------------------------------------------------------

# db_exec <sql>
#   Executes a SQL statement against the configured PostgreSQL instance.
#   Credentials are passed via PGPASSWORD to avoid interactive prompts.
db_exec() {
    local sql="$1"
    PGPASSWORD="$DB_PASSWORD" psql \
        --host="$DB_HOST" \
        --port="$DB_PORT" \
        --dbname="$DB_NAME" \
        --username="$DB_USER" \
        --no-password \
        --tuples-only \
        --command="$sql" 2>&1
}

# verify_db_connection
#   Runs a lightweight query to confirm connectivity before the main loop.
verify_db_connection() {
    log "INFO" "Verifying database connection (${DB_HOST}:${DB_PORT}/${DB_NAME})..."
    if ! db_exec "SELECT 1;" &>/dev/null; then
        log "ERROR" "Cannot connect to PostgreSQL. Check DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD."
        exit 3
    fi
    log "INFO" "Database connection OK."
}

# insert_ping_result <target> <timestamp> <latency_min> <latency_avg> <latency_max> <packet_loss_pct> <probe_count> <status>
#   Inserts one row into the ping_results table.
insert_ping_result() {
    local target="$1"
    local ts="$2"
    local lat_min="$3"
    local lat_avg="$4"
    local lat_max="$5"
    local loss="$6"
    local count="$7"
    local status="$8"

    local sql="
        INSERT INTO ping_results
            (target, probed_at, latency_min_ms, latency_avg_ms, latency_max_ms,
             packet_loss_pct, probe_count, status)
        VALUES
            ('${target}', '${ts}', ${lat_min}, ${lat_avg}, ${lat_max},
             ${loss}, ${count}, '${status}');
    "
    if ! db_exec "$sql" &>/dev/null; then
        log "WARN" "Failed to insert ping result for target=${target}. Row dropped."
    fi
}

# ---------------------------------------------------------------------------
# CORE PROBE LOGIC
# ---------------------------------------------------------------------------

# probe_target <host>
#   Sends PING_COUNT ICMP packets to <host>, parses the ping summary line,
#   and returns: latency_min latency_avg latency_max packet_loss_pct status
#
#   Parsed from ping output lines such as:
#     "5 packets transmitted, 5 received, 0% packet loss"
#     "round-trip min/avg/max/stddev = 12.345/14.567/16.789/1.234 ms"  (macOS/BSD)
#     "rtt min/avg/max/mdev = 12.345/14.567/16.789/1.234 ms"           (Linux)
probe_target() {
    local host="$1"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    log "INFO" "Probing target: ${host} (count=${PING_COUNT})"

    # Run ping; capture stdout+stderr; do not abort script on ping failure
    local raw_output
    raw_output="$(ping -c "$PING_COUNT" -W 2 "$host" 2>&1)" || true

    # --- Parse packet loss ---
    local loss
    loss="$(echo "$raw_output" \
        | awk '/packet loss/ { match($0, /([0-9]+(\.[0-9]+)?)% packet loss/, arr); print arr[1] }')"
    loss="${loss:-100}"   # default to 100% if pattern not found (host unreachable)

    # --- Parse RTT statistics ---
    # Handles both Linux ("rtt min/avg/max/mdev") and BSD/macOS ("round-trip min/avg/max/stddev")
    local rtt_line
    rtt_line="$(echo "$raw_output" | grep -E 'rtt|round-trip' || true)"

    local lat_min lat_avg lat_max
    if [[ -n "$rtt_line" ]]; then
        lat_min="$(echo "$rtt_line" | awk -F'[=/]' '{print $5}')"
        lat_avg="$(echo "$rtt_line" | awk -F'[=/]' '{print $6}')"
        lat_max="$(echo "$rtt_line" | awk -F'[=/]' '{print $7}')"
    else
        # All packets lost — no RTT line will appear
        lat_min="0"
        lat_avg="0"
        lat_max="0"
    fi

    # Sanitise: ensure values are numeric; fall back to 0 if empty/malformed
    lat_min="${lat_min//[^0-9.]/}"
    lat_avg="${lat_avg//[^0-9.]/}"
    lat_max="${lat_max//[^0-9.]/}"
    lat_min="${lat_min:-0}"
    lat_avg="${lat_avg:-0}"
    lat_max="${lat_max:-0}"

    # --- Determine probe status ---
    local status
    if [[ "$loss" == "100" ]]; then
        status="unreachable"
    elif (( $(echo "$loss > 0" | awk '{print ($1 > 0)}') )); then
        status="degraded"
    else
        status="ok"
    fi

    log "INFO" "  Result: host=${host} loss=${loss}% rtt=${lat_min}/${lat_avg}/${lat_max}ms status=${status}"

    insert_ping_result \
        "$host" "$timestamp" \
        "$lat_min" "$lat_avg" "$lat_max" \
        "$loss" "$PING_COUNT" "$status"
}

# run_probe_cycle
#   Iterates over all configured targets and probes each one.
run_probe_cycle() {
    log "INFO" "Starting probe cycle. Targets: [${PING_TARGETS}]"
    for target in $PING_TARGETS; do
        probe_target "$target"
    done
    log "INFO" "Probe cycle complete."
}

# ---------------------------------------------------------------------------
# SIGNAL HANDLING
# ---------------------------------------------------------------------------
SHUTDOWN=false

handle_shutdown() {
    log "INFO" "Shutdown signal received. Exiting gracefully..."
    SHUTDOWN=true
}

trap 'handle_shutdown' SIGTERM SIGINT

# ---------------------------------------------------------------------------
# ENTRYPOINT
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_dependencies
    verify_db_connection

    if [[ "$RUN_MODE" == "once" ]]; then
        run_probe_cycle
        exit 0
    fi

    # Long-lived loop mode: probe every PING_INTERVAL seconds until shutdown
    log "INFO" "Entering loop mode. Probe interval: ${PING_INTERVAL}s"
    while [[ "$SHUTDOWN" == false ]]; do
        run_probe_cycle
        # Sleep in short increments so SIGTERM is handled promptly
        local elapsed=0
        while [[ $elapsed -lt $PING_INTERVAL && "$SHUTDOWN" == false ]]; do
            sleep 1
            (( elapsed++ )) || true
        done
    done

    log "INFO" "${SCRIPT_NAME} stopped."
    exit 0
}

main "$@"