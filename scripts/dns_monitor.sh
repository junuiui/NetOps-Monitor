#!/usr/bin/env bash
# =============================================================================
# dns_monitor.sh
#
# Purpose:
#   Periodically runs DNS lookups against configured targets using `dig`,
#   measures resolution time, detects lookup failures, and writes results to
#   a PostgreSQL table for analytics and alerting.
#
# Usage:
#   ./dns_monitor.sh [--target <domain>] [--resolver <ip>] [--interval <seconds>]
#
# Environment Variables:
#   DNS_TARGETS       Space-separated list of domains to resolve.
#                     Example: "example.com google.com github.com"
#   DNS_RESOLVER      Upstream resolver to query (passed to dig as @<resolver>).
#                     Leave empty to use the system default resolver.
#                     Example: "8.8.8.8"
#   DNS_RECORD_TYPE   DNS record type to query. Default: A
#                     Supported: A AAAA MX CNAME TXT NS
#   DNS_TIMEOUT_SEC   Per-query timeout in seconds. Default: 5
#   DNS_INTERVAL      Seconds between probe cycles. Default: 60
#   RUN_MODE          "loop" | "once". Default: loop
#   DB_HOST           PostgreSQL host.           Default: localhost
#   DB_PORT           PostgreSQL port.           Default: 5432
#   DB_NAME           PostgreSQL database name.  Default: netops
#   DB_USER           PostgreSQL user.           Default: netops_user
#   DB_PASSWORD       PostgreSQL password.       (no default; must be set)
#   LOG_DIR           Directory for log files.   Default: /var/log/netops
#   LOG_LEVEL         INFO | WARN | ERROR        Default: INFO
#
# Dependencies:
#   dig (dnsutils / bind-utils), awk, psql (postgresql-client)
#
# Exit Codes:
#   0  Normal exit (SIGTERM / SIGINT received)
#   1  Missing required dependency
#   2  Invalid argument
#   3  Database connection failure on startup
#
# Cron Example:
#   * * * * * /opt/netops/scripts/dns_monitor.sh >> /var/log/netops/dns.log 2>&1
#
# Output Schema (dns_results table):
#   target          TEXT        — queried domain name
#   record_type     TEXT        — DNS record type (A, AAAA, MX, ...)
#   resolver        TEXT        — resolver IP used (or "system_default")
#   probed_at       TIMESTAMPTZ — UTC timestamp of the query
#   resolution_ms   NUMERIC     — total query time in milliseconds
#   resolved_ips    TEXT        — comma-separated answer records (or empty)
#   status          TEXT        — "ok" | "nxdomain" | "timeout" | "servfail" | "error"
#   raw_status_code TEXT        — RCODE string from dig (NOERROR, NXDOMAIN, ...)
# =============================================================================

# Immediate fail
# -e                if any command fails, then exit all script
# -u                if non-defined variable, exit
# -o pipefail       if any error during pipelining, exit all pipelines
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION — defaults (overridden by env vars or CLI flags)
# ---------------------------------------------------------------------------
DNS_TARGETS="${DNS_TARGETS:-"google.com cloudflare.com"}"
DNS_RESOLVER="${DNS_RESOLVER:-}"            # empty = system default
DNS_RECORD_TYPE="${DNS_RECORD_TYPE:-A}"
DNS_TIMEOUT_SEC="${DNS_TIMEOUT_SEC:-5}"
DNS_INTERVAL="${DNS_INTERVAL:-60}"
RUN_MODE="${RUN_MODE:-loop}"

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
log() {
    local level="$1"
    local message="$2"
    local levels=("DEBUG" "INFO" "WARN" "ERROR")
    local current_idx=1

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
    local deps=("dig" "awk" "psql")
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
                DNS_TARGETS="$2"; shift 2 ;;
            --resolver)
                DNS_RESOLVER="$2"; shift 2 ;;
            --record-type)
                DNS_RECORD_TYPE="$2"; shift 2 ;;
            --interval)
                DNS_INTERVAL="$2"; shift 2 ;;
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

verify_db_connection() {
    log "INFO" "Verifying database connection (${DB_HOST}:${DB_PORT}/${DB_NAME})..."
    if ! db_exec "SELECT 1;" &>/dev/null; then
        log "ERROR" "Cannot connect to PostgreSQL. Check connection variables."
        exit 3
    fi
    log "INFO" "Database connection OK."
}

# insert_dns_result <target> <record_type> <resolver_label> <ts> <resolution_ms> <resolved_ips> <status> <rcode>
insert_dns_result() {
    local target="$1"
    local record_type="$2"
    local resolver_label="$3"
    local ts="$4"
    local resolution_ms="$5"
    local resolved_ips="$6"
    local status="$7"
    local rcode="$8"

    # Escape single quotes in resolved_ips to prevent SQL injection
    resolved_ips="${resolved_ips//\'/\'\'}"

    local sql="
        INSERT INTO dns_results
            (target, record_type, resolver, probed_at, resolution_ms,
             resolved_ips, status, raw_status_code)
        VALUES
            ('${target}', '${record_type}', '${resolver_label}', '${ts}',
             ${resolution_ms}, '${resolved_ips}', '${status}', '${rcode}');
    "
    if ! db_exec "$sql" &>/dev/null; then
        log "WARN" "Failed to insert DNS result for target=${target}. Row dropped."
    fi
}

# ---------------------------------------------------------------------------
# CORE PROBE LOGIC
# ---------------------------------------------------------------------------

# probe_dns <domain>
#   Issues a `dig` query for the configured record type, parses:
#     - Query time (msec) from the STATISTICS section
#     - RCODE (NOERROR / NXDOMAIN / SERVFAIL / ...)
#     - Answer records (A/AAAA/CNAME/MX answer section)
#   Maps RCODE to a human-readable status and inserts into PostgreSQL.
probe_dns() {
    local domain="$1"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Build resolver argument: "@8.8.8.8" if set, empty string if using system default
    local resolver_arg=""
    local resolver_label="system_default"
    if [[ -n "$DNS_RESOLVER" ]]; then
        resolver_arg="@${DNS_RESOLVER}"
        resolver_label="$DNS_RESOLVER"
    fi

    log "INFO" "Probing DNS: domain=${domain} type=${DNS_RECORD_TYPE} resolver=${resolver_label}"

    # Run dig with +stats for timing and +time for timeout control.
    # +noall +answer limits output to the answer section only (plus stats via +stats).
    # We use +stats separately so we can parse ;; Query time and ;; SERVER.
    local raw_output
    raw_output="$(
        dig ${resolver_arg} \
            "${domain}" \
            "${DNS_RECORD_TYPE}" \
            +noall +answer +stats \
            +time="${DNS_TIMEOUT_SEC}" \
            +tries=1 \
            2>&1
    )" || true

    # Also run a separate dig with +noall +comments to capture RCODE
    local rcode_output
    rcode_output="$(
        dig ${resolver_arg} \
            "${domain}" \
            "${DNS_RECORD_TYPE}" \
            +noall +comments \
            +time="${DNS_TIMEOUT_SEC}" \
            +tries=1 \
            2>&1
    )" || true

    # --- Parse RCODE ---
    # dig COMMENTS section contains:  ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: ..."
    local rcode
    rcode="$(echo "$rcode_output" \
        | awk '/status:/ { match($0, /status: ([A-Z]+)/, arr); print arr[1] }')"
    rcode="${rcode:-UNKNOWN}"

    # --- Parse query time (milliseconds) ---
    # dig STATS section contains:  ";; Query time: 12 msec"
    local resolution_ms
    resolution_ms="$(echo "$raw_output" \
        | awk '/Query time:/ { print $4 }')"
    resolution_ms="${resolution_ms//[^0-9]/}"
    resolution_ms="${resolution_ms:-0}"

    # Handle timeout: dig returns status TIMEOUT or produces no query time
    if echo "$raw_output" | grep -qi "connection timed out\|TIMEOUT"; then
        rcode="TIMEOUT"
        resolution_ms="$((DNS_TIMEOUT_SEC * 1000))"
    fi

    # --- Parse answer records ---
    # For an A record query the answer section looks like:
    #   google.com.   299  IN  A  142.250.80.14
    # We extract the last field (the answer value) for each answer line.
    local resolved_ips
    resolved_ips="$(echo "$raw_output" \
        | awk '/^[^;]/ && NF >= 5 { print $NF }' \
        | paste -sd ',' -)"
    resolved_ips="${resolved_ips:-}"

    # --- Map RCODE to internal status ---
    local status
    case "$rcode" in
        NOERROR)
            if [[ -z "$resolved_ips" ]]; then
                # NOERROR with empty answer section = NODATA (e.g. no A record but domain exists)
                status="nodata"
            else
                status="ok"
            fi
            ;;
        NXDOMAIN)  status="nxdomain" ;;
        SERVFAIL)  status="servfail" ;;
        TIMEOUT)   status="timeout"  ;;
        REFUSED)   status="refused"  ;;
        *)         status="error"    ;;
    esac

    log "INFO" "  Result: domain=${domain} rcode=${rcode} status=${status} resolution=${resolution_ms}ms answers=[${resolved_ips}]"

    insert_dns_result \
        "$domain" "$DNS_RECORD_TYPE" "$resolver_label" "$timestamp" \
        "$resolution_ms" "$resolved_ips" "$status" "$rcode"
}

# run_probe_cycle
#   Iterates over all configured DNS targets.
run_probe_cycle() {
    log "INFO" "Starting DNS probe cycle. Targets: [${DNS_TARGETS}]"
    for target in $DNS_TARGETS; do
        probe_dns "$target"
    done
    log "INFO" "DNS probe cycle complete."
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

    log "INFO" "Entering loop mode. Probe interval: ${DNS_INTERVAL}s"
    while [[ "$SHUTDOWN" == false ]]; do
        run_probe_cycle
        local elapsed=0
        while [[ $elapsed -lt $DNS_INTERVAL && "$SHUTDOWN" == false ]]; do
            sleep 1
            (( elapsed++ )) || true
        done
    done

    log "INFO" "${SCRIPT_NAME} stopped."
    exit 0
}

main "$@"