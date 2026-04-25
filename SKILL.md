# gog-wrapper — Claude Skills

These bash scripts wrap [`gogcli`](https://github.com/steipete/gogcli) (invoked as `gog`) to give you CLI access to Google Workspace. Use them whenever the user asks you to read or write Gmail, Google Calendar, Drive, Docs, Sheets, or Photos on their behalf.

All scripts live in this directory. Run them with `bash <script>.sh` or `./script.sh` if executable. They all source `vars.sh` for the default account.

## Account

The active Google account is set by `GOG_ACCOUNT` or `DEFAULT_GOG_ACCOUNT` in `vars.sh`. Override per-command with `-a <email>`.

## Output modes

| Flag | When to use |
|------|-------------|
| `--json` | Scripting — structured output, pipe to `jq` |
| `--plain` | TSV — stable columns, pipe to `awk`/`cut` |
| `--results-only` | With `--json` — strips wrapper, emits array directly |
| `--dry-run` | Preview what would happen without executing |
| `--no-input` | CI/non-interactive — fail instead of prompting |

## gmail.sh

Wraps `gog gmail`. Use for reading and sending email.

```sh
# Search (Gmail query syntax)
./gmail.sh search 'is:unread newer_than:1d' --max 20 --json

# Read a specific message
./gmail.sh get <messageId> --json

# Send
./gmail.sh send --to someone@example.com --subject "Subject" --body "Body"
./gmail.sh send --to someone@example.com --subject "Subject" --body-file ./body.txt

# Organize
./gmail.sh archive <messageId>
./gmail.sh mark-read <messageId>
./gmail.sh trash <messageId>

# Batch archive old mail
./gmail.sh archive $(./gmail.sh search 'older_than:30d' --json --results-only | jq -r '.[].id')

# Drafts
./gmail.sh drafts create --to a@b.com --subject "Draft" --body-file draft.txt
./gmail.sh drafts list --json
```

## calendar.sh

Wraps `gog calendar`. Use for reading, creating, and managing calendar events.

```sh
# List calendars
./calendar.sh calendars --json

# List events in a date range
./calendar.sh events primary --from 2026-04-23T00:00:00Z --to 2026-04-30T00:00:00Z --json

# Get a single event
./calendar.sh event <calendarId> <eventId> --json

# Create an event
./calendar.sh create primary --summary "Standup" --from 2026-04-24T09:00:00Z --to 2026-04-24T09:30:00Z

# Update / delete
./calendar.sh update <calendarId> <eventId> --summary "New title"
./calendar.sh delete <calendarId> <eventId> --force

# Search
./calendar.sh search "standup" --max 10 --json

# Free/busy
./calendar.sh freebusy --from 2026-04-24T00:00:00Z --to 2026-04-25T00:00:00Z --json

# RSVP
./calendar.sh respond <calendarId> <eventId> --status accepted

# Workspace helpers
./calendar.sh users --json
./calendar.sh team engineering@example.com --json
./calendar.sh conflicts --json
```

## drive.sh

Wraps `gog drive`. Use for browsing, uploading, downloading, and sharing files.

```sh
# List files
./drive.sh ls --json
./drive.sh ls --folder <folderId> --json

# Search
./drive.sh search "Q1 report" --max 10 --json

# Get metadata / URL
./drive.sh get <fileId> --json
./drive.sh url <fileId>

# Download / upload
./drive.sh download <fileId> --out ./local.pdf
./drive.sh upload ./report.pdf --name "Q1 Report" --folder <folderId>

# Manage
./drive.sh copy <fileId> "Copy of Doc"
./drive.sh move <fileId> --folder <targetFolderId>
./drive.sh rename <fileId> "New Name"
./drive.sh delete <fileId> --force
./drive.sh mkdir "Project Assets" --folder <parentFolderId>

# Permissions
./drive.sh share <fileId> --email colleague@example.com --role reader
./drive.sh permissions <fileId> --json
./drive.sh unshare <fileId> <permissionId>
```

## docs.sh

Wraps `gog docs`. Use for reading and writing Google Docs.

```sh
# Read
./docs.sh cat <docId>
./docs.sh info <docId> --json
./docs.sh structure <docId>

# Create / copy
./docs.sh create "Meeting Notes"
./docs.sh copy <docId> "Copy of Doc"

# Write
./docs.sh write <docId> --body "Full replacement content"
./docs.sh insert <docId> --body "Inserted text" --index 1
./docs.sh find-replace <docId> "old" "new"
./docs.sh sed <docId> 's/foo/bar/g'
./docs.sh clear <docId> --force

# Export
./docs.sh export <docId> --format txt --out ./doc.txt
./docs.sh export <docId> --format md --out ./doc.md
./docs.sh export <docId> --format pdf --out ./doc.pdf
```

## sheets.sh

Wraps `gog sheets`. Use for reading and writing Google Sheets.

```sh
# Read a range (A1 notation)
./sheets.sh get <spreadsheetId> "Sheet1!A1:D10" --json

# Metadata
./sheets.sh metadata <spreadsheetId> --json

# Write
./sheets.sh update <spreadsheetId> "Sheet1!A1:B2" --values-json '[["Name","Score"],["Alice","95"]]' --input USER_ENTERED
./sheets.sh append <spreadsheetId> "Sheet1!A:C" --values-json '[["2026-04-23","item","10"]]'
./sheets.sh clear <spreadsheetId> "Sheet1!A2:Z" --force

# Find/replace
./sheets.sh find-replace <spreadsheetId> "old" "new"

# Structure
./sheets.sh create "New Spreadsheet"
./sheets.sh add-tab <spreadsheetId> "Tab2"
./sheets.sh rename-tab <spreadsheetId> "Tab2" "Summary"
./sheets.sh delete-tab <spreadsheetId> "OldTab" --force

# Export
./sheets.sh export <spreadsheetId> --format xlsx
./sheets.sh export <spreadsheetId> --format csv
```

## photos.sh

Calls the Google Photos Library REST API using gog OAuth tokens. Unlike other wrappers, this uses curl directly (gog has no native photos command).

**One-time setup** — re-authorize with photos scopes:
```sh
gog auth add edward.quail.claw@gmail.com \
  --extra-scopes "https://www.googleapis.com/auth/photoslibrary.readonly,https://www.googleapis.com/auth/photoslibrary" \
  --force-consent
```

```sh
# Browse
./photos.sh list --max 10 --json
./photos.sh search "sunset" --max 20 --json
./photos.sh get <mediaItemId> --json
./photos.sh download <mediaItemId> --out ./photo.jpg

# Albums
./photos.sh albums --json
./photos.sh album <albumId> --max 50 --json
./photos.sh create-album "Trip 2026"

# Upload
./photos.sh upload ./photo.jpg
./photos.sh upload ./photo.jpg --album <albumId>
```

## Patterns

**Pipe JSON to jq**
```sh
./gmail.sh search 'is:unread' --json --results-only | jq -r '.[].id'
```

**Collect IDs then batch-act**
```sh
ids=$(./gmail.sh search 'label:newsletters older_than:7d' --json --results-only | jq -r '.[].id')
./gmail.sh archive $ids
```

**Dry-run before a destructive action**
```sh
./drive.sh delete <fileId> --dry-run
./drive.sh delete <fileId> --force
```

**Non-interactive / CI**
```sh
./calendar.sh create primary --summary "Deploy" --from ... --to ... --no-input --json
```
