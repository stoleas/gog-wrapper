#!/usr/bin/env bash
# Analyze photos in a Google Drive folder and produce an auction spreadsheet.
# Uses a local Ollama vision model — no API key or cloud costs required.
#
# Usage: ./analyze-for-auction.sh <drive-folder-name> [flags]
# Requires: ollama running locally with a vision model pulled

# shellcheck source=vars.sh
source "$(dirname "${BASH_SOURCE[0]}")/vars.sh"

SCRIPT_NAME=$(basename "$0")
DEFAULT_OLLAMA_MODEL="llama3.2-vision"
DEFAULT_OLLAMA_HOST="http://localhost:11434"
DEPENDENCIES=(gog curl jq base64)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
fi

function usage() {
    cat <<EOM

Analyze photos in a Google Drive folder and create an auction spreadsheet.
Uses a local Ollama vision model for image analysis and pricing research.

usage: ${SCRIPT_NAME} <drive-folder-name> [flags]

arguments:
    <drive-folder-name>           Name of the Drive folder containing photos

flags:
        --sheet-name <name>       Name for the output spreadsheet (default: "Auction - <folder>")
        --model <name>            Ollama model to use (default: $DEFAULT_OLLAMA_MODEL)
        --ollama-host <url>       Ollama host (default: $DEFAULT_OLLAMA_HOST)
        --resume <analysis.json>  Skip photo analysis; resume from a saved analysis file
    -n, --dry-run                 Analyze photos but don't create the spreadsheet
    -a, --account <email>         Override Google account
        --no-input                Never prompt; fail instead (for CI)

environment:
    OLLAMA_MODEL                  Ollama model name (overridden by --model)
    OLLAMA_HOST                   Ollama base URL (overridden by --ollama-host)
    GOG_ACCOUNT                   Google account (or set in vars.sh)

dependencies: ${DEPENDENCIES[*]}

setup (one-time):
    ollama pull llama3.2-vision        # recommended (~8GB, best quality)
    ollama pull llava                  # alternative (~4GB, faster)

examples:
    ${SCRIPT_NAME} kellystore4242026
    ${SCRIPT_NAME} kellystore4242026 --sheet-name "Kelly Store April 2026"
    ${SCRIPT_NAME} kellystore4242026 --model llava
    ${SCRIPT_NAME} kellystore4242026 --ollama-host http://openclaw:11434
    ${SCRIPT_NAME} kellystore4242026 --dry-run
    ${SCRIPT_NAME} kellystore4242026 --resume ./analysis_kellystore4242026.json

workflow:
    1. Finds the Drive folder by name
    2. Downloads each image to a temp directory
    3. Sends each photo to Ollama for item identification and condition assessment
    4. Saves raw analysis to ./analysis_<folder>.json (checkpoint — resume if interrupted)
    5. Groups identical/similar items and researches market prices
    6. Creates a Google Sheet with lot numbers, descriptions, and price ranges

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

function log_info()  { printf "${BLUE}[info]${NC}  %s\n" "$*" >&2; }
function log_ok()    { printf "${GREEN}[ok]${NC}    %s\n" "$*" >&2; }
function log_warn()  { printf "${YELLOW}[warn]${NC}  %s\n" "$*" >&2; }
function log_error() { printf "${RED}[error]${NC} %s\n" "$*" >&2; }
function log_step()  { printf "${CYAN}[step]${NC}  %s\n" "$*" >&2; }

function check_ollama() {
    local host="$1" model="$2"
    if ! curl -sf "$host/api/tags" >/dev/null 2>&1; then
        log_error "Ollama is not running at $host"
        printf "  Start it with: ollama serve\n" >&2
        return 1
    fi
    local models
    models=$(curl -sf "$host/api/tags" | jq -r '.models[].name' 2>/dev/null)
    local model_base="${model%%:*}"
    if ! printf "%s" "$models" | grep -q "^${model_base}"; then
        log_error "Model '$model' not found in Ollama"
        printf "  Pull it with: ollama pull %s\n" "$model" >&2
        printf "  Available models:\n" >&2
        printf "%s" "$models" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}

# Strip markdown code fences and extract the first JSON object/array from text
function extract_json() {
    local text="$1"
    # Remove ```json ... ``` or ``` ... ``` fences
    text=$(printf "%s" "$text" | sed 's/^```[a-z]*//;s/^```//')
    # Try to extract first complete JSON array or object
    printf "%s" "$text" | python3 -c "
import sys, json
text = sys.stdin.read()
# Find first [ or {
for i, c in enumerate(text):
    if c in '[{':
        try:
            obj, end = json.JSONDecoder().raw_decode(text, i)
            print(json.dumps(obj))
            break
        except:
            continue
" 2>/dev/null || printf "%s" "$text" | jq -r '.' 2>/dev/null
}

function ollama_chat() {
    local host="$1" model="$2" prompt="$3" image_b64="$4"
    local req_file response

    req_file=$(mktemp)

    if [[ -n "$image_b64" ]]; then
        jq -n \
            --arg model "$model" \
            --arg content "$prompt" \
            --arg img "$image_b64" \
            '{model: $model, stream: false, messages: [{role: "user", content: $content, images: [$img]}]}' \
            > "$req_file"
    else
        jq -n \
            --arg model "$model" \
            --arg content "$prompt" \
            '{model: $model, stream: false, messages: [{role: "user", content: $content}]}' \
            > "$req_file"
    fi

    response=$(curl -s --max-time 300 -X POST "$host/api/chat" \
        -H "content-type: application/json" \
        -d @"$req_file")
    rm -f "$req_file"

    printf "%s" "$response" | jq -r '.message.content // empty'
}

function analyze_image() {
    local host="$1" model="$2" image_path="$3" filename="$4"
    local b64 prompt text

    # Strip all whitespace — some base64 implementations add line breaks
    # that cause "illegal base64 data" errors in Ollama
    b64=$(base64 -w 0 "$image_path" 2>/dev/null | tr -d '\n\r ')
    if [[ -z "$b64" ]]; then
        printf '{"error": "base64 encoding failed for %s"}' "$filename"
        return 1
    fi

    prompt="You are an expert auction house appraiser. Analyze this item photo for an auction listing.
Filename: $filename

Respond ONLY with valid JSON — no markdown, no explanation, no code fences. Use exactly this structure:
{\"item_name\": \"specific descriptive name\", \"category\": \"Electronics|Clothing|Tools|Collectibles|Jewelry|HomeDecor|Sports|Books|Toys|Kitchen|Furniture|Art|Other\", \"brand\": \"brand/manufacturer or Unknown\", \"model\": \"model number or Unknown\", \"color\": \"primary color(s)\", \"condition\": \"Excellent|Good|Fair|Poor\", \"condition_notes\": \"visible defects, wear, or damage\", \"description\": \"2-3 sentence auction listing description highlighting key selling points\", \"keywords\": [\"tag1\", \"tag2\"]}"

    text=$(ollama_chat "$host" "$model" "$prompt" "$b64")

    if [[ -z "$text" ]]; then
        printf '{"error": "empty response"}' >&2
        return 1
    fi

    local extracted
    extracted=$(extract_json "$text")
    if [[ -z "$extracted" ]]; then
        # Fall back: return raw text wrapped so we don't lose it
        jq -n --arg raw "$text" '{"item_name": "Unknown", "category": "Other", "brand": "Unknown", "model": "Unknown", "color": "Unknown", "condition": "Unknown", "condition_notes": "", "description": $raw, "keywords": []}'
    else
        printf "%s" "$extracted"
    fi
}

function group_and_price() {
    local host="$1" model="$2" items_json="$3"
    local items_summary item_count prompt text extracted

    items_summary=$(printf "%s" "$items_json" | jq -r '
        to_entries | .[] |
        ((.key + 1) | tostring) + ". [" + .value.filename + "] " + (.value.analysis | tostring)
    ')
    item_count=$(printf "%s" "$items_json" | jq 'length')

    prompt="You are an expert auction house appraiser and resale pricing specialist with deep knowledge of eBay sold listings, Etsy, LiveAuctioneers, and other resale markets.

I have $item_count items photographed for auction:

$items_summary

Please:
1. Group identical or very similar items together into lots
2. Write a compelling auction listing description for each lot
3. Provide realistic price ranges based on eBay SOLD listings and comparable auction results
4. Adjust prices for the stated condition

Respond ONLY with a valid JSON array — no markdown, no explanation, no code fences. Each element must have exactly these fields:
{\"lot_number\": 1, \"item_name\": \"clear name\", \"category\": \"category\", \"brand\": \"brand or Unknown\", \"quantity\": 1, \"condition\": \"Excellent|Good|Fair|Poor\", \"description\": \"3-4 sentence compelling auction description\", \"ebay_low\": 5.00, \"ebay_high\": 25.00, \"etsy_low\": 0.00, \"etsy_high\": 0.00, \"other_markets\": \"notes\", \"recommended_low\": 8.00, \"recommended_high\": 20.00, \"pricing_notes\": \"brief justification\", \"photo_files\": [\"file.jpg\"], \"keywords\": [\"tag1\", \"tag2\"]}"

    text=$(ollama_chat "$host" "$model" "$prompt" "")

    if [[ -z "$text" ]]; then
        log_error "Empty response from Ollama during grouping step"
        return 1
    fi

    extracted=$(extract_json "$text")
    if [[ -z "$extracted" ]]; then
        log_warn "Could not parse JSON from grouping response — saving raw output"
        printf "%s" "$text" > "./lots_raw_${FOLDER_NAME}.txt"
        log_info "Raw response saved to ./lots_raw_${FOLDER_NAME}.txt"
        return 1
    fi

    printf "%s" "$extracted"
}

function find_drive_folder() {
    local name="$1"
    local result
    result=$(gog drive search "name = '$name' and mimeType = 'application/vnd.google-apps.folder'" \
        --json --results-only --max 5 2>&1)
    if [[ "$result" == *"error"* ]] && ! printf "%s" "$result" | jq -e '.[0].id' &>/dev/null; then
        log_error "Drive search failed: $result"
        return 1
    fi
    printf "%s" "$result" | jq -r '.[0].id // empty'
}

function list_drive_images() {
    local folder_id="$1"
    gog drive ls --parent "$folder_id" --json --results-only 2>/dev/null | \
        jq -r '.[] | select(.mimeType | test("^image/")) | [.id, .name, .mimeType] | @tsv'
}

function download_image_file() {
    local file_id="$1" out_path="$2"
    local err
    err=$(gog drive download "$file_id" --out "$out_path" --force 2>&1)
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_warn "gog drive download failed: $err"
        return 1
    fi
    if [[ ! -s "$out_path" ]]; then
        log_warn "Downloaded file is empty: $out_path"
        return 1
    fi
    return 0
}

function create_auction_sheet() {
    local sheet_name="$1" lots_json="$2"

    log_step "Creating spreadsheet: $sheet_name"
    local sheet_id
    sheet_id=$(gog sheets create "$sheet_name" --json --results-only 2>/dev/null | jq -r '.spreadsheetId // empty')
    if [[ -z "$sheet_id" ]]; then
        log_error "Failed to create spreadsheet"
        return 1
    fi
    log_ok "Created sheet: $sheet_id"

    local headers='[["Lot #","Category","Item Name","Brand","Qty","Condition","Description","eBay Low","eBay High","Etsy Low","Etsy High","Other Markets","Rec. Low","Rec. High","Pricing Notes","Keywords","Photos"]]'
    gog sheets update "$sheet_id" "Sheet1!A1:Q1" \
        --values-json "$headers" --input USER_ENTERED >/dev/null 2>&1

    local rows
    rows=$(printf "%s" "$lots_json" | jq '[
        .[] | [
            (.lot_number | tostring),
            .category,
            .item_name,
            (.brand // "Unknown"),
            (.quantity | tostring),
            .condition,
            .description,
            ("$" + (.ebay_low | tostring)),
            ("$" + (.ebay_high | tostring)),
            ("$" + (.etsy_low | tostring)),
            ("$" + (.etsy_high | tostring)),
            (.other_markets // ""),
            ("$" + (.recommended_low | tostring)),
            ("$" + (.recommended_high | tostring)),
            (.pricing_notes // ""),
            (.keywords // [] | join(", ")),
            (.photo_files // [] | join(", "))
        ]
    ]')

    if [[ -z "$rows" || "$rows" == "[]" ]]; then
        log_error "No rows to write to sheet"
        return 1
    fi

    log_info "Writing $(printf "%s" "$rows" | jq 'length') rows..."
    gog sheets append "$sheet_id" "Sheet1!A:Q" \
        --values-json "$rows" --insert INSERT_ROWS >/dev/null 2>&1

    printf "%s" "$sheet_id"
}

# Exported so group_and_price can reference it in the raw fallback filename
FOLDER_NAME=""

function main() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    exit_on_missing_tools "${DEPENDENCIES[@]}"

    local folder_name="$1"
    shift
    FOLDER_NAME="$folder_name"

    local sheet_name="" resume_file="" dry_run="false" no_input="false" account=""
    local ollama_host="${OLLAMA_HOST:-$DEFAULT_OLLAMA_HOST}"
    local ollama_model="${OLLAMA_MODEL:-$DEFAULT_OLLAMA_MODEL}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sheet-name)   sheet_name="$2";     shift ;;
            --model)        ollama_model="$2";   shift ;;
            --ollama-host)  ollama_host="$2";    shift ;;
            --resume)       resume_file="$2";    shift ;;
            -n|--dry-run)   dry_run="true" ;;
            --no-input)     no_input="true" ;;
            -a|--account)   account="$2";        shift ;;
            *) log_error "Unknown flag: $1"; usage ;;
        esac
        shift
    done

    [[ -n "$account" ]] && export GOG_ACCOUNT="$account"
    export GOG_ACCOUNT="${GOG_ACCOUNT:-${DEFAULT_GOG_ACCOUNT}}"
    [[ -z "$sheet_name" ]] && sheet_name="Auction - $folder_name"

    # Verify Ollama is up and model is available
    log_step "Checking Ollama at $ollama_host (model: $ollama_model)..."
    if ! check_ollama "$ollama_host" "$ollama_model"; then
        exit 1
    fi
    log_ok "Ollama ready"

    local checkpoint_file="./analysis_${folder_name}.json"
    local items_json="[]"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

    # --- Step 1: Photo analysis ---
    if [[ -n "$resume_file" ]]; then
        log_step "Resuming from $resume_file"
        items_json=$(cat "$resume_file")
        log_ok "Loaded $(printf "%s" "$items_json" | jq 'length') items from checkpoint"
    else
        log_step "Finding Drive folder: $folder_name"
        local folder_id
        folder_id=$(find_drive_folder "$folder_name")
        if [[ -z "$folder_id" ]]; then
            log_error "Drive folder '$folder_name' not found"
            exit 1
        fi
        log_ok "Found folder: $folder_id"

        log_step "Listing images..."
        local image_list
        image_list=$(list_drive_images "$folder_id")
        if [[ -z "$image_list" ]]; then
            log_error "No images found in folder '$folder_name'"
            exit 1
        fi

        local total_images
        total_images=$(printf "%s\n" "$image_list" | wc -l | tr -d ' ')
        log_info "Found $total_images image(s) — this will take a few minutes"

        local idx=0
        while IFS=$'\t' read -r file_id filename mime_type; do
            (( idx++ ))
            local img_path="$tmp_dir/$filename"

            printf "${CYAN}[%d/%d]${NC} %-35s downloading... " "$idx" "$total_images" "$filename" >&2
            if ! download_image_file "$file_id" "$img_path" 2>/dev/null; then
                printf "${RED}failed, skipping${NC}\n" >&2
                continue
            fi
            local file_size
            file_size=$(wc -c < "$img_path" 2>/dev/null || echo 0)
            printf "analyzing (%d KB)... " "$(( file_size / 1024 ))" >&2

            local analysis
            analysis=$(analyze_image "$ollama_host" "$ollama_model" "$img_path" "$filename")

            if ! printf "%s" "$analysis" | jq -e . &>/dev/null; then
                printf "${YELLOW}parse error, skipping${NC}\n" >&2
                log_warn "Raw response for $filename: $analysis"
                continue
            fi

            printf "${GREEN}done${NC}\n" >&2

            items_json=$(printf "%s" "$items_json" | jq \
                --arg fid    "$file_id" \
                --arg fname  "$filename" \
                --argjson analysis "$analysis" \
                '. + [{"file_id": $fid, "filename": $fname, "analysis": $analysis}]')

        done <<< "$image_list"

        printf "%s" "$items_json" > "$checkpoint_file"
        log_ok "Checkpoint saved to $checkpoint_file"
    fi

    local analyzed_count
    analyzed_count=$(printf "%s" "$items_json" | jq 'length')
    if [[ "$analyzed_count" -eq 0 ]]; then
        log_error "No items were successfully analyzed"
        exit 1
    fi
    log_info "$analyzed_count item(s) analyzed"

    # --- Step 2: Grouping + market pricing ---
    log_step "Grouping items and researching market prices (this may take a few minutes)..."
    local lots_json
    lots_json=$(group_and_price "$ollama_host" "$ollama_model" "$items_json")

    if [[ -z "$lots_json" ]] || ! printf "%s" "$lots_json" | jq -e 'arrays' &>/dev/null; then
        log_error "Failed to get valid lots from model — check ./lots_raw_${folder_name}.txt"
        exit 1
    fi

    local lot_count
    lot_count=$(printf "%s" "$lots_json" | jq 'length')
    log_ok "$lot_count lot(s) identified"

    printf "%s" "$lots_json" > "./lots_${folder_name}.json"
    log_info "Lots saved to ./lots_${folder_name}.json"

    if [[ "$dry_run" == "true" ]]; then
        log_info "Dry run complete — skipping spreadsheet creation"
        printf "\n"
        printf "%s" "$lots_json" | jq -r \
            '.[] | "Lot \(.lot_number): \(.item_name) (x\(.quantity)) [\(.condition)] — $\(.recommended_low)–$\(.recommended_high)"'
        exit 0
    fi

    # --- Step 3: Create spreadsheet ---
    local sheet_id
    sheet_id=$(create_auction_sheet "$sheet_name" "$lots_json")
    if [[ -z "$sheet_id" ]]; then
        log_error "Spreadsheet creation failed"
        exit 1
    fi

    log_ok "Done!"
    printf "\n"
    printf "  Spreadsheet: https://docs.google.com/spreadsheets/d/%s\n" "$sheet_id"
    printf "  Lots:        %d\n" "$lot_count"
    printf "  Items:       %d\n" "$analyzed_count"
    printf "  Checkpoint:  %s\n" "$checkpoint_file"
    printf "\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
