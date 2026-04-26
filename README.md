# gog-wrapper

Bash wrappers around [`gogcli`](https://github.com/steipete/gogcli) for Google Workspace CLI access — Gmail, Calendar, Drive, Docs, and Sheets.

## Requirements

- [`gogcli`](https://github.com/steipete/gogcli) installed as `gog` and in `PATH`
- A `vars.local.sh` file (see [Configuration](#configuration))

## Use as an AI skill

### Claude Code

Symlink this repo into Claude's skills directory so Claude picks it up automatically:

```sh
mkdir -p ~/.claude/skills
ln -s "$(pwd)" ~/.claude/skills/gog-wrapper
```

### OpenClaw

Symlink this repo into OpenClaw's skills directory:

```sh
mkdir -p ~/.openclaw/skills
ln -s "$(pwd)" ~/.openclaw/skills/gog-wrapper
```

Then enable it in `~/.openclaw/openclaw.json`:

```json5
{
  skills: {
    entries: {
      "gog-wrapper": {
        enabled: true,
        env: { GOG_ACCOUNT: "you@gmail.com" }
      }
    }
  },
  agents: {
    defaults: { skills: ["gog-wrapper"] }
  }
}
```

## Configuration

Create `vars.local.sh` (gitignored — never committed) with your account:

```sh
cp vars.local.sh.example vars.local.sh
# then edit vars.local.sh
```

```sh
# vars.local.sh
DEFAULT_GOG_ACCOUNT="you@gmail.com"
# GOG_KEYRING_PASSWORD="your-keyring-password"   # only if needed
```

`vars.sh` is the committed template that sources `vars.local.sh` automatically. The `GOG_ACCOUNT` environment variable always takes precedence over `DEFAULT_GOG_ACCOUNT`. You can also override per-command with `-a <email>`.

## Scripts

### `gmail.sh` — Gmail

```
gmail.sh <command> [flags]
```

| Group | Commands |
|-------|----------|
| Read | `search`, `messages search`, `get`, `attachment`, `url` |
| Organize | `archive`, `mark-read`, `unread`, `trash`, `thread`, `labels`, `batch` |
| Write | `send`, `drafts`, `autoreply` |

**Examples**

```sh
./gmail.sh search 'newer_than:7d is:unread' --max 10
./gmail.sh send --to someone@example.com --subject "Hi" --body "Hello"
./gmail.sh drafts create --to a@b.com --subject "Draft" --body-file draft.txt
./gmail.sh archive $(./gmail.sh search 'older_than:30d' --json --results-only | jq -r '.[].id')
```

---

### `calendar.sh` — Google Calendar

```
calendar.sh <command> [flags]
```

| Commands |
|----------|
| `calendars`, `events`, `event`, `create`, `update`, `delete`, `search`, `freebusy`, `colors`, `conflicts`, `respond`, `focus-time`, `out-of-office`, `working-location`, `users`, `team` |

**Examples**

```sh
./calendar.sh calendars
./calendar.sh events primary --from 2026-04-23T00:00:00Z --to 2026-04-30T00:00:00Z
./calendar.sh create primary --summary "Team standup" --from 2026-04-24T09:00:00Z --to 2026-04-24T09:30:00Z
./calendar.sh search "standup" --max 10 --json
./calendar.sh freebusy --from 2026-04-24T00:00:00Z --to 2026-04-25T00:00:00Z
```

---

### `drive.sh` — Google Drive

```
drive.sh <command> [flags]
```

| Group | Commands |
|-------|----------|
| Browse | `ls`, `search`, `get`, `url`, `drives`, `permissions`, `comments` |
| Files | `download`, `upload`, `copy`, `move`, `rename`, `delete`, `mkdir` |
| Share | `share`, `unshare` |

**Examples**

```sh
./drive.sh ls
./drive.sh search "Q1 report" --max 10
./drive.sh upload ./report.pdf --name "Q1 Report 2026" --folder <folderId>
./drive.sh download <fileId> --out ./local-copy.pdf
./drive.sh share <fileId> --email colleague@example.com --role reader
```

---

### `docs.sh` — Google Docs

```
docs.sh <command> [flags]
```

| Group | Commands |
|-------|----------|
| Read | `cat`, `info`, `structure`, `list-tabs`, `comments` |
| Write | `create`, `copy`, `write`, `insert`, `update`, `edit`, `find-replace`, `sed`, `delete`, `clear` |
| Export | `export` |

**Examples**

```sh
./docs.sh cat <docId>
./docs.sh create "Meeting Notes April 2026"
./docs.sh find-replace <docId> "old text" "new text"
./docs.sh sed <docId> 's/foo/bar/g'
./docs.sh export <docId> --format md --out ./doc.md
```

---

### `sheets.sh` — Google Sheets

```
sheets.sh <command> [flags]
```

| Group | Commands |
|-------|----------|
| Read | `get`, `metadata`, `notes`, `links`, `read-format`, `named-ranges` |
| Write | `update`, `append`, `clear`, `find-replace`, `update-note` |
| Structure | `create`, `copy`, `add-tab`, `rename-tab`, `delete-tab`, `insert`, `freeze`, `resize-columns`, `resize-rows` |
| Format | `format`, `merge`, `unmerge`, `number-format` |
| Export | `export` |

**Examples**

```sh
./sheets.sh get <spreadsheetId> "Sheet1!A1:D10"
./sheets.sh update <spreadsheetId> "Sheet1!A1:B2" --values-json '[["Name","Score"],["Alice","95"]]'
./sheets.sh append <spreadsheetId> "Sheet1!A:C" --values-json '[["2026-04-23","item","10"]]'
./sheets.sh export <spreadsheetId> --format xlsx
```

---

### `photos-to-drive.sh` — Bulk upload photos to Drive

Uploads a local folder of photos/videos to a Google Drive folder. Designed for saving a downloaded Google Photos shared album to Drive.

```
photos-to-drive.sh <source-folder> [flags]
```

**Examples**

```sh
# Create a new Drive folder and upload into it
./photos-to-drive.sh ~/Downloads/album --album-name "Beach Trip 2026"

# Upload into an existing Drive folder
./photos-to-drive.sh ~/Downloads/album --folder <driveId>

# Preview without uploading
./photos-to-drive.sh ~/Downloads/album --album-name "Trip" --dry-run
```

---

### `analyze-for-auction.sh` — Auction analysis spreadsheet

Analyzes photos in a Google Drive folder using a local [Ollama](https://ollama.com) vision model, groups items into lots, and writes descriptions and pricing to a Google Sheet.

**Extra requirements:**
- Ollama running with a vision model: `ollama pull llava` or `ollama pull llama3.2-vision`
- `jq` installed

```
analyze-for-auction.sh <drive-folder-name> [flags]
```

**Examples**

```sh
# Ollama on localhost
./analyze-for-auction.sh myfolder --sheet-name "Sale April 2026"

# Ollama on a remote server
./analyze-for-auction.sh myfolder \
  --ollama-host http://myserver:11434 \
  --model llava \
  --text-model qwen3.5:9b \
  --sheet-name "Sale April 2026" \
  --share colleague@example.com

# Resume after interruption (skips re-analyzing photos)
./analyze-for-auction.sh myfolder --resume ./analysis_myfolder.json
```

**Output spreadsheet columns:** Lot #, Category, Item Name, Brand, Qty, Condition, Description, eBay Low/High, Etsy Low/High, Other Markets, Rec. Low/High, Pricing Notes, Keywords, Photo Links

---

## Global Flags

All scripts share these flags:

| Flag | Description |
|------|-------------|
| `-j, --json` | Output JSON (recommended for scripting) |
| `-p, --plain` | Output TSV (stable, parseable) |
| `--results-only` | Emit only primary result in JSON mode |
| `-n, --dry-run` | Print intended actions without executing |
| `-y, --force` | Skip confirmations |
| `--no-input` | Never prompt; fail instead (for CI) |
| `-a, --account <email>` | Override the active account |
