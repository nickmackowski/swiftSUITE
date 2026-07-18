# swiftMAIL

swiftMAIL is a terminal-based IMAP/SMTP email client that supports multiple accounts, folder navigation, composing and replying to email, and contact lookup from swiftCONTACTS.

---

## What It Does

- Connects to any IMAP/SMTP email provider (Gmail, Outlook, iCloud, etc.)
- Supports multiple email accounts with TAB switching between them
- Fetches and displays email in a clean greenbar grid
- Composes and sends email via SMTP
- Looks up recipient names and addresses from swiftCONTACTS
- Auto-syncs every 15 minutes in the background

---

## Account Setup

Before using swiftMAIL you need to add at least one email account.

Press `A` from the main workspace to open Account Setup. You will need:

- **Account type** — currently supports Google (Gmail) and generic IMAP/SMTP
- **Email address**
- **IMAP server** and port (e.g. `imap.gmail.com:993`)
- **SMTP server** and port (e.g. `smtp.gmail.com:587`)
- **Password or App Password**

> **Gmail users:** Google requires an App Password rather than your regular account password. Generate one at myaccount.google.com → Security → App Passwords.

---

## Main Workspace

```
ACCOUNT: [1/2] nick@gmail.com ──► FOLDER: [ INBOX ] (23 Messages)
Status: [ Done ] Sync complete.
```

The grid shows message number, unread indicator (●), date, sender, and subject. Unread messages appear in bold.

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

### Contact Lookup

When entering a recipient address, swiftMAIL can look up names from your swiftCONTACTS database. Type a name or partial name and swiftMAIL will suggest matching contacts with their email addresses, so you never have to remember exact addresses.

This integration works automatically as long as swiftCONTACTS has been set up and contains contacts with email addresses.

---

## Multiple Accounts

If you have more than one email account configured, press `TAB` in the workspace to cycle between them. The account indicator at the top shows which account you are currently viewing:

```
ACCOUNT: [1/2] nick@gmail.com
ACCOUNT: [2/2] nick@outlook.com
```

Each account maintains its own folder and message list independently.

---

## Folder Navigation

Press `F` to switch folders within the current account. Common folders include Inbox, Sent, Drafts, Trash, and any custom folders you have created in your email provider.

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
| `T` | Toggle account enabled/disabled |
| `ESC` | Back to workspace |

---

## Tips

- Use App Passwords for Gmail and other providers that support two-factor authentication — regular passwords will be rejected
- The `W` key was chosen for Compose (Write) to keep `C` free for the Calendar nav key
- If a sync fails, check that your IMAP server settings and credentials are correct in Account Setup
- swiftMAIL stores messages locally after syncing — you can read previously fetched email without an internet connection
