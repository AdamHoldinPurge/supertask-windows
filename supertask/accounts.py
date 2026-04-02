"""Multi-account management for SuperTask™."""
import os
import sys
import json
import subprocess
from pathlib import Path
from .constants import (ACCOUNTS_FILE, ACCOUNTS_DIR, CONFIG_BASE,
                        DEFAULT_CLAUDE_CONFIG, IS_WINDOWS, find_claude_cli)


def get_accounts():
    """Get all configured Claude accounts.

    First checks the default config dir, then reads accounts.json for
    additional accounts. For each, runs `claude auth status --json` with
    CLAUDE_CONFIG_DIR set to verify the account.

    Returns:
        List of (email, plan, config_dir) tuples for all working accounts.
    """
    accounts = []
    claude_cli = find_claude_cli()
    if not claude_cli:
        return accounts

    # Check default config dir first
    default_account = _probe_account(claude_cli, DEFAULT_CLAUDE_CONFIG)
    if default_account:
        accounts.append(default_account)

    # Check additional accounts from accounts.json
    saved = _read_accounts_file()
    for entry in saved:
        config_dir = entry.get("config_dir", "")
        if not config_dir or config_dir == DEFAULT_CLAUDE_CONFIG:
            continue
        account = _probe_account(claude_cli, config_dir)
        if account:
            accounts.append(account)

    return accounts


def _probe_account(claude_cli, config_dir):
    """Run claude auth status --json for a given config dir.

    Returns:
        Tuple of (email, plan, config_dir) or None if the probe fails.
    """
    try:
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(config_dir)
        kwargs = {}
        if IS_WINDOWS:
            kwargs['creationflags'] = subprocess.CREATE_NO_WINDOW

        result = subprocess.run(
            [claude_cli, "auth", "status", "--json"],
            capture_output=True,
            text=True,
            encoding='utf-8',
            timeout=15,
            env=env,
            **kwargs,
        )
        if result.returncode != 0:
            return None
        data = json.loads(result.stdout.strip())
        email = data.get("email", data.get("account", "unknown"))
        plan = data.get("plan", data.get("subscription", "unknown"))
        return (email, plan, config_dir)
    except Exception:
        return None


def find_next_slot():
    """Find the lowest unused account slot number (1-20).

    Returns:
        Integer slot number, or None if all 20 slots are occupied.
    """
    saved = _read_accounts_file()
    used_slots = {entry.get("slot") for entry in saved}
    for slot in range(1, 21):
        if slot not in used_slots:
            return slot
    return None


def save_account(slot, email, plan, config_dir):
    """Save an account entry to accounts.json.

    Creates ACCOUNTS_DIR if needed. Removes any existing entry with the
    same slot before appending the new one. Sorts by slot and writes back.

    Args:
        slot: Integer slot number (1-20).
        email: Account email address.
        plan: Subscription plan name.
        config_dir: Path to the CLAUDE_CONFIG_DIR for this account.
    """
    ACCOUNTS_DIR.mkdir(parents=True, exist_ok=True)

    saved = _read_accounts_file()

    # Remove any existing entry with the same slot
    saved = [entry for entry in saved if entry.get("slot") != slot]

    # Append the new entry
    saved.append({
        "slot": slot,
        "email": email,
        "plan": plan,
        "config_dir": str(config_dir),
    })

    # Sort by slot number
    saved.sort(key=lambda e: e.get("slot", 0))

    # Write back
    ACCOUNTS_FILE.write_text(json.dumps(saved, indent=2), encoding='utf-8')


def login_new_account(slot):
    """Prepare a config directory for a new account login.

    Creates the config dir CONFIG_BASE-{slot} and symlinks settings files
    from the default config directory. The actual terminal spawning for
    the interactive login is handled by the UI layer.

    Args:
        slot: Integer slot number (1-20).

    Returns:
        Path string to the new config directory.
    """
    config_dir = Path(f"{CONFIG_BASE}-{slot}")
    config_dir.mkdir(parents=True, exist_ok=True)

    # Symlink settings files from the default config
    default_config = Path(DEFAULT_CLAUDE_CONFIG)
    settings_files = ["settings.json", "settings.local.json"]
    for filename in settings_files:
        src = default_config / filename
        dst = config_dir / filename
        if src.exists() and not dst.exists():
            try:
                dst.symlink_to(src)
            except OSError:
                # On Windows, symlinks may require elevated privileges;
                # fall back to copying the file
                import shutil
                shutil.copy2(str(src), str(dst))

    return str(config_dir)


def get_login_command(config_dir):
    """Get the shell command string to run claude auth login.

    On Windows: set CLAUDE_CONFIG_DIR={dir} && claude auth login
    On Linux:   CLAUDE_CONFIG_DIR='{dir}' claude auth login

    Args:
        config_dir: Path to the CLAUDE_CONFIG_DIR to use.

    Returns:
        Shell command string ready to execute in a terminal.
    """
    if IS_WINDOWS:
        return f"set CLAUDE_CONFIG_DIR={config_dir} && claude auth login"
    else:
        return f"CLAUDE_CONFIG_DIR='{config_dir}' claude auth login"


def _read_accounts_file():
    """Read and parse accounts.json. Returns list of dicts, or [] on error."""
    try:
        if ACCOUNTS_FILE.exists():
            return json.loads(ACCOUNTS_FILE.read_text(encoding='utf-8'))
    except (json.JSONDecodeError, OSError):
        pass
    return []
