# swiftCONTACTS

swiftCONTACTS is an AES-256 encrypted personal contact manager. Contact details are stored locally and encrypted at rest. It integrates with swiftMAIL for name lookup when composing email.

---

## What It Does

- Stores personal and professional contact details including name, phone, email, address, company, spouse, birthday, and tags
- Encrypts sensitive contact details using AES-256-GCM via Apple's CryptoKit
- Supports search by name, company, email, and tags
- Imports and exports contacts via CSV
- Integrates with swiftMAIL for contact lookup when composing

---

## Main Workspace

```
CONTACTS: 24 Contacts Stored                          ● AES-256 ENCRYPTED
Last Backup: 07/17/26 09:21                           ● All Contacts Current
```
- ● AES-256 ENCRYPTED** — always green, confirms all data is encrypted at rest using AES-256-GCM via Apple's CryptoKit.
- ● All Contacts Current** — backup is up to date. Changes since the last backup will update this indicator.

The grid shows contact number, name, company, and tags.

---

## Key Shortcuts

### Workspace
| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate contacts |
| `ENTER` or `1-9` | View contact detail |
| `A` | Add new contact |
| `/` | Search |
| `D` | Delete selected contact |
| `U` | Utilities menu |

### Contact Detail Screen
| Key | Action |
|-----|--------|
| `E` | Edit contact |
| `D` | Delete contact |
| `ESC` | Back to workspace |

---

## Contact Detail Layout

Contact details are grouped into logical blocks for easy reading:

```
Name              First Last
Personal Email    user@email.com
Personal Phone    123-345-7890
Birthday          mm/dd/yyyy
Spouse            Spouse Name

Address           124 Any Street
                  Any Town, NC 12345

Company           Company Name
Work Email        Company Email
Work Phone        123-456-7890

Tags              tag1, tag2, tag3
Last Modified     07/17/26 09:21 (today)
```

---

## Adding a Contact

Press `A` from the workspace. You will be prompted for all contact fields. Only first name and last name are required — all other fields are optional and can be filled in later via Edit.

---

## CSV Import and Export

### Export CSV Template

From Utilities, select **Export CSV Template** to export all contacts to `contacts.csv`. Column order:

```
FirstName, LastName, DOB, Spouse, Phone, PersonalEmail, Street, City, State, Zip, Company, WorkPhone, WorkEmail, Tags
```

### Import from CSV

Place a `contacts.csv` file in the `swiftCONTACTS` app folder and select **Import from CSV** from the Utilities menu. The importer:

- Skips any contact where the same first name and last name already exist
- Reports how many were imported and how many were skipped
- Automatically deletes `contacts.csv` after a successful import

---

## Integration with swiftMAIL

When composing an email in swiftMAIL, you can look up contact names from your swiftCONTACTS database to auto-fill recipient addresses. See the [swiftMAIL documentation](swiftMAIL.md) for details.

---

## Utilities

| Option | Description |
|--------|-------------|
| Backup Contacts | Creates a timestamped encrypted backup |
| Restore Contacts | Restores from a previous backup |
| Export CSV Template | Exports all contacts to contacts.csv |
| Import from CSV | Imports contacts from contacts.csv |
| Delete All Contacts | Permanently wipes all contacts |

---

## Tips

- Tags are shared across the suite — use consistent naming so contacts are easy to filter
- The spouse field is useful for household mailings or gift tracking
- Birthday is stored as free text so you can use any format you prefer (7/30/69, July 30, etc.)
