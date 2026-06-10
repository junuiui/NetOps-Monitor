#!/bin/bash
# ===========================================================================
# ping_monitor.sh
# 
# Purpose:
#   Periodically pings one or more configured targets, measures
#       1. round-trip latency (min/avg/max) and
#       2. packet loss percentage
#   writes results to a PostgreSQL table for downstream analytics and alerting
#
# Usage:
#   ./ping_monitor.sh [--target <host>] [--count <n>] [--interval <seconds>]
#
#   All flags are optional. Values fall back to environment variables or the hard-coded defaults defined in the CONFIGURATION section below
#
# Environment Variables (override defaults without editing this file):
#   PING_TARGETS    space-separated list of hosts/IPs to ping
#                   Example: "8.8.8.8 123.1.2.122 example.com"
#
#   PING_COUNT      Number of ICMP packets sent per probe cycle. Default: 5
#   PING_INTERVAL   Seconds between probe cycles. Default: 60
#   RUN_MODE        loop | once             Default: loop
#   DB_HOST         Default: localhost
#   DB_PORT         Default: 5432
#   DB_NAME         Default: netops
#   DB_USER         Default: netops_user
#   DB_PASSWORD     No Default, Must be set
#   LOG_DIR         Directory for log files Default: /var/log/netops
#   LOG_LEVEL       INFO | WARN | ERROR     Default: INFO
#   
# Exit Codes:
#   0   Normal exit (SIGTERM / SIGINT)
#   1   Missing required dependency
#   2   Invalid Arguments
#   3   Database Connection failure on startup
#
# ===========================================================================

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
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

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
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

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
    log "INFO" "TEST MESSAGE"
}

main "$@"