# swiftCONTACTS

swiftCONTACTS is an AES-256 encrypted personal contact manager. Contact details are stored locally and encrypted at rest. It integrates with swiftMAIL for name lookup when composing email, and with swiftCALENDAR for automatic birthday reminders.

<img width="989" height="611" alt="image" src="https://github.com/user-attachments/assets/69aa2a27-e6d9-480e-b34b-915adbe4dd7c" />

---

## What It Does

- Stores personal and professional contact details including name, phone, email, address, company, spouse, birthday, and tags
- Encrypts sensitive contact details using AES-256-GCM via Apple's CryptoKit
- Supports search by name, company, email, and tags
- Imports and exports contacts via CSV
- Integrates with swiftMAIL for contact lookup when composing
- Integrates with swiftCALENDAR to surface recurring birthday reminders automatically

---

## Main Workspace

```
CONTACTS: 24 Contacts Stored                          ● AES-256 ENCRYPTED
Last Backup: 07/17/26 09:21                           ● All Contacts Current
```
- **AES-256 ENCRYPTED** — always green, confirms all data is encrypted at rest using AES-256-GCM via Apple's CryptoKit.
- **All Contacts Current** — backup is up to date. Changes since the last backup will update this indicator.

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
Name              Account Name
Personal Email    account.name@rmail.com
Personal Phone    123-345-7890
Birthday          mm/dd/yyyy
Calendar B-day     mm/dd
Spouse            Spouse Name

Address           124 Any Street
                  Any Town, NC 12345

Company           Work
Work Email        account.name@work.com
Work Phone        123-456-7890

Tags              tag1, tag2, tag3
Last Modified     07/17/26 09:21 (today)
```

<img width="989" height="611" alt="image" src="https://github.com/user-attachments/assets/2b558254-529d-4bd0-b896-121589d9153e" />

---

## Adding a Contact

Press `A` from the workspace. You will be prompted for all contact fields. Only first name and last name are required — all other fields are optional and can be filled in later via Edit.

When you enter a date of birth, swiftCONTACTS automatically suggests the month/day for **Calendar B-day** (see below) — accept the suggestion by pressing Enter, or type a different month/day if needed.

---

## Two Birthday Fields, On Purpose

You'll notice two separate birthday-related rows in the contact detail view:

- **Birthday** — the full date of birth (month, day, and year), stored **encrypted** like the rest of a contact's sensitive details. Requires your master password to decrypt.
- **Calendar B-day** — just the month and day, no year, stored as **plaintext** — the same way a contact's name or email address is already stored in the clear.

This split exists specifically so swiftCALENDAR can compute recurring birthday reminders every time it launches, without ever needing your master password or decrypting anything. Only the month/day is exposed this way — the actual birth year stays fully encrypted in the regular Birthday field. If you're not using swiftCALENDAR's birthday overlay, this field simply goes unused; there's no downside to leaving it filled in either way.

---

## CSV Import and Export

### Export CSV Template

From Utilities, select **Export CSV Template** to export all contacts to `contacts.csv`. Column order:

```
FirstName, LastName, DOB, CalendarBDay, Spouse, Phone, PersonalEmail, Street, City, State, Zip, Company, WorkPhone, WorkEmail, Tags
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

## Integration with swiftCALENDAR

Every contact with a **Calendar B-day** set shows up as a recurring all-day birthday event on swiftCALENDAR's month view, computed fresh every time swiftCALENDAR launches — nothing is copied or duplicated into swiftCALENDAR's own files. See [swiftCALENDAR's documentation](swiftCALENDAR.md) for how the birthday overlay itself works.

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
- The full Birthday field is stored as free text so you can use any format you prefer (7/30/69, July 30, etc.) — Calendar B-day, by contrast, needs a real month/day to work with swiftCALENDAR
- If a birthday isn't showing up on swiftCALENDAR, double check Calendar B-day is actually filled in for that contact — having only the full (encrypted) Birthday field set isn't enough on its own
