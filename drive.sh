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

Google Drive wrapper for gog. Account defaults to \$GOG_ACCOUNT or \$DEFAULT_GOG_ACCOUNT.

usage: ${SCRIPT_NAME} <command> [flags]

browse commands:
    ls                                List files in a folder (default: root)
    search <query>                    Full-text search across Drive
    get <fileId>                      Get file metadata
    url <fileId> ...                  Print web URLs for files
    drives                            List shared drives (Team Drives)
    permissions <fileId>              List permissions on a file
    comments <command>                Manage comments on files

file commands:
    download <fileId>                 Download a file (exports Google Docs formats)
    upload <localPath>                Upload a file
    copy <fileId> <name>              Copy a file
    move <fileId>                     Move a file to a different folder
    rename <fileId> <newName>         Rename a file or folder
    delete <fileId>                   Move a file to trash
    mkdir <name>                      Create a folder

share commands:
    share <fileId>                    Share a file or folder
    unshare <fileId> <permissionId>   Remove a permission from a file

global flags:
    -j, --json                        Output JSON (recommended for scripting)
    -p, --plain                       Output TSV (stable, parseable)
        --results-only                Emit only primary result in JSON mode
    -n, --dry-run                     Print intended actions without executing
    -y, --force                       Skip confirmations
        --no-input                    Never prompt; fail instead (for CI)
    -a, --account <email>             Override account

dependencies: ${DEPENDENCIES[*]}

examples:
    ${SCRIPT_NAME} ls
    ${SCRIPT_NAME} ls --folder <folderId>
    ${SCRIPT_NAME} search "Q1 report" --max 10
    ${SCRIPT_NAME} upload ./report.pdf --name "Q1 Report 2026" --folder <folderId>
    ${SCRIPT_NAME} download <fileId> --out ./local-copy.pdf
    ${SCRIPT_NAME} share <fileId> --email colleague@example.com --role reader
    ${SCRIPT_NAME} mkdir "Project Assets" --folder <parentFolderId>
    ${SCRIPT_NAME} delete <fileId> --force

EOM
    exit 1
}

function main() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    export GOG_ACCOUNT="${GOG_ACCOUNT:-${DEFAULT_GOG_ACCOUNT}}"
    exit_on_missing_tools "${DEPENDENCIES[@]}"
    exec gog drive "$@"
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
