# swiftVAULT

swiftVAULT is an AES-256 encrypted password manager. Credentials are stored locally and never leave your machine. All passwords are encrypted at rest and only decrypted when you explicitly view them.

---

## What It Does

- Stores service name, URL, username, password, notes, and 2FA flag per credential
- Encrypts passwords using AES-256-GCM via Apple's CryptoKit
- Detects and flags reused and weak passwords
- Supports bulk import from Chrome, Bitwarden, 1Password, and compatible CSV exports
- Exports a CSV template for backup or migration

---

## Main Workspace

```
VAULT: 8 Credentials Stored                           ● AES-256 ENCRYPTED
Last Backup: Never                                     ● 3 Reused
```

The grid shows credential number, a reuse / weak flag, service name, URL, and account name. Reused / weak passwords are highlighted to help you identify accounts that share the same password.

---

## Key Shortcuts

### Workspace
| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate credentials |
| `ENTER` or `1-9` | View credential detail |
| `A` | Add new credential |
| `/` | Search |
| `D` | Delete selected credential |
| `U` | Utilities menu |

### Credential Detail Screen
| Key | Action |
|-----|--------|
| `E` | Edit credential |
| `D` | Delete credential |
| `X` | Toggle password visibility (shown/hidden) |
| `ESC` | Back to workspace |

---

## Adding a Credential

Press `A` from the workspace. You will be prompted for:

1. **Service** — name of the site or app (e.g. `Google`)
2. **URL** — the login URL (e.g. `google.com`)
3. **Username** — your username or email address
4. **Password** — stored encrypted
5. **Notes** — any additional information
6. **2FA** — whether two-factor authentication is enabled (`y/n`)

---

## Password Health

swiftVAULT automatically analyzes your credentials and flags:

- **Reused** — the same password used across multiple services (shown as `R` in yellow)
- **Weak** — passwords that are short or lack complexity (shown as `W` in red)

The status line shows counts at a glance. Use this to prioritize which passwords to change first.

---

## Bulk Import

swiftVAULT can import credentials from a CSV file placed at `swiftVAULT/vault.csv`.

Supported column names:
- Service: `service`, `name`, `title`, `site`
- URL: `url`, `website`, `login_uri`, `link`
- Username: `username`, `login`, `email`, `user`
- Password: `password`, `login_password`, `pass`
- Notes: `notes`, `note`, `extra`
- 2FA: `2fa`, `totp`, `mfa`, `two_factor`

Duplicate detection skips any credential where the service and username already exist. After a successful import the CSV is automatically deleted.

---

## Export CSV Template

From Utilities, select **Export CSV Template** to export all credentials (including decrypted passwords) to `vault.csv`. This file contains plaintext passwords — handle it carefully and delete it after use.

---

## Utilities

| Option | Description |
|--------|-------------|
| Backup Vault | Creates a timestamped encrypted backup |
| Restore Vault | Restores from a previous backup |
| Export CSV Template | Exports all credentials to vault.csv |
| Bulk Import from CSV | Imports credentials from vault.csv |
| Delete All Credentials | Permanently wipes all credentials |

---

## Tips

- Never store vault.csv in a cloud-synced folder — it contains plaintext passwords
- The 2FA flag is a reminder only — swiftVAULT does not generate TOTP codes
- Use the reuse indicator regularly — password reuse is one of the most common security risks
