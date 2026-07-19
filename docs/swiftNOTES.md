# swiftNOTES

swiftNOTES is an AES-256 encrypted personal notebook. Notes are stored locally and encrypted at rest — nobody can read them without your swiftCORE password.

---

## What It Does

- Stores notes with a title, body, and tags
- Encrypts all note content using AES-256-GCM via Apple's CryptoKit
- Supports search by title, body, and tags
- Provides an archive for notes you want to keep but not see daily
- Backs up and restores the full notebook

---

## First-Time Setup

On first launch swiftNOTES automatically creates an encrypted notebook using your swiftCORE session key. No additional setup required — just start adding notes.

---

## Main Workspace

```
NOTEBOOK: 12 Notes Stored  [2 Archived]               ● AES-256 ENCRYPTED
Last Backup: 07/17/26 09:21                            ● All Notes Current
```

The grid shows note number, date modified, title, and tags. Notes are sorted by most recently modified.

---

## Key Shortcuts

### Workspace
| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate notes |
| `ENTER` or `1-9` | Open note |
| `A` | Add new note |
| `/` | Search |
| `D` | Delete selected note |
| `H` | Archive selected note |
| `I` | View archived notes |
| `U` | Utilities menu |

### Note Detail Screen
| Key | Action |
|-----|--------|
| `E` | Edit note |
| `D` | Delete note permanently |
| `V` | Archive note (or `R` to restore if already archived) |
| `ESC` | Back to workspace |

---

## Adding a Note

Press `A` from the workspace. You will be prompted for:

1. **Title** — shown in the main list
2. **Body** — the full note content (multi-line supported)
3. **Tags** — comma-separated (e.g. `work, project, dell`)

The note is encrypted and saved immediately.

---

## Searching Notes

Press `/` to search. The search scans titles, body text, and tags. Results appear in a filtered list — navigate and open just like the main workspace.

---

## Archive

Notes you no longer need day-to-day but want to keep can be archived rather than deleted:

- Press `H` in the workspace and on the detail screen to archive a note
- Archived notes disappear from the main view but are not deleted
- Press `I` to switch to the archived notes view
- From the archive, press `R` to restore a note to the main workspace or `D` to permanently delete it
- The status line shows how many notes are in the archive at all times

---

## Utilities

Press `U` to access the utilities menu:

| Option | Description |
|--------|-------------|
| Backup Notebook | Creates a timestamped encrypted backup |
| Restore Notebook | Restores from a previous backup |
| Export CSV | Exports note titles and tags (body stays encrypted) |
| Delete All Notes | Permanently wipes all notes |

---

## Tips

- Tags are powerful for filtering — use consistent tag names across notes (e.g. always `work` not sometimes `work` and sometimes `office`)
- The archive is a great place for completed projects, old reference notes, or anything you might want to search later but don't need to see every day
- Backups are encrypted with the same key as your notebook — keep them somewhere safe
