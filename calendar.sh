#!/usr/bin/env bash

# shellcheck source=vars.sh
source "$(dirname "${BASH_SOURCE[0]}")/vars.sh"

DEPENDENCIES=(gog)
SCRIPT_NAME=$(basename "$0")
VERSION="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    RED="" GREEN="" YELLOW="" BLUE="" NC=""
fi

function usage() {
    cat <<EOM

Google Calendar wrapper for gog. Account defaults to \$GOG_ACCOUNT or \$DEFAULT_GOG_ACCOUNT.

usage: ${SCRIPT_NAME} <command> [flags]

commands:
    calendars                             List all calendars
    events [<calendarId>]                 List events (default: primary)
    event <calendarId> <eventId>          Get a single event
    create <calendarId>                   Create an event
    update <calendarId> <eventId>         Update an event
    delete <calendarId> <eventId>         Delete an event
    search <query>                        Search events
    freebusy [<calendarIds>]              Get free/busy info
    colors                                Show available event color IDs
    conflicts                             Find scheduling conflicts
    respond <calendarId> <eventId>        RSVP to an event invitation
    focus-time                            Create a Focus Time block
    out-of-office                         Create an Out of Office event
    working-location                      Set working location (home/office/custom)
    users                                 List workspace users
    team <group-email>                    Show events for a Google Group

global flags:
    -j, --json                            Output JSON (recommended for scripting)
    -p, --plain                           Output TSV (stable, parseable)
        --results-only                    Emit only primary result in JSON mode
    -n, --dry-run                         Print intended actions without executing
    -y, --force                           Skip confirmations
        --no-input                        Never prompt; fail instead (for CI)
    -a, --account <email>                 Override account

dependencies: ${DEPENDENCIES[*]}

examples:
    ${SCRIPT_NAME} calendars
    ${SCRIPT_NAME} events primary --from 2026-04-23T00:00:00Z --to 2026-04-30T00:00:00Z
    ${SCRIPT_NAME} create primary --summary "Team standup" --from 2026-04-24T09:00:00Z --to 2026-04-24T09:30:00Z
    ${SCRIPT_NAME} search "standup" --max 10 --json
    ${SCRIPT_NAME} colors
    ${SCRIPT_NAME} freebusy --from 2026-04-24T00:00:00Z --to 2026-04-25T00:00:00Z

EOM
    exit 1
}

function main() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    export GOG_ACCOUNT="${GOG_ACCOUNT:-${DEFAULT_GOG_ACCOUNT}}"
    exit_on_missing_tools "${DEPENDENCIES[@]}"
    exec gog calendar "$@"
}

function exit_on_missing_tools() {
    for cmd in "$@"; do
        if command -v "$cmd" &>/dev/null; then
            continue
        fi
        printf "${RED}Error: Required tool '%s' is not installed or not in PATH${NC}\n" "$cmd" >&2
        exit 1
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
