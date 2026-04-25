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
        --overwrite               Clear existing sheet rows before writing (keeps headers)
        --share <emails>          Share the sheet with comma-separated email addresses
        --share-role <role>       Share role: reader|commenter|writer (default: writer)
        --model <name>            Vision model for image analysis (default: $DEFAULT_OLLAMA_MODEL)
        --text-model <name>       Text model for grouping/pricing (default: same as --model)
                                  Use a stronger text model e.g. qwen3.5:9b for better results
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

# Strip thinking tokens, markdown fences, and extract the first JSON array/object.
# Handles qwen3/deepseek-style <think>...</think> reasoning blocks.
function extract_json() {
    local text="$1"
    printf "%s" "$text" | python3 -c "
import sys, json, re
text = sys.stdin.read()
# Strip <think>...</think> blocks (qwen3, deepseek-r1, etc.)
text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL)
# Strip markdown code fences
text = re.sub(r'\`\`\`[a-z]*', '', text)
# Find the first valid JSON array or object
for i, c in enumerate(text):
    if c in '[{':
        try:
            obj, _ = json.JSONDecoder().raw_decode(text, i)
            print(json.dumps(obj))
            break
        except:
            continue
" 2>/dev/null
}

function ollama_chat() {
    local host="$1" model="$2" prompt="$3" image_b64="$4"
    local req_file response

    req_file=$(mktemp)

    if [[ -n "$image_b64" ]]; then
        # Write b64 to a temp file and use --rawfile to avoid hitting
        # the OS ARG_MAX limit (~2MB) with large images passed via --arg
        local b64_file
        b64_file=$(mktemp)
        printf "%s" "$image_b64" > "$b64_file"
        jq -n \
            --arg model "$model" \
            --arg content "$prompt" \
            --rawfile img "$b64_file" \
            '{model: $model, stream: false, messages: [{role: "user", content: $content, images: [$img]}]}' \
            > "$req_file"
        rm -f "$b64_file"
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

# Build lots directly from per-photo analysis without needing a grouping model call.
# Used as a fallback when the model can't produce valid JSON for the grouping step.
function lots_from_analysis() {
    local items_json="$1"
    printf "%s" "$items_json" | jq '[
        to_entries[] |
        # Normalise analysis to an object regardless of what the model returned
        (.value.analysis | if type == "object" then . else {} end) as $a |
        {
            lot_number:   (.key + 1),
            item_name:    ($a.item_name  // "Unknown Item"),
            category:     ($a.category  // "Other"),
            brand:        ($a.brand     // "Unknown"),
            quantity:     1,
            condition:    ($a.condition // "Unknown"),
            description:  ($a.description // ""),
            ebay_low:     0,
            ebay_high:    0,
            etsy_low:     0,
            etsy_high:    0,
            other_markets: "",
            recommended_low:  0,
            recommended_high: 0,
            pricing_notes: "Manual pricing required — model could not complete market research",
            photo_files:  [.value.filename],
            keywords:     ($a.keywords // [])
        }
    ]'
}

# Deterministically group items into candidate lots using timestamp proximity.
# Photos taken within window_secs of each other = same item photographed from
# multiple angles. Returns JSON: [{group_id, photo_files, analyses}]
function pre_group_by_timestamp() {
    local items_json="$1" window="${2:-90}"
    local items_file
    items_file=$(mktemp)
    printf "%s" "$items_json" > "$items_file"

    python3 - "$items_file" "$window" <<'PYEOF'
import sys, json, re
from datetime import datetime

def parse_ts(filename):
    m = re.search(r'(\d{8}_\d{6})', filename)
    if m:
        try:
            return datetime.strptime(m.group(1), '%Y%m%d_%H%M%S').timestamp()
        except:
            pass
    return None

with open(sys.argv[1]) as f:
    items = json.load(f)
window = float(sys.argv[2])

timestamped, no_ts = [], []
for item in items:
    ts = parse_ts(item['filename'])
    if ts is not None:
        timestamped.append((ts, item))
    else:
        no_ts.append(item)
timestamped.sort(key=lambda x: x[0])

groups, current, last_ts = [], [], None
for ts, item in timestamped:
    if last_ts is None or (ts - last_ts) > window:
        if current:
            groups.append(current)
        current = [(ts, item)]
    else:
        current.append((ts, item))
    last_ts = ts
if current:
    groups.append(current)
for item in no_ts:
    groups.append([(None, item)])

result = []
for idx, group in enumerate(groups):
    result.append({
        'group_id': idx + 1,
        'photo_files': [item['filename'] for _, item in group],
        'analyses': [{'filename': item['filename'], 'analysis': item.get('analysis', {}), 'file_id': item.get('file_id', '')} for _, item in group]
    })
print(json.dumps(result))
PYEOF
    local rc=$?
    rm -f "$items_file"
    return $rc
}

# Renumber lots 1..N regardless of what the model assigned.
function renumber_lots() {
    printf "%s" "$1" | jq '[to_entries[] | .value + {lot_number: (.key + 1)}]'
}

function group_and_price() {
    local host="$1" model="$2" items_json="$3"
    local groups_json group_count

    # Phase 1 — deterministic timestamp grouping (no model needed)
    log_info "Pre-grouping photos by timestamp proximity..."
    groups_json=$(pre_group_by_timestamp "$items_json" 90)
    if [[ -z "$groups_json" ]]; then
        log_warn "Timestamp grouping failed — falling back to one lot per item"
        lots_from_analysis "$items_json"
        return 0
    fi
    group_count=$(printf "%s" "$groups_json" | jq 'length')
    log_info "$group_count candidate lot(s) after timestamp grouping"

    # Phase 2 — ask model to name, describe, and price each pre-grouped candidate lot
    # Model no longer needs to figure out which photos go together — that's already done.
    # We batch into chunks of 25 so we never hit output token limits.
    local all_lots="[]"
    local batch_size=25
    local total_groups="$group_count"
    local start=0

    while [[ $start -lt $total_groups ]]; do
        local batch_groups end_idx batch_summary prompt text extracted
        end_idx=$(( start + batch_size - 1 ))
        batch_groups=$(printf "%s" "$groups_json" | jq --argjson s "$start" --argjson e "$end_idx" '.[$s:($e+1)]')

        # Build one line per candidate lot showing its analyses
        batch_summary=$(printf "%s" "$batch_groups" | jq -r '
            def str: if type == "array" then join(", ") elif . == null then "?" else tostring end;
            .[] |
            "Lot \(.group_id) (" + (.photo_files | length | tostring) + " photos): " +
            (.analyses | map(
                (.analysis | if type == "object" then . else {} end) as $a |
                ($a.item_name | str) + " / " + ($a.brand | str) + " / " +
                ($a.condition | str) + " / " + ($a.color | str)
            ) | join(" | "))
        ')
        local batch_count
        batch_count=$(printf "%s" "$batch_groups" | jq 'length')

        prompt="You are an expert auction house appraiser. I have pre-grouped ${batch_count} auction lots by photograph timestamp — each lot already contains all photos of one physical item.

For each lot below, provide a name, description, and realistic eBay SOLD price range. Use only the lot numbers shown.

${batch_summary}

Output ONLY a raw JSON array — no markdown, no explanation:
[{\"lot_number\":1,\"item_name\":\"specific descriptive name\",\"category\":\"Electronics|Clothing|Tools|Collectibles|Jewelry|HomeDecor|Sports|Books|Toys|Kitchen|Furniture|Art|Other\",\"brand\":\"brand or Unknown\",\"quantity\":1,\"condition\":\"Excellent|Good|Fair|Poor\",\"description\":\"compelling 2-3 sentence auction listing\",\"ebay_low\":5.00,\"ebay_high\":25.00,\"etsy_low\":0.00,\"etsy_high\":0.00,\"other_markets\":\"\",\"recommended_low\":8.00,\"recommended_high\":20.00,\"pricing_notes\":\"brief justification\",\"keywords\":[\"tag\"]}]"

        log_info "Pricing batch lots $((start+1))–$((start + batch_count)) of $total_groups..."
        text=$(ollama_chat "$host" "$model" "$prompt" "")

        if [[ -n "$text" ]]; then
            extracted=$(extract_json "$text")
            if [[ -n "$extracted" ]] && printf "%s" "$extracted" | jq -e 'arrays | length > 0' &>/dev/null; then
                all_lots=$(printf "%s\n%s" "$all_lots" "$extracted" | jq -s 'add')
            else
                log_warn "Model returned invalid JSON for batch starting at $((start+1)) — using analysis fallback for this batch"
                printf "%s" "$text" >> "./lots_raw_${FOLDER_NAME}.txt"
                local fallback_batch
                fallback_batch=$(printf "%s" "$batch_groups" | jq '
                    [.[] | {
                        lot_number: .group_id,
                        item_name: (.analyses[0].analysis.item_name // "Unknown Item"),
                        category: (.analyses[0].analysis.category // "Other"),
                        brand: (.analyses[0].analysis.brand // "Unknown"),
                        quantity: (.photo_files | length),
                        condition: (.analyses[0].analysis.condition // "Unknown"),
                        description: (.analyses[0].analysis.description // ""),
                        ebay_low: 0, ebay_high: 0, etsy_low: 0, etsy_high: 0,
                        other_markets: "",
                        recommended_low: 0, recommended_high: 0,
                        pricing_notes: "Manual pricing required",
                        keywords: (.analyses[0].analysis.keywords // [])
                    }]
                ')
                all_lots=$(printf "%s\n%s" "$all_lots" "$fallback_batch" | jq -s 'add')
            fi
        else
            log_warn "Empty response for batch starting at $((start+1))"
        fi

        start=$(( start + batch_size ))
    done

    # Attach photo_files from the pre-grouped data (model no longer tracks these)
    local groups_map
    groups_map=$(printf "%s" "$groups_json" | jq 'map({key: (.group_id | tostring), value: .photo_files}) | from_entries')

    all_lots=$(printf "%s" "$all_lots" | jq \
        --argjson gmap "$groups_map" \
        '[.[] | . + {photo_files: ($gmap[.lot_number | tostring] // [])}]')

    if [[ -z "$all_lots" ]] || ! printf "%s" "$all_lots" | jq -e 'arrays | length > 0' &>/dev/null; then
        log_warn "All batches failed — falling back to one lot per item"
        lots_from_analysis "$items_json"
        return 0
    fi

    printf "%s" "$all_lots"
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
    gog drive ls --parent "$folder_id" --max 1000 --json --results-only 2>/dev/null | \
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

function find_sheet_by_name() {
    local name="$1"
    gog drive search "name = '$name' and mimeType = 'application/vnd.google-apps.spreadsheet'" \
        --json --results-only --max 5 2>/dev/null | jq -r '.[0].id // empty'
}

function create_auction_sheet() {
    local sheet_name="$1" lots_json="$2" items_json="$3" overwrite="$4"

    # Reuse existing sheet if one with this name already exists
    local sheet_id existing
    existing=$(find_sheet_by_name "$sheet_name")

    if [[ -n "$existing" ]]; then
        sheet_id="$existing"
        if [[ "$overwrite" == "true" ]]; then
            log_ok "Found existing sheet '$sheet_name' ($sheet_id) — clearing rows"
            gog sheets clear "$sheet_id" "Sheet1!A2:Z" --force >/dev/null 2>&1
        else
            log_ok "Found existing sheet '$sheet_name' ($sheet_id) — appending"
        fi
    else
        log_step "Creating spreadsheet: $sheet_name"
        local create_output
        create_output=$(gog sheets create "$sheet_name" --json 2>&1)
        log_info "sheets create raw output: $create_output"
        sheet_id=$(printf "%s" "$create_output" | jq -r '
            .spreadsheetId //
            .result.spreadsheetId //
            .data.spreadsheetId //
            (.[] | .spreadsheetId?) //
            empty' 2>/dev/null)
        if [[ -z "$sheet_id" ]]; then
            log_error "Failed to create spreadsheet. Raw output: $create_output"
            return 1
        fi
        log_ok "Created sheet: $sheet_id"

        local headers='[["Lot #","Category","Item Name","Brand","Qty","Condition","Description","eBay Low","eBay High","Etsy Low","Etsy High","Other Markets","Rec. Low","Rec. High","Pricing Notes","Keywords","Photo Links"]]'
        gog sheets update "$sheet_id" "Sheet1!A1:Q1" \
            --values-json "$headers" --input USER_ENTERED >/dev/null 2>&1
    fi

    # Build filename -> Drive URL map from items_json
    local url_map
    url_map=$(printf "%s" "$items_json" | jq '
        [.[] | {key: .filename, value: ("https://drive.google.com/file/d/" + .file_id + "/view")}]
        | from_entries
    ')

    local rows
    rows=$(printf "%s" "$lots_json" | jq \
        --argjson urls "$url_map" '
        [.[] | [
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
            # Build one HYPERLINK formula per photo, newline-separated
            (.photo_files // [] |
                map(. as $f | "=HYPERLINK(\"" + ($urls[$f] // "") + "\",\"" + $f + "\")")
                | join("\n"))
        ]]
    ')

    if [[ -z "$rows" || "$rows" == "[]" ]]; then
        log_error "No rows to write to sheet"
        return 1
    fi

    log_info "Writing $(printf "%s" "$rows" | jq 'length') rows..."
    gog sheets append "$sheet_id" "Sheet1!A:Q" \
        --values-json "$rows" --insert INSERT_ROWS --input USER_ENTERED >/dev/null 2>&1

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
    local ollama_text_model=""
    local share_emails="" share_role="writer" overwrite="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sheet-name)   sheet_name="$2";         shift ;;
            --overwrite)    overwrite="true" ;;
            --share)        share_emails="$2";       shift ;;
            --share-role)   share_role="$2";         shift ;;
            --model)        ollama_model="$2";       shift ;;
            --text-model)   ollama_text_model="$2";  shift ;;
            --ollama-host)  ollama_host="$2";        shift ;;
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
    # Default text model to vision model if not separately specified
    [[ -z "$ollama_text_model" ]] && ollama_text_model="$ollama_model"

    # Verify Ollama is up and both models are available
    log_step "Checking Ollama at $ollama_host (vision: $ollama_model, text: $ollama_text_model)..."
    if ! check_ollama "$ollama_host" "$ollama_model"; then
        exit 1
    fi
    if [[ "$ollama_text_model" != "$ollama_model" ]]; then
        if ! check_ollama "$ollama_host" "$ollama_text_model"; then
            exit 1
        fi
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
    lots_json=$(group_and_price "$ollama_host" "$ollama_text_model" "$items_json")

    if [[ -z "$lots_json" ]] || ! printf "%s" "$lots_json" | jq -e 'arrays' &>/dev/null; then
        log_error "Failed to get valid lots from model — check ./lots_raw_${folder_name}.txt"
        exit 1
    fi

    # Renumber lots sequentially starting at 1
    lots_json=$(renumber_lots "$lots_json")

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
    sheet_id=$(create_auction_sheet "$sheet_name" "$lots_json" "$items_json" "$overwrite")
    if [[ -z "$sheet_id" ]]; then
        log_error "Spreadsheet creation failed"
        exit 1
    fi

    # --- Step 4: Share the sheet ---
    if [[ -n "$share_emails" ]]; then
        log_step "Sharing sheet with: $share_emails (role: $share_role)"
        IFS=',' read -ra email_list <<< "$share_emails"
        for email in "${email_list[@]}"; do
            email="${email// /}"   # strip any spaces
            [[ -z "$email" ]] && continue
            if gog drive share "$sheet_id" --email "$email" --role "$share_role" --no-input >/dev/null 2>&1; then
                log_ok "Shared with $email"
            else
                log_warn "Failed to share with $email"
            fi
        done
    fi

    log_ok "Done!"
    printf "\n"
    printf "  Spreadsheet: https://docs.google.com/spreadsheets/d/%s\n" "$sheet_id"
    printf "  Lots:        %d\n" "$lot_count"
    printf "  Items:       %d\n" "$analyzed_count"
    printf "  Checkpoint:  %s\n" "$checkpoint_file"
    [[ -n "$share_emails" ]] && printf "  Shared with: %s\n" "$share_emails"
    printf "\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
