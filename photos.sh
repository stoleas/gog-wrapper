#!/usr/bin/env bash

# shellcheck source=vars.sh
source "$(dirname "${BASH_SOURCE[0]}")/vars.sh"

DEPENDENCIES=(gog curl jq)
SCRIPT_NAME=$(basename "$0")
VERSION="1.0.0"
PHOTOS_API="https://photoslibrary.googleapis.com/v1"
GOG_CREDENTIALS_FILE="${HOME}/.config/gogcli/credentials.json"

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

Google Photos wrapper. Account defaults to \$GOG_ACCOUNT or \$DEFAULT_GOG_ACCOUNT.
Uses gog OAuth tokens + Photos Library REST API.

usage: ${SCRIPT_NAME} <command> [flags]

browse commands:
    list                                  List media items (newest first)
    search <query>                        Search media items by text
    get <mediaItemId>                     Get metadata for a media item
    download <mediaItemId>                Download a media item

album commands:
    albums                                List all albums
    album <albumId>                       List items in an album
    create-album <title>                  Create a new album

upload commands:
    upload <file>                         Upload a photo or video

global flags:
    -j, --json                            Output JSON (recommended for scripting)
    -p, --plain                           Output TSV (stable, parseable)
        --max <n>                         Max results (default: 25)
        --page-token <token>              Resume from a page token
        --out <path>                      Output file for download
    -a, --account <email>                 Override account
        --no-input                        Never prompt; fail instead (for CI)

dependencies: ${DEPENDENCIES[*]}

setup (one-time):
    gog auth add <email> \\
      --extra-scopes "https://www.googleapis.com/auth/photoslibrary.readonly,https://www.googleapis.com/auth/photoslibrary" \\
      --force-consent

examples:
    ${SCRIPT_NAME} list --max 10 --json
    ${SCRIPT_NAME} search "sunset" --max 20 --json
    ${SCRIPT_NAME} get <mediaItemId> --json
    ${SCRIPT_NAME} download <mediaItemId> --out ./photo.jpg
    ${SCRIPT_NAME} albums --json
    ${SCRIPT_NAME} album <albumId> --max 50 --json
    ${SCRIPT_NAME} create-album "Trip 2026"
    ${SCRIPT_NAME} upload ./photo.jpg

EOM
    exit 1
}

function exit_on_missing_tools() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            printf "${RED}Error: Required tool '%s' is not installed or not in PATH${NC}\n" "$cmd" >&2
            exit 1
        fi
    done
}

function get_access_token() {
    local account="$1"
    if [[ ! -f "$GOG_CREDENTIALS_FILE" ]]; then
        printf "${RED}Error: gog credentials not found at %s${NC}\n" "$GOG_CREDENTIALS_FILE" >&2
        exit 1
    fi
    local client_id client_secret refresh_token token_file token_response access_token
    client_id=$(jq -r '.client_id' "$GOG_CREDENTIALS_FILE")
    client_secret=$(jq -r '.client_secret' "$GOG_CREDENTIALS_FILE")

    token_file=$(mktemp --dry-run)
    if ! gog auth tokens export "$account" --out "$token_file" >/dev/null 2>&1; then
        printf "${RED}Error: Failed to export token for %s. Run: gog auth add %s --extra-scopes \"https://www.googleapis.com/auth/photoslibrary.readonly,https://www.googleapis.com/auth/photoslibrary\" --force-consent${NC}\n" "$account" "$account" >&2
        exit 1
    fi
    refresh_token=$(jq -r '.refresh_token' "$token_file")
    local scopes
    scopes=$(jq -r '.scopes[]?' "$token_file" 2>/dev/null)
    rm -f "$token_file"

    if ! grep -q "photoslibrary" <<< "$scopes"; then
        printf "${RED}Error: Photos scopes not authorized. Run:\n  gog auth add %s --extra-scopes \"https://www.googleapis.com/auth/photoslibrary.readonly,https://www.googleapis.com/auth/photoslibrary\" --force-consent${NC}\n" "$account" >&2
        exit 1
    fi

    token_response=$(curl -s -X POST https://oauth2.googleapis.com/token \
        --data-urlencode "client_id=$client_id" \
        --data-urlencode "client_secret=$client_secret" \
        --data-urlencode "refresh_token=$refresh_token" \
        --data-urlencode "grant_type=refresh_token")
    access_token=$(jq -r '.access_token' <<< "$token_response")
    if [[ -z "$access_token" || "$access_token" == "null" ]]; then
        printf "${RED}Error: Failed to get access token: %s${NC}\n" "$(jq -r '.error_description // .error // "unknown"' <<< "$token_response")" >&2
        exit 1
    fi
    printf "%s" "$access_token"
}

function photos_get() {
    local access_token="$1" path="$2" params="$3"
    local url="$PHOTOS_API/$path"
    [[ -n "$params" ]] && url="$url?$params"
    curl -s -H "Authorization: Bearer $access_token" "$url"
}

function photos_post() {
    local access_token="$1" path="$2" body="$3"
    curl -s -X POST \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$PHOTOS_API/$path"
}

function cmd_list() {
    local access_token="$1" max="$2" page_token="$3" json_mode="$4" plain_mode="$5"
    local body
    body=$(jq -n --argjson max "$max" '{"pageSize": $max}')
    [[ -n "$page_token" ]] && body=$(jq --arg t "$page_token" '. + {"pageToken": $t}' <<< "$body")
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$PHOTOS_API/mediaItems:search")
    format_media_list "$response" "$json_mode" "$plain_mode"
}

function cmd_search() {
    local access_token="$1" query="$2" max="$3" page_token="$4" json_mode="$5" plain_mode="$6"
    local body
    body=$(jq -n --arg q "$query" --argjson max "$max" '{"pageSize": $max, "filters": {"contentFilter": {"includedContentCategories": []}, "textFilter": {"searchText": $q}}}')
    [[ -n "$page_token" ]] && body=$(jq --arg t "$page_token" '. + {"pageToken": $t}' <<< "$body")
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$PHOTOS_API/mediaItems:search")
    format_media_list "$response" "$json_mode" "$plain_mode"
}

function cmd_get() {
    local access_token="$1" media_item_id="$2" json_mode="$3" plain_mode="$4"
    local response
    response=$(photos_get "$access_token" "mediaItems/$media_item_id")
    if [[ "$json_mode" == "true" ]]; then
        jq '.' <<< "$response"
    elif [[ "$plain_mode" == "true" ]]; then
        jq -r '[.id, .mediaMetadata.creationTime, .mimeType, .filename] | @tsv' <<< "$response"
    else
        jq -r '"ID:       \(.id)\nFilename: \(.filename)\nMIME:     \(.mimeType)\nCreated:  \(.mediaMetadata.creationTime)\nURL:      \(.productUrl)"' <<< "$response"
    fi
}

function cmd_download() {
    local access_token="$1" media_item_id="$2" out_path="$3"
    local response base_url mime
    response=$(photos_get "$access_token" "mediaItems/$media_item_id")
    base_url=$(jq -r '.baseUrl' <<< "$response")
    mime=$(jq -r '.mimeType' <<< "$response")
    filename=$(jq -r '.filename' <<< "$response")

    if [[ -z "$base_url" || "$base_url" == "null" ]]; then
        printf "${RED}Error: Could not get download URL for media item %s${NC}\n" "$media_item_id" >&2
        exit 1
    fi

    # Append =d to get full download URL
    local download_url="${base_url}=d"
    [[ -z "$out_path" ]] && out_path="./$filename"

    printf "Downloading %s -> %s\n" "$filename" "$out_path" >&2
    curl -s -L -o "$out_path" "$download_url"
    printf "${GREEN}Saved to %s${NC}\n" "$out_path" >&2
}

function cmd_albums() {
    local access_token="$1" max="$2" page_token="$3" json_mode="$4" plain_mode="$5"
    local params="pageSize=$max"
    [[ -n "$page_token" ]] && params="$params&pageToken=$page_token"
    local response
    response=$(photos_get "$access_token" "albums" "$params")
    if [[ "$json_mode" == "true" ]]; then
        jq '.' <<< "$response"
    elif [[ "$plain_mode" == "true" ]]; then
        jq -r '.albums[]? | [.id, .title, (.mediaItemsCount // "0")] | @tsv' <<< "$response"
    else
        local next_token
        next_token=$(jq -r '.nextPageToken // ""' <<< "$response")
        jq -r '.albums[]? | "\(.id)\t\(.title)\t\(.mediaItemsCount // 0) items"' <<< "$response" | column -t -s $'\t'
        [[ -n "$next_token" ]] && printf "\n${YELLOW}Next page token: %s${NC}\n" "$next_token" >&2
    fi
}

function cmd_album() {
    local access_token="$1" album_id="$2" max="$3" page_token="$4" json_mode="$5" plain_mode="$6"
    local body
    body=$(jq -n --arg id "$album_id" --argjson max "$max" '{"albumId": $id, "pageSize": $max}')
    [[ -n "$page_token" ]] && body=$(jq --arg t "$page_token" '. + {"pageToken": $t}' <<< "$body")
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$PHOTOS_API/mediaItems:search")
    format_media_list "$response" "$json_mode" "$plain_mode"
}

function cmd_create_album() {
    local access_token="$1" title="$2" json_mode="$3" plain_mode="$4"
    local body response
    body=$(jq -n --arg title "$title" '{"album": {"title": $title}}')
    response=$(photos_post "$access_token" "albums" "$body")
    if [[ "$json_mode" == "true" ]]; then
        jq '.' <<< "$response"
    elif [[ "$plain_mode" == "true" ]]; then
        jq -r '[.id, .title] | @tsv' <<< "$response"
    else
        jq -r '"Created album: \(.title)\nID: \(.id)\nURL: \(.productUrl)"' <<< "$response"
    fi
}

function cmd_upload() {
    local access_token="$1" file_path="$2" album_id="$3" json_mode="$4"
    if [[ ! -f "$file_path" ]]; then
        printf "${RED}Error: File not found: %s${NC}\n" "$file_path" >&2
        exit 1
    fi
    local filename mime upload_token create_response
    filename=$(basename "$file_path")
    mime=$(file --mime-type -b "$file_path" 2>/dev/null || printf "application/octet-stream")

    printf "Uploading %s...\n" "$filename" >&2
    upload_token=$(curl -s -X POST \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/octet-stream" \
        -H "X-Goog-Upload-Protocol: raw" \
        -H "X-Goog-Upload-File-Name: $filename" \
        --data-binary "@$file_path" \
        "https://photoslibrary.googleapis.com/v1/uploads")

    if [[ -z "$upload_token" ]]; then
        printf "${RED}Error: Upload failed (no upload token returned)${NC}\n" >&2
        exit 1
    fi

    local new_item_body
    new_item_body=$(jq -n --arg token "$upload_token" --arg desc "$filename" '{"newMediaItems": [{"description": $desc, "simpleMediaItem": {"fileName": $desc, "uploadToken": $token}}]}')
    [[ -n "$album_id" ]] && new_item_body=$(jq --arg id "$album_id" '. + {"albumId": $id}' <<< "$new_item_body")

    create_response=$(photos_post "$access_token" "mediaItems:batchCreate" "$new_item_body")

    if [[ "$json_mode" == "true" ]]; then
        jq '.' <<< "$create_response"
    else
        local status media_item_id
        status=$(jq -r '.newMediaItemResults[0].status.message // "unknown"' <<< "$create_response")
        media_item_id=$(jq -r '.newMediaItemResults[0].mediaItem.id // ""' <<< "$create_response")
        if [[ -n "$media_item_id" && "$media_item_id" != "null" ]]; then
            printf "${GREEN}Uploaded: %s (ID: %s)${NC}\n" "$filename" "$media_item_id"
        else
            printf "${RED}Upload failed: %s${NC}\n" "$status" >&2
            jq '.' <<< "$create_response" >&2
            exit 1
        fi
    fi
}

function format_media_list() {
    local response="$1" json_mode="$2" plain_mode="$3"
    if [[ "$json_mode" == "true" ]]; then
        jq '.' <<< "$response"
    elif [[ "$plain_mode" == "true" ]]; then
        jq -r '.mediaItems[]? | [.id, .mediaMetadata.creationTime, .mimeType, .filename] | @tsv' <<< "$response"
    else
        local next_token
        next_token=$(jq -r '.nextPageToken // ""' <<< "$response")
        jq -r '.mediaItems[]? | "\(.id)\t\(.mediaMetadata.creationTime // "?")\t\(.mimeType)\t\(.filename)"' <<< "$response" | column -t -s $'\t'
        [[ -n "$next_token" ]] && printf "\n${YELLOW}Next page token: %s${NC}\n" "$next_token" >&2
    fi
}

function main() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    exit_on_missing_tools "${DEPENDENCIES[@]}"

    local account="${GOG_ACCOUNT:-${DEFAULT_GOG_ACCOUNT}}"
    local json_mode="false" plain_mode="false" max=25 page_token="" out_path="" album_id="" no_input="false"
    local cmd="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -j|--json)       json_mode="true" ;;
            -p|--plain)      plain_mode="true" ;;
            --max)           max="$2"; shift ;;
            --page-token)    page_token="$2"; shift ;;
            --out)           out_path="$2"; shift ;;
            --album)         album_id="$2"; shift ;;
            -a|--account)    account="$2"; shift ;;
            --no-input)      no_input="true" ;;
            *) break ;;
        esac
        shift
    done

    local access_token
    access_token=$(get_access_token "$account") || exit 1

    case "$cmd" in
        list)
            cmd_list "$access_token" "$max" "$page_token" "$json_mode" "$plain_mode"
            ;;
        search)
            local query="${1:-}"
            if [[ -z "$query" ]]; then
                printf "${RED}Error: search requires a query${NC}\n" >&2
                exit 1
            fi
            cmd_search "$access_token" "$query" "$max" "$page_token" "$json_mode" "$plain_mode"
            ;;
        get)
            local media_item_id="${1:-}"
            if [[ -z "$media_item_id" ]]; then
                printf "${RED}Error: get requires a mediaItemId${NC}\n" >&2
                exit 1
            fi
            cmd_get "$access_token" "$media_item_id" "$json_mode" "$plain_mode"
            ;;
        download)
            local media_item_id="${1:-}"
            if [[ -z "$media_item_id" ]]; then
                printf "${RED}Error: download requires a mediaItemId${NC}\n" >&2
                exit 1
            fi
            cmd_download "$access_token" "$media_item_id" "$out_path"
            ;;
        albums)
            cmd_albums "$access_token" "$max" "$page_token" "$json_mode" "$plain_mode"
            ;;
        album)
            local album_id_arg="${1:-}"
            if [[ -z "$album_id_arg" ]]; then
                printf "${RED}Error: album requires an albumId${NC}\n" >&2
                exit 1
            fi
            cmd_album "$access_token" "$album_id_arg" "$max" "$page_token" "$json_mode" "$plain_mode"
            ;;
        create-album)
            local title="${1:-}"
            if [[ -z "$title" ]]; then
                printf "${RED}Error: create-album requires a title${NC}\n" >&2
                exit 1
            fi
            cmd_create_album "$access_token" "$title" "$json_mode" "$plain_mode"
            ;;
        upload)
            local file_path="${1:-}"
            if [[ -z "$file_path" ]]; then
                printf "${RED}Error: upload requires a file path${NC}\n" >&2
                exit 1
            fi
            cmd_upload "$access_token" "$file_path" "$album_id" "$json_mode"
            ;;
        *)
            printf "${RED}Error: Unknown command '%s'${NC}\n" "$cmd" >&2
            usage
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
