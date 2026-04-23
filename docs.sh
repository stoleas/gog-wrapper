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

Google Docs wrapper for gog. Account defaults to \$GOG_ACCOUNT or \$DEFAULT_GOG_ACCOUNT.

usage: ${SCRIPT_NAME} <command> [flags]

read commands:
    cat <docId>                         Print document as plain text
    info <docId>                        Get document metadata
    structure <docId>                   Show document structure with numbered paragraphs
    list-tabs <docId>                   List all tabs in a document
    comments <command>                  Manage comments on a document

write commands:
    create <title>                      Create a new Google Doc
    copy <docId> <title>                Copy/duplicate a document
    write <docId>                       Write content to a document
    insert <docId> [<content>]          Insert text at a specific position
    update <docId>                      Insert text at a specific index
    edit <docId> <find> <replace>       Find and replace text
    find-replace <docId> <find> [<replace>]  Find and replace (supports markdown)
    sed <docId> [<expression>]          Regex find/replace (sed-style: s/pattern/replacement/g)
    delete <docId>                      Delete a text range (requires --start and --end)
    clear <docId>                       Clear all content from a document

export commands:
    export <docId>                      Export as pdf|docx|txt|md

global flags:
    -j, --json                          Output JSON (recommended for scripting)
    -p, --plain                         Output TSV (stable, parseable)
        --results-only                  Emit only primary result in JSON mode
    -n, --dry-run                       Print intended actions without executing
    -y, --force                         Skip confirmations
        --no-input                      Never prompt; fail instead (for CI)
    -a, --account <email>               Override account

dependencies: ${DEPENDENCIES[*]}

examples:
    ${SCRIPT_NAME} cat <docId>
    ${SCRIPT_NAME} create "Meeting Notes April 2026"
    ${SCRIPT_NAME} export <docId> --format txt --out ./doc.txt
    ${SCRIPT_NAME} export <docId> --format md --out ./doc.md
    ${SCRIPT_NAME} write <docId> --body "New content here"
    ${SCRIPT_NAME} find-replace <docId> "old text" "new text"
    ${SCRIPT_NAME} sed <docId> 's/foo/bar/g'
    ${SCRIPT_NAME} copy <docId> "Copy of My Doc"
    ${SCRIPT_NAME} structure <docId>

EOM
    exit 1
}

function main() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    export GOG_ACCOUNT="${GOG_ACCOUNT:-${DEFAULT_GOG_ACCOUNT}}"
    exit_on_missing_tools "${DEPENDENCIES[@]}"
    exec gog docs "$@"
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
