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

Google Sheets wrapper for gog. Account defaults to \$GOG_ACCOUNT or \$DEFAULT_GOG_ACCOUNT.

usage: ${SCRIPT_NAME} <command> [flags]

read commands:
    get <spreadsheetId> <range>           Read values from a range
    metadata <spreadsheetId>              Get spreadsheet metadata (tabs, size, etc.)
    notes <spreadsheetId> <range>         Get cell notes from a range
    links <spreadsheetId> <range>         Get cell hyperlinks from a range
    read-format <spreadsheetId> <range>   Read cell formatting from a range
    named-ranges <command>                Manage named ranges

write commands:
    update <spreadsheetId> <range>        Update values in a range
    append <spreadsheetId> <range>        Append values to a range
    clear <spreadsheetId> <range>         Clear values in a range
    find-replace <spreadsheetId> <find> <replace>  Find and replace text
    update-note <spreadsheetId> <range>   Set or clear a cell note

structure commands:
    create <title>                        Create a new spreadsheet
    copy <spreadsheetId> <title>          Copy/duplicate a spreadsheet
    add-tab <spreadsheetId> <tabName>     Add a new tab
    rename-tab <spreadsheetId> <old> <new>  Rename a tab
    delete-tab <spreadsheetId> <tabName>  Delete a tab
    insert <spreadsheetId> <sheet> <dimension> <start>  Insert rows/columns
    freeze <spreadsheetId>                Freeze rows/columns
    resize-columns <spreadsheetId> <cols> Resize columns
    resize-rows <spreadsheetId> <rows>    Resize rows

format commands:
    format <spreadsheetId> <range>        Apply cell formatting
    merge <spreadsheetId> <range>         Merge cells
    unmerge <spreadsheetId> <range>       Unmerge cells
    number-format <spreadsheetId> <range> Apply number format

export commands:
    export <spreadsheetId>                Export as pdf|xlsx|csv

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
    ${SCRIPT_NAME} get 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms "Sheet1!A1:D10"
    ${SCRIPT_NAME} update 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms "Sheet1!A1:B2" --values-json '[["Name","Score"],["Alice","95"]]' --input USER_ENTERED
    ${SCRIPT_NAME} append 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms "Sheet1!A:C" --values-json '[["2026-04-23","item","10"]]' --insert INSERT_ROWS
    ${SCRIPT_NAME} clear 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms "Sheet1!A2:Z"
    ${SCRIPT_NAME} metadata 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms --json
    ${SCRIPT_NAME} export 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms --format xlsx

EOM
    exit 1
}

function main() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    export GOG_ACCOUNT="${GOG_ACCOUNT:-${DEFAULT_GOG_ACCOUNT}}"
    exit_on_missing_tools "${DEPENDENCIES[@]}"
    exec gog sheets "$@"
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
