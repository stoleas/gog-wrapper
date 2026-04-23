# gog-wrapper

Bash wrappers around [`gogcli`](https://github.com/steipete/gogcli) for Google Workspace CLI access — Gmail, Calendar, Drive, Docs, and Sheets.

## Requirements

- [`gogcli`](https://github.com/steipete/gogcli) installed as `gog` and in `PATH`
- A `vars.sh` file (see [Configuration](#configuration))

## Configuration

Copy `vars.sh` and set your defaults:

```sh
DEFAULT_GOG_ACCOUNT="you@example.com"
GOG_KEYRING_PASSWORD=""
```

The `GOG_ACCOUNT` environment variable always takes precedence over `DEFAULT_GOG_ACCOUNT`. You can also override per-command with `-a <email>`.

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
