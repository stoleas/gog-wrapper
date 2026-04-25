#!/usr/bin/env bash
# Bulk-upload a local folder of photos/videos to a Google Drive folder.
# Designed for use after manually downloading a Google Photos shared album.

# shellcheck source=vars.sh
source "$(dirname "${BASH_SOURCE[0]}")/vars.sh"

DEPENDENCIES=(gog)
SCRIPT_NAME=$(basename "$0")
VERSION="1.0.0"



PHOTO_EXTENSIONS="jpg jpeg png gif webp heic heif tiff bmp mp4 mov avi mkv m4v 3gp"

function usage() {
    cat <<EOM

Upload a local folder of photos/videos to Google Drive.

usage: ${SCRIPT_NAME} <source-folder> [flags]

arguments:
    <source-folder>               Local folder containing photos/videos to upload

flags:
        --folder <driveId>        Drive folder ID to upload into (default: Drive root)
        --album-name <name>       Create a new Drive folder with this name and upload into it
    -n, --dry-run                 Print what would be uploaded without doing it
    -y, --force                   Skip confirmations
        --no-input                Never prompt; fail instead (for CI)
    -a, --account <email>         Override account

dependencies: ${DEPENDENCIES[*]}

workflow:
    1. In Google Photos, open the shared album
    2. Select all photos (click first, Shift+click last)
    3. Three-dot menu -> Download (saves a .zip)
    4. Unzip: unzip ~/Downloads/Photos*.zip -d ~/Downloads/album
    5. Run: ${SCRIPT_NAME} ~/Downloads/album --album-name "Shared Album Name"

examples:
    ${SCRIPT_NAME} ~/Downloads/album --album-name "Beach Trip 2026"
    ${SCRIPT_NAME} ~/Downloads/album --folder 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74
    ${SCRIPT_NAME} ~/Downloads/album --album-name "Beach Trip" --dry-run

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

function is_media_file() {
    local file="$1"
    local ext="${file##*.}"
    ext="${ext,,}"
    for e in $PHOTO_EXTENSIONS; do
        [[ "$ext" == "$e" ]] && return 0
    done
    return 1
}

function main() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    export GOG_ACCOUNT="${GOG_ACCOUNT:-${DEFAULT_GOG_ACCOUNT}}"
    exit_on_missing_tools "${DEPENDENCIES[@]}"

    local source_folder="$1"
    shift

    local folder_id="" album_name="" dry_run="false" force="false" no_input="false" account=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --folder)      folder_id="$2"; shift ;;
            --album-name)  album_name="$2"; shift ;;
            -n|--dry-run)  dry_run="true" ;;
            -y|--force)    force="true" ;;
            --no-input)    no_input="true" ;;
            -a|--account)  account="$2"; shift ;;
            *) printf "${RED}Error: Unknown flag '%s'${NC}\n" "$1" >&2; usage ;;
        esac
        shift
    done

    [[ -n "$account" ]] && export GOG_ACCOUNT="$account"

    if [[ ! -d "$source_folder" ]]; then
        printf "${RED}Error: Source folder not found: %s${NC}\n" "$source_folder" >&2
        exit 1
    fi

    if [[ -n "$album_name" && -n "$folder_id" ]]; then
        printf "${RED}Error: Use either --album-name or --folder, not both${NC}\n" >&2
        exit 1
    fi

    # Collect media files
    local files=()
    while IFS= read -r -d '' f; do
        is_media_file "$f" && files+=("$f")
    done < <(find "$source_folder" -maxdepth 1 -type f -print0 | sort -z)

    if [[ ${#files[@]} -eq 0 ]]; then
        printf "${YELLOW}No media files found in %s${NC}\n" "$source_folder" >&2
        printf "Supported: %s\n" "$PHOTO_EXTENSIONS" >&2
        exit 1
    fi

    printf "Found %d media file(s) in %s\n" "${#files[@]}" "$source_folder"

    # Create Drive folder if --album-name given
    if [[ -n "$album_name" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            printf "${BLUE}[dry-run] Would create Drive folder: %s${NC}\n" "$album_name"
        else
            printf "Creating Drive folder '%s'...\n" "$album_name"
            local mkdir_result
            mkdir_result=$(gog drive mkdir "$album_name" --json --results-only 2>&1)
            folder_id=$(printf "%s" "$mkdir_result" | jq -r '.id // empty' 2>/dev/null)
            if [[ -z "$folder_id" ]]; then
                printf "${RED}Error: Failed to create Drive folder:\n%s${NC}\n" "$mkdir_result" >&2
                exit 1
            fi
            printf "${GREEN}Created folder '%s' (ID: %s)${NC}\n" "$album_name" "$folder_id"
        fi
    fi

    # Confirm before uploading
    if [[ "$dry_run" == "false" && "$force" == "false" && "$no_input" == "false" ]]; then
        local dest_label="${folder_id:-Drive root}"
        printf "\nUpload %d file(s) to %s? [y/N] " "${#files[@]}" "$dest_label"
        read -r confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { printf "Aborted.\n"; exit 0; }
    fi

    # Upload
    local success=0 failed=0
    for f in "${files[@]}"; do
        local name
        name=$(basename "$f")
        if [[ "$dry_run" == "true" ]]; then
            printf "${BLUE}[dry-run] Would upload: %s${NC}\n" "$name"
            (( success++ ))
            continue
        fi

        printf "Uploading %s... " "$name"
        local upload_args=("$f" "--name" "$name")
        [[ -n "$folder_id" ]] && upload_args+=("--parent" "$folder_id")

        if gog drive upload "${upload_args[@]}" >/dev/null 2>&1; then
            printf "${GREEN}ok${NC}\n"
            (( success++ ))
        else
            printf "${RED}FAILED${NC}\n"
            (( failed++ ))
        fi
    done

    printf "\n"
    if [[ "$dry_run" == "true" ]]; then
        printf "${BLUE}Dry run complete. %d file(s) would be uploaded.${NC}\n" "$success"
    else
        printf "${GREEN}Done. %d uploaded${NC}" "$success"
        [[ $failed -gt 0 ]] && printf ", ${RED}%d failed${NC}" "$failed"
        printf "\n"
        if [[ -n "$folder_id" && "$failed" -eq 0 ]]; then
            printf "Drive folder: https://drive.google.com/drive/folders/%s\n" "$folder_id"
        fi
    fi

    [[ $failed -gt 0 ]] && exit 1
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
