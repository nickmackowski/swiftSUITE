# swiftMAIL

swiftMAIL is a terminal-based IMAP/SMTP email client that supports multiple accounts, folder navigation, composing and replying to email, and contact lookup from swiftCONTACTS.

<img width="2314" height="1688" alt="image" src="https://github.com/user-attachments/assets/bea6abad-f6a6-4cab-817d-9363011b030a" />


---

## What It Does

- Connects to any IMAP/SMTP email provider (Gmail, Yahoo, iCloud, Fastmail, or custom servers)
- Supports multiple email accounts with TAB switching between them
- Fetches and displays email in a clean greenbar grid
- Composes and sends email via SMTP
- Looks up recipient names and addresses from swiftCONTACTS
- Auto-syncs every 15 minutes in the background
- Automatically discovers each provider's real folder names (Sent/Trash/Junk/Drafts) instead of guessing

---

## A Real Limitation — Outlook / Hotmail / Live

**Outlook.com, Hotmail, and Live accounts cannot currently be used.** Microsoft disabled password-based (Basic Auth) login for these accounts in September 2024, and this app authenticates with a password/app-password — there's no way around that without implementing full OAuth2 "Modern Auth," which this app doesn't support yet. swiftMAIL will warn you about this directly if you enter an `@outlook.com`, `@hotmail.com`, or `@live.com` address during setup, before you waste time troubleshooting a connection that can't work. This is a Microsoft-side platform change, not a bug — Gmail, Yahoo, iCloud, and Fastmail are all unaffected and work normally.

---

## Account Setup

Before using swiftMAIL you need to add at least one email account.

Press `A` from the main workspace to open Account Setup. You will need:

- **Account type** — Gmail/Google Workspace, Yahoo, iCloud, Fastmail, or a custom IMAP/SMTP server
- **Email address**
- **IMAP server** and port (auto-filled for known providers; e.g. `imap.gmail.com:993`)
- **SMTP server** and port (auto-filled for known providers; e.g. `smtp.gmail.com:465`)
- **App-Specific Password** (see below)

> **App passwords are required, not your regular account password**, for any provider that supports two-factor authentication — which is effectively all of them today. Generate one from your provider's account security settings (for Gmail: myaccount.google.com → Security → App Passwords).

Type `esc` and press Enter (or press Escape and press Enter) at any prompt during setup to cancel without saving anything.

### Automatic Folder Discovery

After you enter your password, swiftMAIL connects and asks the server directly which real folder is Sent, Trash, Junk, and Drafts (via the IMAP SPECIAL-USE extension, supported by Gmail, Yahoo, Outlook, iCloud, and Fastmail), rather than guessing a folder name based on the provider. This is what makes providers like Yahoo — whose real folder names don't match the common guesses — work correctly. If a server doesn't support SPECIAL-USE, swiftMAIL falls back to listing every folder that actually exists and matching against common naming patterns. You'll see a brief confirmation ("Folder names verified against the server") or a warning if neither approach found anything, in which case folder paths can still be set manually.

---

## Main Workspace

```
ACCOUNT: [1/2] user@mail.com ──► FOLDER: [ INBOX ] (23 Messages)
Status: [ ⠋ ] Syncing...
```

The second line is a fixed-slot status indicator — while idle it shows the result of the last sync (`[ Done ]` or `[ Error ]` with a message); while actively syncing, it swaps to a live braille spinner. The grid shows message number, unread indicator (●), date, sender, and subject. Unread messages appear in bold.

---

## Key Shortcuts

### Workspace
| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate messages |
| `ENTER` or `1-9` | Read selected message |
| `R` | Sync / refresh |
| `TAB` | Switch to next account |
| `F` | Switch folder |
| `W` | Compose new email |
| `D` | Delete selected message |
| `A` | Account setup |

### Reading Pane
| Key | Action |
|-----|--------|
| `R` | Reply to message |
| `D` | Delete message |
| `ESC` | Back to workspace |

---

## Reading Email

Select a message with `↑`/`↓` and press `ENTER` or its number to open it. The reading pane shows:

```
From         sender@example.com
Subject      The email subject
Date         Jul 17, 2026 at 9:21 AM
────────────────────────────────────
Message body here...
```

From the reading pane, press `R` to reply or `D` to delete.

---

## Composing Email

Press `W` from the workspace to compose a new message. You will be prompted for:

1. **To** — recipient email address (see Contact Lookup below)
2. **Subject** — email subject line
3. **Body** — message body. Type your message and enter `DONE` on its own line when finished

A copy is saved to your Sent folder after sending — except on Gmail specifically, where Google's own server already saves a copy automatically on send, so swiftMAIL skips the extra step rather than create a duplicate.

### Contact Lookup

When entering a recipient address, swiftMAIL can look up names from your swiftCONTACTS database. Type a name or partial name and swiftMAIL will suggest matching contacts with their email addresses, so you never have to remember exact addresses.

This integration works automatically as long as swiftCONTACTS has been set up and contains contacts with email addresses.

---

## Multiple Accounts

If you have more than one email account configured, press `TAB` in the workspace to cycle between them. The account indicator at the top shows which account you are currently viewing:

```
ACCOUNT: [1/2] user@gmail.com
ACCOUNT: [2/2] user@yahoo.com
```

Each account maintains its own folder and message list independently.

---

## Folder Navigation

Press `F` to switch folders within the current account. Common folders include Inbox, Sent, Drafts, Trash, and any custom folders you have created in your email provider — the real names are discovered automatically per account (see [Automatic Folder Discovery](#automatic-folder-discovery) above), not assumed.

---

## Auto-Sync

swiftMAIL automatically syncs in the background every 15 minutes while the app is open. The status line shows when the last sync completed and whether new messages were received. Press `R` at any time for an immediate manual sync.

---

## Account Setup Screen

Press `A` from the workspace to manage accounts.

| Key | Action |
|-----|--------|
| `↑` / `↓` | Select account |
| `ENTER` | Edit selected account |
| `A` | Add new account |
| `D` | Delete selected account |
| `ESC` | Back to workspace |

---

## Tips

- Use App Passwords for Gmail and other providers that support two-factor authentication — regular passwords will be rejected
- Outlook, Hotmail, and Live accounts don't currently work — see [above](#a-real-limitation--outlook--hotmail--live) for why
- The `W` key was chosen for Compose (Write) to keep `C` free for the Calendar nav key
- If a folder doesn't seem to sync correctly on an unusual or self-hosted IMAP server, check whether automatic discovery found anything — you may need to enter that folder's path manually
- swiftMAIL stores messages locally after syncing — you can read previously fetched email without an internet connection
