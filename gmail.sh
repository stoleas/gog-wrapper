#!/usr/bin/env bash

# shellcheck source=vars.sh
source "$(dirname "${BASH_SOURCE[0]}")/vars.sh"

DEPENDENCIES=(gog)
SCRIPT_NAME=$(basename "$0")
VERSION="1.0.0"



function usage() {
    cat <<EOM

Gmail wrapper for gog. Account defaults to \$GOG_ACCOUNT.

usage: ${SCRIPT_NAME} <command> [flags]

read commands:
    search <query>                  Search threads (Gmail query syntax)
    messages search <query>         Search individual messages (not threads)
    get <messageId>                 Get a message
    attachment <msgId> <attachId>   Download an attachment
    url <threadId>                  Print Gmail web URL for a thread

organize commands:
    archive [<messageId> ...]       Archive messages (remove from inbox)
    mark-read [<messageId> ...]     Mark messages as read
    unread [<messageId> ...]        Mark messages as unread
    trash [<messageId> ...]         Move messages to trash
    thread <command>                Thread operations (get, modify)
    labels <command>                Label operations
    batch <command>                 Batch operations

write commands:
    send                            Send an email
    drafts <command>                Draft operations (create, send, list)
    autoreply <query>               Reply once to matching messages

global flags:
    -j, --json                      Output JSON (recommended for scripting)
    -p, --plain                     Output TSV (stable, parseable)
        --results-only              Emit only primary result in JSON mode
    -n, --dry-run                   Print intended actions without executing
    -y, --force                     Skip confirmations
        --no-input                  Never prompt; fail instead (for CI)
    -a, --account <email>           Override account

dependencies: ${DEPENDENCIES[*]}

examples:
    ${SCRIPT_NAME} search 'newer_than:7d is:unread' --max 10
    ${SCRIPT_NAME} messages search 'from:github.com' --max 20 --json
    ${SCRIPT_NAME} send --to someone@example.com --subject "Hi" --body "Hello"
    ${SCRIPT_NAME} send --to someone@example.com --subject "Report" --body-file report.txt
    ${SCRIPT_NAME} archive \$(${SCRIPT_NAME} search 'older_than:30d' --json --results-only | jq -r '.[].id')
    ${SCRIPT_NAME} drafts create --to a@b.com --subject "Draft" --body-file draft.txt

EOM
    exit 1
}

function main() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    export GOG_ACCOUNT="${GOG_ACCOUNT:-${DEFAULT_GOG_ACCOUNT}}"
    exit_on_missing_tools "${DEPENDENCIES[@]}"
    exec gog gmail "$@"
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
