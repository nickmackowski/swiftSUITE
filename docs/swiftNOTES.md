# swiftNOTES

swiftNOTES is an AES-256 encrypted personal notebook. Notes are stored locally and encrypted at rest — nobody can read them without your swiftCORE password. Beyond typing notes directly into the app, swiftNOTES can also capture notes (and calendar entries — see swiftCALENDAR) sent remotely by email or text, and supports due dates that surface automatically on swiftCALENDAR's month view.

<img width="2314" height="1688" alt="image" src="https://github.com/user-attachments/assets/9382c132-913b-47c1-9fc4-68a178cac81e" />


---

## What It Does

- Stores notes with a title, body, tags, and an optional due date
- Encrypts all note content using AES-256-GCM via Apple's CryptoKit
- Supports search by title, body, and tags
- Provides an archive for notes you want to keep but not see daily
- Backs up and restores the full notebook
- Captures notes sent remotely by email or text, from one or more configured inboxes
- Due dates show up automatically as reminders on swiftCALENDAR — no extra steps needed

---

## First-Time Setup

On first launch swiftNOTES automatically creates an encrypted notebook using your swiftCORE session key. No additional setup required — just start adding notes.

---

## Main Workspace

```
NOTEBOOK: 12 Notes Stored  [2 Archived]               ● AES-256 ENCRYPTED
Last Backup: 07/17/26 09:21                           ● All Notes Current
```
- **AES-256 ENCRYPTED** — always green, confirms all data is encrypted at rest using AES-256-GCM via Apple's CryptoKit.
- **All Notes Current** — backup is up to date. Changes since the last backup will update this indicator.
- While swiftNOTES checks your capture inbox(es) for new messages, this second line temporarily swaps to `Status: [ ⠋ ] Checking capture inbox...` with a live spinner. This check runs automatically every time you launch the app.

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
| `X` | Archive / unarchive selected note |
| `R` | Show or hide archived notes |
| `U` | Utilities menu |

### Note Detail Screen
| Key | Action |
|-----|--------|
| `E` | Edit note |
| `D` | Delete note permanently |
| `X` | Archive note (label switches to "Unarchive" if it's already archived) |
| `ESC` | Back to workspace |

Delete asks for confirmation (`y`/`n`) before doing anything permanent, on both screens.

---

## Adding a Note

Press `A` from the workspace. You will be prompted for:

1. **Title** — shown in the main list
2. **Tags** — separate with spaces or commas (e.g. `work project dell`)
3. **Due Date** — optional, `MM/DD/YY` format. If set, this note automatically shows up as a due-date reminder on swiftCALENDAR (see that app's own README for details)
4. **Body** — the full note content (multi-line supported)

The note is encrypted and saved immediately.

---

## Searching Notes

Press `/` to search. The search scans titles, body text, and tags. Results appear in a filtered list — navigate and open just like the main workspace.

---

## Archive

Notes you no longer need day-to-day but want to keep can be archived rather than deleted:

- Press `X` in the workspace or on the detail screen to archive a note (or unarchive it, if it's already archived — the footer label switches automatically)
- Archived notes are shown by default; press `R` in the workspace to hide them, press `R` again to show them
- The status line shows how many notes are in the archive at all times
- Delete works the same on archived notes as anywhere else — `D`, then confirm

---

## Remote Capture (Email & Text)

swiftNOTES can turn an email — or a text message forwarded to email — into a note automatically. This works through a "remote send inbox": a real email account you dedicate to this one purpose.

### Setting Up a Capture Inbox

**Create a new, dedicated email account for this** — don't use your everyday inbox. A free Gmail account works well and takes a minute to set up. Name it something recognizable, like:

```
rsend.yourname@gmail.com
```

You'll need an **app-specific password**, not your regular account password. Gmail (and most providers) require this for any app connecting via IMAP — it's a separate, revocable password generated specifically for this purpose, found under your account's security settings. swiftNOTES will prompt for this during setup and explains it right there, but generating it happens on the email provider's site first.

From swiftNOTES, go to **Utilities (`U`) → Manage Capture Accounts**, then press `A` to add one. You'll be asked for:

1. The inbox's email address
2. The IMAP host (auto-suggested for Gmail/Outlook/Yahoo/iCloud based on the address you enter)
3. The IMAP port (defaults to 993)
4. Whether to delete text-only messages from the inbox after they're captured, or keep them (see below)
5. The app-specific password

Type `esc` and press Enter (or press Escape and press Enter) at any of these prompts to cancel without saving anything.

**swiftNOTES supports more than one capture inbox** — add as many as you want, each with its own settings. Every configured inbox gets checked together on launch, and pressing `A` again from the account list adds another.

### Delete-After-Capture

Each inbox has its own setting for whether captured text-only messages get deleted automatically or kept (marked read and filed into a "Captured" label instead). Pick whichever fits how you're using that inbox — a fully dedicated throwaway inbox is usually safe to auto-delete from, while one you're repurposing might be worth always keeping.

**Anything with an attachment is always kept, never deleted, regardless of this setting.** Capture is text-only — an attachment is never actually pulled into the note, so deleting the original would make it permanently unrecoverable.

### Writing a Captured Note

Just send an email (or a text, forwarded to your capture address — see below) to your configured inbox. The subject becomes the note's title, and the body becomes the note's content, with two optional lines pulled out automatically:

```
Subject: n: Grocery list

Pick up milk, eggs, bread.

Tag: errands, personal
Due: 8/10/26
```

Start the subject with **`n:`** — this is the recommended convention, matching swiftCALENDAR's `c:` prefix for calendar entries, so the choice between "note" and "calendar event" is always explicit rather than implied. A subject with no prefix at all is still treated as a note too, kept for backward compatibility, but `n:` is the standard going forward and the one to actually use.

- **`Tag:`** — comma-separated tags, same idea as typing tags in-app. Not `[bracketed]` — that syntax used to be the way to do this, but was dropped because it's painful to reach on an iOS keyboard
- **`Due:`** — accepts `M/D`, `M/D/YY`, or `M/D/YYYY`. Same as setting a due date in-app, it'll show up on swiftCALENDAR automatically

Both lines are stripped out of the saved note body — only the actual content remains. Every captured note also gets tagged `rsend`, so you can always find everything that came in remotely by searching that tag.

### Texting a Note

If your phone can forward incoming texts to email (iOS Shortcuts' "Personal Automation" can do this), point that forward at your capture address and texted notes work exactly the same way — no extra setup on the swiftNOTES side.

### Calendar Entries, Not Just Notes

The same inbox and same pipeline can also create real calendar events in swiftCALENDAR — swap the `n:` prefix for **`c:`** instead. See swiftCALENDAR's own README for the full `c:` format — it's a different single-line date format from `Due:`, since a calendar event needs a specific time, not just a date.

---

## Utilities

Press `U` to access the utilities menu:

| Option | Description |
|--------|-------------|
| Backup Notebook Database | Creates a timestamped encrypted backup |
| Restore Notebook Database | Restores from a previous backup |
| Delete All Notes | Permanently wipes all notes |
| Manage Capture Accounts | Add, edit, or delete remote send inboxes (see above) |

Utilities screens don't show the app-switching nav footer — this is a deliberate, suite-wide convention for configuration/maintenance screens, not an oversight.

---

## Known Limitations

- **No live-updating clock in the header.** Like the rest of the suite, the time only refreshes on keystroke, not continuously. Known and deliberate, not specific to swiftNOTES.
- **Capture is text-only.** A message with an attachment is recognized and kept safely (never deleted), but the attachment itself is never pulled into the note — only the message text is captured.

---

## Tips

- Tags are powerful for filtering — use consistent tag names across notes (e.g. always `work` not sometimes `work` and sometimes `office`)
- The archive is a great place for completed projects, old reference notes, or anything you might want to search later but don't need to see every day
- Backups are encrypted with the same key as your notebook — keep them somewhere safe
- Search for `rsend` any time to see everything that's ever come in through remote capture, across every configured inbox
- If a due date isn't showing up on swiftCALENDAR after capturing a note, double check the `Due:` line parsed correctly — an unparseable date just gets skipped rather than guessed at
