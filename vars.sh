#!/usr/bin/env bash
# Default configuration for gog wrapper scripts. Source this file to apply defaults.
# Put your personal settings (email, keyring password) in vars.local.sh — it is gitignored.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$DIR/vars.local.sh" ]]; then
    # shellcheck source=vars.local.sh
    source "$DIR/vars.local.sh"
fi

if [[ -z "${DEFAULT_GOG_ACCOUNT:-}" ]]; then
    printf '\033[0;31m[error]\033[0m DEFAULT_GOG_ACCOUNT is not set.\n' >&2
    printf '  Create %s/vars.local.sh and add:\n' "$DIR" >&2
    printf '    DEFAULT_GOG_ACCOUNT="you@gmail.com"\n' >&2
    exit 1
fi

export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
fi
