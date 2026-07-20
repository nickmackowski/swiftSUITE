#!/usr/bin/env python3
"""
swiftADMIN.py — swiftSUITE Administrative Toolkit v2.5
─────────────────────────────────────────────────────────
Handles builds, password management, data export/import,
and ttyd web terminal server management.

Place this script in:  swiftSUITE/swiftADMIN/swiftADMIN.py
Run from anywhere:     python3 /path/to/swiftADMIN.py
"""

from __future__ import annotations
import base64
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.progress import BarColumn, Progress, SpinnerColumn, TextColumn
from rich.prompt import Confirm, Prompt
from rich.table import Table
from rich.text import Text

# ── Constants ──────────────────────────────────────────────────────────────────
VERSION       = "2.5"
FIXED_WIDTH   = 68
LOGS_ROOT     = "swiftLOGS"
BUILD_LOG_DIR = "swiftBUILD"
MAX_LOGS      = 5
ADMIN_DIR     = ".swiftadmin"
PID_FILE      = ".swiftadmin/ttyd.pid"
CFG_FILE      = ".swiftadmin/config.json"

FALLBACK_PROJECTS = [
    ("swiftcalendar", "sccm.main.swift", "swiftCALENDAR"),
    ("swiftcontacts", "scc.main.swift",  "swiftCONTACTS"),
    ("swiftcore",     "scl.main.swift",  "swiftCORE"),
    ("swiftmail",     "scm.main.swift",  "swiftMAIL"),
    ("swiftnotes",    "scn.main.swift",  "swiftNOTES"),
    ("swiftstocks",   "scs.main.swift",  "swiftSTOCKS"),
    ("swiftvault",    "scv.main.swift",  "swiftVAULT"),
]

console = Console()


# ══════════════════════════════════════════════════════════════════════════════
# STARTUP — Auto-detect suite root so the script works from any directory
# ══════════════════════════════════════════════════════════════════════════════

def find_suite_root() -> Path:
    """
    swiftADMIN.py lives at:  <suite_root>/swiftADMIN/swiftADMIN.py
    The suite root is therefore two levels up from this file.
    """
    here = Path(__file__).resolve().parent
    # If we're inside swiftADMIN/, go up one level to suite root
    if here.name.lower() == "swiftadmin":
        return here.parent
    # Otherwise assume we're already at the suite root
    return here


SUITE_ROOT = find_suite_root()


def ensure_admin_dir():
    (SUITE_ROOT / ADMIN_DIR).mkdir(parents=True, exist_ok=True)


def load_config() -> dict:
    cfg_path = SUITE_ROOT / CFG_FILE
    if cfg_path.exists():
        try:
            return json.loads(cfg_path.read_text())
        except Exception:
            pass
    return {"ttyd_port": 7681, "ttyd_bind": "0.0.0.0"}


def save_config(cfg: dict):
    ensure_admin_dir()
    (SUITE_ROOT / CFG_FILE).write_text(json.dumps(cfg, indent=2))


# ══════════════════════════════════════════════════════════════════════════════
# SHARED HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def clear():
    os.system("clear")


def header(subtitle: str = ""):
    clear()
    title = Text(f"swiftADMIN v{VERSION}", style="bold cyan")
    if subtitle:
        title.append(f"  ›  {subtitle}", style="dim white")
    title.append(f"\nWorking Directory -> {os.getcwd()}", style="bold red")
    console.print(Panel(title, width=FIXED_WIDTH, border_style="cyan"))
    console.print()


def pause(msg: str = "Press Enter to continue..."):
    console.print(f"\n[dim]{msg}[/dim]")
    input()


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f}{unit}" if unit == "B" else f"{size:.1f}{unit}"
        size /= 1024


def notify(title: str, message: str):
    if sys.platform != "darwin":
        return
    try:
        subprocess.run(
            ["osascript", "-e", f'display notification "{message}" with title "{title}"'],
            capture_output=True, timeout=5,
        )
    except Exception:
        pass


# ══════════════════════════════════════════════════════════════════════════════
# MAIN MENU
# ══════════════════════════════════════════════════════════════════════════════

def main_menu():
    ensure_admin_dir()
    while True:
        header()

        menu = Table.grid(padding=(0, 2))
        menu.add_column(style="bold cyan", width=5)
        menu.add_column()

        menu.add_row("", "[bold dim]── BUILD ──────────────────────────────[/bold dim]")
        menu.add_row("[1]", "Build All Apps")
        menu.add_row("[2]", "Build Single App")
        menu.add_row("", "")
        menu.add_row("", "[bold dim]── SECURITY ────────────────────────────[/bold dim]")
        menu.add_row("[3]", "Change Master Password  [bold red]Coming in v3.0[/bold red]")
        menu.add_row("", "")
        menu.add_row("", "[bold dim]── DATA ────────────────────────────────[/bold dim]")
        menu.add_row("[4]", "Export All Data  [dim](plaintext backup)[/dim]")
        menu.add_row("[5]", "Import Data")
        menu.add_row("", "")
        menu.add_row("", "[bold dim]── TTYD WEB TERMINAL ───────────────────[/bold dim]")
        menu.add_row("[6]", "Start ttyd")
        menu.add_row("[7]", "ttyd Status")
        menu.add_row("[8]", "Stop ttyd")
        menu.add_row("", "")
        menu.add_row("", "[bold dim]── DANGER ZONE ─────────────────────────[/bold dim]")
        menu.add_row("[9]", "[bold red]Reset to Factory Defaults[/bold red]")
        menu.add_row("", "")
        menu.add_row("[Q]", "Quit")

        console.print(Panel(menu, width=FIXED_WIDTH, border_style="dim"))

        choice = Prompt.ask("[bold]Select[/bold]", default="q").strip().lower()

        if choice == "1":
            build_all()
        elif choice == "2":
            build_single()
        elif choice == "3":
            change_password()
        elif choice == "4":
            export_all_data()
        elif choice == "5":
            import_data()
        elif choice == "6":
            ttyd_start()
        elif choice == "7":
            ttyd_status()
        elif choice == "8":
            ttyd_stop()
        elif choice == "9":
            factory_reset()
        elif choice in ("q", "quit", "exit", ""):
            clear()
            console.print("[dim]swiftADMIN exited.[/dim]")
            sys.exit(0)
        else:
            console.print("[yellow]Unknown option — try again.[/yellow]")
            time.sleep(0.8)


# ══════════════════════════════════════════════════════════════════════════════
# BUILD — absorbed from build_all.py
# ══════════════════════════════════════════════════════════════════════════════

def discover_projects():
    """Scan the suite root for swift* project folders containing *.main.swift."""
    discovered = []
    try:
        entries = sorted(os.listdir(SUITE_ROOT))
    except OSError:
        return FALLBACK_PROJECTS

    for entry in entries:
        dir_path = SUITE_ROOT / entry
        if not dir_path.is_dir():
            continue
        # Skip swiftADMIN itself and swiftLOGS
        if entry.lower() in ("swiftadmin", "swiftlogs", ".swiftadmin"):
            continue
        try:
            swift_sources = sorted(f for f in os.listdir(dir_path) if f.endswith(".main.swift"))
        except OSError:
            continue
        if not swift_sources:
            continue
        source = swift_sources[0]
        binary = f"swift{entry[5:].upper()}" if entry.lower().startswith("swift") else entry.upper()
        discovered.append((entry, source, binary))

    return discovered if discovered else FALLBACK_PROJECTS


def check_toolchain() -> bool:
    missing = [t for t in ("swiftc", "lipo") if shutil.which(t) is None]
    if missing:
        console.print(f"[red]Missing required tool(s): {', '.join(missing)}[/red]")
        console.print("[dim]Install Xcode Command Line Tools: xcode-select --install[/dim]")
        return False
    return True


def log_timestamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


def prune_logs(directory: Path, keep: int):
    try:
        files = sorted(f for f in os.listdir(directory) if f.endswith(".log"))
        for old in files[:max(0, len(files) - keep)]:
            try:
                os.remove(directory / old)
            except OSError:
                pass
    except OSError:
        pass


def write_app_log(binary: str, content: str):
    log_dir = SUITE_ROOT / LOGS_ROOT / binary
    log_dir.mkdir(parents=True, exist_ok=True)
    (log_dir / f"{log_timestamp()}.log").write_text(content)
    prune_logs(log_dir, MAX_LOGS)


def write_build_summary(elapsed: int, selected, failed, warnings, sizes):
    lines = [
        f"Build run: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"Projects: {', '.join(b for _, _, b in selected)}",
        f"Completed in: {elapsed} seconds",
        "",
        "Result: ALL PROJECTS COMPILED SUCCESSFULLY" if not failed
            else f"Result: FAILED — {', '.join(failed)}",
    ]
    if warnings:
        lines += ["", "Warnings:"] + [f"  - {w}" for w in warnings]
    if sizes:
        lines += ["", "Binary sizes:"] + [f"  - {b}: {human_size(s)}" for b, s in sizes.items()]

    build_dir = SUITE_ROOT / LOGS_ROOT / BUILD_LOG_DIR
    build_dir.mkdir(parents=True, exist_ok=True)
    (build_dir / f"{log_timestamp()}.log").write_text("\n".join(lines) + "\n")
    prune_logs(build_dir, MAX_LOGS)


def build_one(dir_name: str, source: str, binary: str) -> dict:
    cwd = SUITE_ROOT / dir_name
    result = {"binary": binary, "ok": False, "warnings": 0, "error": None}
    log_lines = [
        f"Build started: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"Project: {binary} ({dir_name}/{source})",
        "",
    ]
    steps = [
        ["swiftc", "-target", "x86_64-apple-macosx14.0", source, "-o", f"{binary}_x86"],
        ["swiftc", "-target", "arm64-apple-macosx14.0",  source, "-o", f"{binary}_arm64"],
        ["lipo", "-create", f"{binary}_arm64", f"{binary}_x86", "-output", binary],
    ]
    try:
        for cmd in steps:
            proc = subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)
            log_lines.append(f"$ {' '.join(cmd)}")
            if proc.stdout: log_lines.append(proc.stdout.rstrip())
            if proc.stderr:
                log_lines.append(proc.stderr.rstrip())
                result["warnings"] += proc.stderr.lower().count("warning:")
            log_lines.append("")
        result["ok"] = True
        for tmp in (f"{binary}_x86", f"{binary}_arm64"):
            tmp_path = cwd / tmp
            if tmp_path.exists():
                tmp_path.unlink()
                log_lines.append(f"Removed intermediate: {tmp}")
        log_lines.append("Result: SUCCESS")
    except subprocess.CalledProcessError as e:
        log_lines.append(f"$ {' '.join(e.cmd)}")
        if e.stdout: log_lines.append(e.stdout.rstrip())
        if e.stderr: log_lines.append(e.stderr.rstrip())
        result["error"] = (e.stderr or "").strip() or f"exit code {e.returncode}"
        log_lines.append(f"\nResult: FAILED (exit code {e.returncode})")
    except FileNotFoundError as e:
        result["error"] = f"Command not found: {e.filename}"
        log_lines.append(f"Result: FAILED (missing tool: {e.filename})")

    write_app_log(binary, "\n".join(log_lines) + "\n")
    return result


def run_build(projects):
    """Shared build runner used by build_all and build_single."""
    if not check_toolchain():
        pause()
        return

    failed, warnings, errors, sizes = [], [], {}, {}
    start = time.time()
    jobs  = os.cpu_count() or 4

    progress = Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(bar_width=20),
        TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
    )
    task_ids = {
        d: progress.add_task(f"[white]{b:<18}[/white] queued", total=1)
        for d, _, b in projects
    }

    try:
        with Live(Panel(progress, title="Build Status", width=FIXED_WIDTH),
                  console=console, refresh_per_second=10):
            with ThreadPoolExecutor(max_workers=jobs) as pool:
                futures = {}
                for d, s, b in projects:
                    progress.update(task_ids[d], description=f"[yellow]{b:<18}[/yellow] building")
                    futures[pool.submit(build_one, d, s, b)] = (d, b)

                for future in as_completed(futures):
                    d, b = futures[future]
                    res  = future.result()
                    tid  = task_ids[d]
                    if res["ok"]:
                        progress.update(tid, description=f"[green]{b:<18}[/green] done", completed=1)
                        if res["warnings"]:
                            warnings.append(f"{b} ({res['warnings']} warnings)")
                        bp = SUITE_ROOT / d / b
                        if bp.exists():
                            sizes[b] = bp.stat().st_size
                    else:
                        progress.update(tid, description=f"[red]{b:<18}[/red] failed", completed=1)
                        failed.append(b)
                        errors[b] = res["error"]
    except KeyboardInterrupt:
        console.print("\n[red]Interrupted — waiting for in-flight steps...[/red]")
        return

    elapsed = int(time.time() - start)

    # Summary
    summary = Table.grid(expand=True)
    summary.add_column()
    summary.add_row(f"[bold]Completed in {elapsed}s[/bold]")
    if not failed:
        summary.add_row("[bold green]All projects compiled successfully.[/bold green]")
    else:
        summary.add_row(f"[bold red]Failed: {', '.join(failed)}[/bold red]")
    if warnings:
        summary.add_row("\n[yellow]WARNINGS:[/yellow]")
        for w in warnings: summary.add_row(f"  [white]·[/white] {w}")
    if sizes:
        summary.add_row("\n[cyan]Binary sizes:[/cyan]")
        for b, s in sizes.items(): summary.add_row(f"  [white]·[/white] {b}: {human_size(s)}")

    console.print(Panel(summary, title="BUILD SUMMARY", width=FIXED_WIDTH))

    if failed:
        console.print(f"[dim]See {LOGS_ROOT}/<app>/ for full compiler output.[/dim]")
        for b in failed:
            console.print(Panel(errors.get(b, "(no error captured)"),
                                title=f"{b} error", width=FIXED_WIDTH, border_style="red"))

    write_build_summary(elapsed, projects, failed, warnings, sizes)
    if failed:
        notify("swiftADMIN", f"{len(failed)} build(s) failed ({elapsed}s)")
    else:
        notify("swiftADMIN", f"All {len(projects)} app(s) built ({elapsed}s)")

    pause()


def build_all():
    header("Build All Apps")
    projects = discover_projects()
    if not projects:
        console.print("[red]No projects found.[/red]")
        pause()
        return
    console.print(f"Found [cyan]{len(projects)}[/cyan] project(s) in [dim]{SUITE_ROOT}[/dim]\n")
    run_build(projects)


def build_single():
    header("Build Single App")
    projects = discover_projects()
    if not projects:
        console.print("[red]No projects found.[/red]")
        pause()
        return

    menu = Table.grid(padding=(0, 2))
    menu.add_column(style="bold cyan", width=5)
    menu.add_column()
    for i, (_, _, b) in enumerate(projects, 1):
        menu.add_row(f"[{i}]", b)
    console.print(Panel(menu, title="Select App to Build", width=FIXED_WIDTH))

    choice = Prompt.ask("App number (or Q to cancel)", default="q").strip().lower()
    if choice == "q":
        return
    if choice.isdigit() and 1 <= int(choice) <= len(projects):
        run_build([projects[int(choice) - 1]])
    else:
        console.print("[yellow]Invalid selection.[/yellow]")
        pause()


# ══════════════════════════════════════════════════════════════════════════════
# SECURITY — Change Master Password
# ══════════════════════════════════════════════════════════════════════════════

def hash_password(password: str, salt_b64: str) -> str:
    """SHA-256 of salt_bytes + password_bytes — matches swiftCORE's hashPassword().
    Salt is stored as base64 in .core_credentials (not hex)."""
    salt = base64.b64decode(salt_b64)
    h = hashlib.sha256()
    h.update(salt)
    h.update(password.encode("utf-8"))
    return base64.b64encode(h.digest()).decode("utf-8")


def derive_session_key(password: str, salt_b64: str) -> bytes:
    """Matches swiftCORE deriveSessionKey(password:salt:) — v2.5 unified auth."""
    salt = base64.b64decode(salt_b64)
    h = hashlib.sha256()
    h.update(salt)
    h.update(password.encode("utf-8"))
    h.update(b"swiftCORE-unified-auth-v2.5")
    return h.digest()


def derive_app_key(skey: bytes, app_id: str) -> bytes:
    """Matches readCoreSessionKey app-specific derivation — SHA256(skey + appID)."""
    h = hashlib.sha256()
    h.update(skey)
    h.update(app_id.encode("utf-8"))
    return h.digest()


def aes_gcm_decrypt(ciphertext_b64: str, key: bytes) -> str:
    """AES-256-GCM decrypt matching Swift's AES.GCM — format: nonce(12) + ciphertext + tag(16)."""
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        data = base64.b64decode(ciphertext_b64)
        nonce, payload = data[:12], data[12:]
        return AESGCM(key).decrypt(nonce, payload, None).decode("utf-8")
    except Exception as e:
        raise ValueError(f"Decryption failed: {e}")


def aes_gcm_encrypt(plaintext: str, key: bytes) -> str:
    """AES-256-GCM encrypt matching Swift's AES.GCM — format: nonce(12) + ciphertext + tag(16)."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = os.urandom(12)
    payload = AESGCM(key).encrypt(nonce, plaintext.encode("utf-8"), None)
    return base64.b64encode(nonce + payload).decode("utf-8")


def reencrypt_field(val: str, old_key: bytes, new_key: bytes) -> str:
    """Decrypt with old key, re-encrypt with new key."""
    return aes_gcm_encrypt(aes_gcm_decrypt(val, old_key), new_key)


def reencrypt_app_data(suite_root: Path, old_pw: str, new_pw: str, salt_b64: str) -> list:
    """
    Re-encrypt notes, vault, and contacts data files with the new password.
    Returns list of (app, result_message) tuples.
    """
    old_skey = derive_session_key(old_pw, salt_b64)
    new_skey = derive_session_key(new_pw, salt_b64)
    results = []

    apps = [
        ("swiftNOTES",    "swiftNOTES",    "notes.json",    "swiftNOTES"),
        ("swiftVAULT",    "swiftVAULT",    "vault.json",    "swiftVAULT"),
        ("swiftCONTACTS", "swiftCONTACTS", "contacts.json", "swiftCONTACTS"),
    ]

    for dir_name, _, json_name, app_id in apps:
        # Try both case variants for the folder name
        json_path = suite_root / dir_name / json_name
        if not json_path.exists():
            json_path = suite_root / dir_name.lower() / json_name
        if not json_path.exists():
            results.append((dir_name, "skipped (file not found)"))
            continue

        old_key = derive_app_key(old_skey, app_id)
        new_key = derive_app_key(new_skey, app_id)

        try:
            raw = json_path.read_text()
            data = json.loads(raw)

            # Notes is wrapped in an outer array; vault/contacts are plain objects
            is_array = isinstance(data, list)
            obj = data[0] if is_array else data

            # Verify old key works before making any changes
            aes_gcm_decrypt(obj["canary"], old_key)

            # Re-encrypt canary
            obj["canary"] = reencrypt_field(obj["canary"], old_key, new_key)

            # Re-encrypt per-record encrypted fields
            count = 0
            if "notes" in obj:
                for note in obj["notes"]:
                    note["encryptedBody"] = reencrypt_field(note["encryptedBody"], old_key, new_key)
                    count += 1
            elif "credentials" in obj:
                for cred in obj["credentials"]:
                    cred["encryptedPassword"] = reencrypt_field(cred["encryptedPassword"], old_key, new_key)
                    count += 1
            elif "contacts" in obj:
                for contact in obj["contacts"]:
                    contact["encryptedDetails"] = reencrypt_field(contact["encryptedDetails"], old_key, new_key)
                    count += 1

            result = [obj] if is_array else obj
            json_path.write_text(json.dumps(result, separators=(",", ":")))
            results.append((dir_name, f"✓ re-encrypted ({count} record(s))"))

        except ValueError as e:
            results.append((dir_name, f"skipped — wrong key or not using unified auth ({e})"))
        except Exception as e:
            results.append((dir_name, f"error: {e}"))

    return results


def find_core_credentials() -> Path | None:
    """Locate the swiftCORE credentials file."""
    # Try common locations relative to suite root
    candidates = [
        SUITE_ROOT / "swiftcore" / ".core_credentials",
        SUITE_ROOT / "swiftCORE" / ".core_credentials",
        Path.home() / "Documents" / "Claude" / "swiftcore" / ".core_credentials",
        Path.home() / "Library" / "Application Support" / "swiftcore" / ".core_credentials",
    ]
    for c in candidates:
        if c.exists():
            return c
    # Scan suite root subfolders for .core_credentials
    for d in SUITE_ROOT.iterdir():
        p = d / ".core_credentials"
        if p.exists():
            return p
    return None


def change_password():
    header("Change Master Password")

    cred_file = find_core_credentials()
    if not cred_file:
        console.print("[red]Could not locate .core_credentials file.[/red]")
        console.print("[dim]Make sure you have logged into swiftCORE at least once.[/dim]")
        pause()
        return

    # Read credentials: username\tsalt_b64\thash_b64
    try:
        raw = cred_file.read_text().strip()
        parts = raw.split()  # handles tab or space separator
        if len(parts) != 3:
            raise ValueError(f"expected 3 parts, got {len(parts)}")
        username, salt_b64, stored_hash = parts
    except Exception as e:
        console.print(f"[red]Could not parse credentials file: {e}[/red]")
        pause()
        return

    console.print(f"Account: [cyan]{username}[/cyan]\n")

    # Verify current password
    import getpass
    current_pw = getpass.getpass(" Current password: ")
    if hash_password(current_pw, salt_b64) != stored_hash:
        console.print("\n[red]Incorrect current password.[/red]")
        pause()
        return

    console.print("[green]✓ Current password verified.[/green]\n")

    # Get new password
    new_pw = getpass.getpass(" New password: ")
    confirm_pw = getpass.getpass(" Confirm new password: ")

    if new_pw != confirm_pw:
        console.print("\n[red]Passwords do not match.[/red]")
        pause()
        return
    if len(new_pw) < 6:
        console.print("\n[red]Password must be at least 6 characters.[/red]")
        pause()
        return

    # Check if cryptography library is available for re-encryption
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        can_reencrypt = True
    except ImportError:
        can_reencrypt = False

    console.print()
    if can_reencrypt:
        console.print(Panel(
            "[green]swiftADMIN will automatically re-encrypt all your data\n"
            "(notes, vault, contacts) with the new password.\n\n"
            "[bold]Your data will be preserved — no manual steps needed.[/bold][/green]",
            title="✓  Seamless Re-encryption", width=FIXED_WIDTH, border_style="green"
        ))
    else:
        console.print(Panel(
            "[yellow]The 'cryptography' library is not installed.\n"
            "Data re-encryption will be skipped — notes, vault, and\n"
            "contacts will reset to empty on next login.\n\n"
            "Install it with: pip3 install cryptography[/yellow]",
            title="⚠  Re-encryption unavailable", width=FIXED_WIDTH, border_style="yellow"
        ))

    if not Confirm.ask("\n Proceed with password change?", default=False):
        console.print("[dim]Cancelled.[/dim]")
        pause()
        return

    # ── Step 1: Re-encrypt app data with new password (while we still have both) ──
    if can_reencrypt:
        console.print("\n[bold]Re-encrypting app data...[/bold]")
        results = reencrypt_app_data(SUITE_ROOT, current_pw, new_pw, salt_b64)
        for app, msg in results:
            color = "green" if msg.startswith("✓") else "yellow"
            console.print(f"  [{color}]{app}: {msg}[/{color}]")
    else:
        # Fallback: back up encrypted files at minimum
        backup_dir = SUITE_ROOT / f"swiftADMIN_pw_backup_{time.strftime('%Y%m%d_%H%M%S')}"
        backup_dir.mkdir(parents=True, exist_ok=True)
        for app_dir in sorted(SUITE_ROOT.iterdir()):
            if not app_dir.is_dir() or app_dir.name.startswith("."): continue
            for f_path in app_dir.iterdir():
                if f_path.suffix == ".json" and f_path.is_file():
                    try:
                        shutil.copy2(f_path, backup_dir / f"{app_dir.name}_{f_path.name}")
                    except Exception:
                        pass
        console.print(f"\n[dim]Encrypted backup saved to: {backup_dir.name}[/dim]")

    # ── Step 2: Write new credentials (same salt, new hash) ──
    new_hash = hash_password(new_pw, salt_b64)
    cred_file.write_text(f"{username}\t{salt_b64}\t{new_hash}")
    os.chmod(cred_file, 0o600)

    # ── Step 3: Update session with new skey so apps unlock immediately ──
    session_file = cred_file.parent / ".core_session"
    if session_file.exists() and can_reencrypt:
        new_skey = derive_session_key(new_pw, salt_b64)
        try:
            old_content = session_file.read_text()
            lines = [l for l in old_content.splitlines() if not l.startswith("skey:") and not l.startswith("expires:")]
            lines.insert(0, f"expires:{time.time() + 1800}")
            lines.append(f"skey:{base64.b64encode(new_skey).decode()}")
            session_file.write_text("\n".join(lines))
        except Exception:
            session_file.write_text("expires:0\nuser:\n")
    elif session_file.exists():
        session_file.write_text("expires:0\nuser:\n")

    console.print("\n[bold green]Password changed successfully.[/bold green]")
    if can_reencrypt:
        console.print("[dim]All app data re-encrypted with your new password.[/dim]")
        console.print("[dim]You can log in to swiftCORE immediately — no data loss.[/dim]")
    else:
        console.print("[dim]Log in to swiftCORE with your new password to re-initialize encrypted apps.[/dim]")
    pause()


# ══════════════════════════════════════════════════════════════════════════════
# DATA — Export / Import
# ══════════════════════════════════════════════════════════════════════════════

def find_app_data_dirs() -> dict:
    """Locate app data directories. Returns {app_name: path}."""
    app_dirs = {}
    # Scan suite root for app folders
    for d in sorted(SUITE_ROOT.iterdir()):
        if not d.is_dir():
            continue
        name = d.name.lower()
        for suffix in ("notes", "vault", "contacts", "mail", "stocks", "calendar"):
            if suffix in name:
                app_dirs[suffix] = d
    return app_dirs


def export_all_data():
    header("Export All Data")
    console.print("[yellow]This exports unencrypted plaintext copies of your app data.[/yellow]")
    console.print("[yellow]Handle the export files carefully and delete them when done.[/yellow]\n")

    export_dir = SUITE_ROOT / f"swiftADMIN_export_{time.strftime('%Y%m%d_%H%M%S')}"
    export_dir.mkdir(parents=True, exist_ok=True)

    console.print(f"Export directory: [cyan]{export_dir}[/cyan]\n")
    console.print("[dim]Note: vault.csv and contacts.csv export requires the apps to write them first.[/dim]")
    console.print("[dim]Use each app's Utilities → Export CSV Template, then run this to collect them.[/dim]\n")

    app_dirs = find_app_data_dirs()
    collected = []

    for app, data_dir in app_dirs.items():
        # Look for any .csv or .json backup files to collect
        for pattern in ("*.csv", "*.json", "*.backup"):
            for f in data_dir.glob(pattern):
                if "credentials" in f.name or "session" in f.name:
                    continue  # skip sensitive auth files
                dest = export_dir / f"{app}_{f.name}"
                try:
                    shutil.copy2(f, dest)
                    collected.append(f"{app}/{f.name}")
                    console.print(f"  [green]✓[/green] {app}/{f.name}")
                except Exception as e:
                    console.print(f"  [red]✗[/red] {app}/{f.name}: {e}")

    if collected:
        console.print(f"\n[bold green]{len(collected)} file(s) collected in {export_dir.name}[/bold green]")
    else:
        console.print("\n[yellow]No exportable files found.[/yellow]")
        console.print("[dim]Export CSV from each app's Utilities menu first.[/dim]")
        export_dir.rmdir()

    pause()


def import_data():
    header("Import Data")
    console.print("[dim]Place your CSV files in the appropriate app data folder, then use each[/dim]")
    console.print("[dim]app's Utilities → Bulk Import to import them.[/dim]")
    console.print("[dim]swiftADMIN handles builds and admin tasks; per-app import stays in the app.[/dim]")
    pause()


# ══════════════════════════════════════════════════════════════════════════════
# FACTORY RESET
# ══════════════════════════════════════════════════════════════════════════════

def factory_reset():
    header("Reset to Factory Defaults")

    console.print(Panel(
        "[red]This will permanently delete:[/red]\n"
        "  · swiftCORE login credentials\n"
        "  · All notes, vault credentials, and contacts\n"
        "  · Mail account configurations\n"
        "  · Stocks portfolio data\n"
        "  · Calendar sync data\n"
        "  · All session and backup files\n\n"
        "[bold]Binaries, source files, and logs are kept intact.[/bold]\n"
        "[bold]The suite will be ready for a fresh first-time setup.[/bold]",
        title="⚠  DANGER ZONE", width=FIXED_WIDTH, border_style="red"
    ))

    console.print("\n[bold red]Type RESET to confirm — this cannot be undone:[/bold red] ", end="")
    confirmation = input().strip()
    if confirmation != "RESET":
        console.print("\n[dim]Cancelled — nothing was changed.[/dim]")
        pause()
        return

    # Stop ttyd if running — can't leave it pointing at a wiped install
    pid = ttyd_pid()
    if pid:
        console.print("\n[yellow]Stopping ttyd before reset...[/yellow]")
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.5)
        except Exception:
            pass
        (SUITE_ROOT / PID_FILE).unlink(missing_ok=True)

    console.print()
    deleted = []
    failed  = []

    # Files and patterns to wipe — data only, never binaries or source
    DATA_EXTENSIONS  = {".json", ".backup", ".csv"}
    WIPE_NAMES       = {".core_credentials", ".core_session"}
    SKIP_DIRS        = {"swiftadmin", ".swiftadmin"}
    SKIP_EXTENSIONS  = {".swift", ".py", ".md", ".txt"}

    def try_delete(path: Path):
        try:
            path.unlink()
            deleted.append(str(path.relative_to(SUITE_ROOT)))
        except Exception as e:
            failed.append(f"{path.name}: {e}")

    for app_dir in sorted(SUITE_ROOT.iterdir()):
        if not app_dir.is_dir():
            continue
        if app_dir.name.lower() in SKIP_DIRS:
            continue

        for f_path in sorted(app_dir.iterdir()):
            if not f_path.is_file():
                continue
            if f_path.suffix in SKIP_EXTENSIONS:
                continue
            # Delete by name (auth files) or by extension (data files)
            if f_path.name in WIPE_NAMES or f_path.suffix in DATA_EXTENSIONS:
                try_delete(f_path)

    # Wipe swiftLOGS directory entirely
    logs_dir = SUITE_ROOT / LOGS_ROOT
    if logs_dir.exists():
        try:
            shutil.rmtree(logs_dir)
            deleted.append("swiftLOGS/ (entire directory)")
        except Exception as e:
            failed.append(f"swiftLOGS/: {e}")

    # Also wipe the swiftADMIN config (port settings etc) for a true clean slate
    cfg_path = SUITE_ROOT / CFG_FILE
    if cfg_path.exists():
        try_delete(cfg_path)

    # Report
    if deleted:
        console.print(f"[bold green]✓ Deleted {len(deleted)} file(s):[/bold green]")
        for name in deleted:
            console.print(f"  [dim]· {name}[/dim]")
    else:
        console.print("[dim]No data files found — suite was already clean.[/dim]")

    if failed:
        console.print(f"\n[yellow]Could not delete {len(failed)} file(s):[/yellow]")
        for msg in failed:
            console.print(f"  [red]· {msg}[/red]")

    console.print("\n[bold green]Factory reset complete.[/bold green]")
    console.print("[dim]Launch swiftCORE to begin first-time setup.[/dim]")
    notify("swiftADMIN", "Factory reset complete — suite ready for fresh setup")
    pause()




def ttyd_pid() -> int | None:
    """Return running ttyd PID or None."""
    pid_path = SUITE_ROOT / PID_FILE
    if not pid_path.exists():
        return None
    try:
        pid = int(pid_path.read_text().strip())
        # Check if process is actually running
        os.kill(pid, 0)
        return pid
    except (ValueError, ProcessLookupError, PermissionError):
        pid_path.unlink(missing_ok=True)
        return None


def ttyd_binary() -> str | None:
    return shutil.which("ttyd")


def ttyd_start():
    header("Start ttyd")
    cfg = load_config()

    if not ttyd_binary():
        console.print("[red]ttyd not found.[/red] Install it with: [cyan]brew install ttyd[/cyan]")
        pause()
        return

    existing_pid = ttyd_pid()
    if existing_pid:
        console.print(f"[yellow]ttyd is already running[/yellow] (PID {existing_pid})")
        console.print(f"[dim]Access: http://100.x.x.x:{cfg['ttyd_port']}[/dim]")
        pause()
        return

    # Find swiftCORE binary
    core_binary = SUITE_ROOT / "swiftCORE" / "swiftCORE"
    if not core_binary.exists():
        # Try lowercase
        core_binary = SUITE_ROOT / "swiftcore" / "swiftCORE"
    if not core_binary.exists():
        console.print("[red]swiftCORE binary not found.[/red] Build it first via option [2].")
        pause()
        return

    port = cfg.get("ttyd_port", 7681)

    # Allow port config
    new_port = Prompt.ask(f"Port", default=str(port))
    try:
        port = int(new_port)
        cfg["ttyd_port"] = port
        save_config(cfg)
    except ValueError:
        console.print("[yellow]Invalid port — using default 7681.[/yellow]")
        port = 7681

    console.print(f"\nStarting ttyd on port [cyan]{port}[/cyan]...")
    console.print(f"Binary: [dim]{core_binary}[/dim]\n")

    try:
        proc = subprocess.Popen(
            ["ttyd", "-p", str(port), "--writable", str(core_binary)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        time.sleep(1.5)  # Give ttyd a moment to start

        if proc.poll() is not None:
            console.print("[red]ttyd failed to start. Check that port is available.[/red]")
            console.print(f"[dim]Try: lsof -i :{port}  to see what's using the port.[/dim]")
        else:
            ensure_admin_dir()
            (SUITE_ROOT / PID_FILE).write_text(str(proc.pid))
            console.print(f"[bold green]✓ ttyd started[/bold green] (PID {proc.pid})")
            console.print(f"\n[cyan]Access swiftCORE in any browser on your Tailscale network:[/cyan]")
            console.print(f"  http://100.x.x.x:{port}")
            console.print(f"\n[dim]Use option [8] to stop ttyd when done.[/dim]")
            notify("swiftADMIN", f"ttyd started on port {port}")
    except FileNotFoundError:
        console.print("[red]ttyd not found in PATH.[/red]")

    pause()


def ttyd_status():
    header("ttyd Status")

    binary = ttyd_binary()
    pid = ttyd_pid()
    cfg = load_config()
    port = cfg.get("ttyd_port", 7681)

    status_table = Table.grid(padding=(0, 2))
    status_table.add_column(style="dim", width=18)
    status_table.add_column()

    status_table.add_row("ttyd installed:",
        f"[green]Yes[/green] ({binary})" if binary else "[red]No[/red] — brew install ttyd")
    status_table.add_row("Status:",
        f"[green]Running[/green] (PID {pid})" if pid else "[red]Not running[/red]")
    status_table.add_row("Port:", str(port))

    if pid:
        # Try to get process start time
        try:
            result = subprocess.run(["ps", "-p", str(pid), "-o", "etime="],
                                    capture_output=True, text=True)
            uptime = result.stdout.strip()
            if uptime:
                status_table.add_row("Uptime:", uptime)
        except Exception:
            pass
        status_table.add_row("Access:", f"http://100.x.x.x:{port}")

    console.print(Panel(status_table, title="ttyd Status", width=FIXED_WIDTH))

    if pid:
        console.print("\n[dim]Press [8] from the main menu to stop ttyd.[/dim]")

    pause()


def ttyd_stop():
    header("Stop ttyd")

    pid = ttyd_pid()
    if not pid:
        console.print("[yellow]ttyd is not running (no PID file found).[/yellow]")
        # Try killing any ttyd process by name as fallback
        try:
            result = subprocess.run(["pgrep", "ttyd"], capture_output=True, text=True)
            if result.stdout.strip():
                if Confirm.ask("Found a ttyd process not tracked by swiftADMIN — kill it?", default=False):
                    subprocess.run(["pkill", "ttyd"])
                    console.print("[green]ttyd process killed.[/green]")
        except Exception:
            pass
        pause()
        return

    console.print(f"Stopping ttyd (PID {pid})...")
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.5)
        # Check if still running, force kill if needed
        try:
            os.kill(pid, 0)
            os.kill(pid, signal.SIGKILL)
            console.print("[yellow]SIGTERM ignored — sent SIGKILL.[/yellow]")
        except ProcessLookupError:
            pass  # Process already gone, good
        (SUITE_ROOT / PID_FILE).unlink(missing_ok=True)
        console.print("[bold green]✓ ttyd stopped.[/bold green]")
        notify("swiftADMIN", "ttyd stopped")
    except ProcessLookupError:
        console.print("[yellow]Process was already gone — cleaning up PID file.[/yellow]")
        (SUITE_ROOT / PID_FILE).unlink(missing_ok=True)
    except PermissionError:
        console.print("[red]Permission denied — try running with sudo.[/red]")

    pause()


# ══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    # Change to suite root so all relative paths work correctly
    os.chdir(SUITE_ROOT)
    try:
        main_menu()
    except KeyboardInterrupt:
        clear()
        console.print("[dim]swiftADMIN exited.[/dim]")
        sys.exit(0)