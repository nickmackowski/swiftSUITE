# swiftBASE

A personal database app — define your own fields, keep as many separate databases as you want, and search across all of them at once. Architecturally modeled directly on swiftCONTACTS (same screen-stack navigation, workspace/search/card/edit flow), with two additions Contacts itself doesn't need: user-definable fields instead of a fixed schema, and the ability to hold multiple independent databases rather than just one.

---

## Concept

Where swiftCONTACTS has one fixed shape (name, company, email, phone) for every record, swiftBASE lets you define that shape yourself, per database. A "Camera Gear" database might have fields like Lens, Focal Length, and Purchase Price; a "Car Maintenance" database might have Vehicle, Work Performed, Shop Name, and Cost. Each database is fully independent — its own fields, its own records, its own field order and layout.

---

## Getting Started

On launch, swiftBASE shows every database you've created in a grid — name, record count, field count — with your cursor pre-positioned on whichever one you used last. Arrow up/down or type a number to open one, or press `[A]` to create your first one.

Creating a database asks for a name, then walks you through defining fields one at a time (leave the prompt blank when you're done adding fields). A database needs at least one field.

---

## Working with Records

Opening a database drops you into its workspace — a live table of records, using up to three of your defined fields as columns, with the same alternating-row and cursor-highlight styling used throughout the rest of the suite.

- **Arrow keys / number keys** — select or jump directly to a record
- **`[Enter]`** — open the selected record's full card view (every field, not just the three showing as table columns)
- **`[/]`** — search within this database only
- **`[A]`** — add a new record (prompts for each defined field in order)
- **`[M]`** — open the Modify menu for this database (see below)
- **`ESC`** — back to the all-databases screen

From a record's card view: `[E]` edits it (pre-filled prompts, leave blank to keep the current value), `[D]` deletes it.

---

## Global Search

Press `[/]` from the **all-databases** screen (not from inside a specific database) to search across every database at once. Results show which database each match came from, and selecting one opens the correct database directly on that record — no need to know in advance where something lives.

---

## Modify Menu

Reached via `[M]` from inside a database's workspace. Everything here is scoped to that one database:

- **Manage Fields** — rename fields (existing data is migrated to the new name automatically, not lost), reorder them with `+`/`-` (this order controls the card layout, table columns, and add/edit prompt order), add new fields, delete fields, insert blank-line spacers to visually group related fields on the card, and toggle individual fields to be hidden from the card view specifically (they stay fully present in the table, CSV export, and add/edit prompts either way)
- **Export CSV Template** — writes a header-only CSV file matching this database's current fields, ready to fill in externally
- **Import from CSV** — reads that same file back in as new records (proper quote-aware parsing, so a field value containing a comma — like a lens description — won't get misaligned)
- **Delete All Records** — clears every record in this database, with confirmation; field definitions are untouched

---

## Global Utilities

Reached via `[U]` from the all-databases screen — for concerns that span every database, not just one:

- **Backup Database(s)** — back up everything at once, or select a single database to back up individually
- **Restore Database(s)** — restore everything from a full-suite backup file, or restore a single database from one of its own backups

The all-databases screen's status line shows when the last full backup happened, so it's visible at a glance without digging into the menu.

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)

---

## Building

A core-style Swift Package project — plain `swiftc` + `lipo`, not Swift Package Manager, matching swiftCONTACTS/swiftNOTES/etc. rather than the GUI companion apps. Builds automatically as part of swiftADMIN's Build All Apps, or manually:

```bash
cd swiftBASE/source_code
swiftc -target arm64-apple-macosx14.0 scb.main.swift -o swiftBASE_arm64
swiftc -target x86_64-apple-macosx14.0 scb.main.swift -o swiftBASE_x86
lipo -create swiftBASE_arm64 swiftBASE_x86 -output swiftBASE
```

---

## A Note on Encryption

Unlike swiftNOTES, swiftVAULT, and swiftCONTACTS, swiftBASE does **not** encrypt its data at rest. Records are stored as plain JSON. This was a deliberate scope decision, not an oversight — but it's worth knowing plainly if you're storing anything sensitive.

---

Part of the [swiftSUITE](../README.md) collection.
