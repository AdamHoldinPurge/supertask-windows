"""SuperTask™ — entry point."""

import sys
import os
import tkinter as tk
import tkinter.messagebox

try:
    from tkinterdnd2 import TkinterDnD
    HAS_DND = True
except ImportError:
    HAS_DND = False

from .constants import APP_NAME, ICON_PATH, find_claude_cli
from .config_dialog import ConfigDialog
from .launcher import launch
from .monitor import MonitorWindow


def main():
    # ── 1. Check for Claude CLI ──────────────────────────────────────
    cli_path = find_claude_cli()
    if cli_path is None:
        _root = tk.Tk()
        _root.withdraw()
        tk.messagebox.showerror(
            "Claude CLI Not Found",
            "SuperTask\u2122 requires the Claude Code CLI.\n\n"
            "Install it with:\n  npm install -g @anthropic-ai/claude-code\n\n"
            "Then restart SuperTask\u2122.",
        )
        _root.destroy()
        sys.exit(1)

    # ── 2. Create root window ────────────────────────────────────────
    root = TkinterDnD.Tk() if HAS_DND else tk.Tk()
    root.title(APP_NAME)

    try:
        icon = tk.PhotoImage(file=ICON_PATH)
        root.iconphoto(True, icon)
    except Exception:
        pass  # PNG icon not available — skip silently

    root.withdraw()

    # ── 3. Show config dialog ────────────────────────────────────────
    dialog = ConfigDialog(root)
    config = dialog.show()

    if config is None:
        root.destroy()
        sys.exit(0)

    # ── 4. Launch ────────────────────────────────────────────────────
    engine = launch(root, config)

    if engine is None:
        root.destroy()
        sys.exit(0)

    # ── 5. Show monitor ─────────────────────────────────────────────
    monitor = MonitorWindow(root, config, engine)

    # Wrap the monitor's close handler so it also quits the mainloop
    _original_on_close = monitor._on_close

    def _close_and_quit():
        _original_on_close()
        # If the monitor was destroyed (user confirmed or loop was stopped),
        # quit the mainloop so the process exits cleanly
        if not monitor.winfo_exists():
            root.quit()

    monitor.protocol("WM_DELETE_WINDOW", _close_and_quit)
    root.mainloop()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        try:
            _err_root = tk.Tk()
            _err_root.withdraw()
            tk.messagebox.showerror(
                "SuperTask\u2122 — Unhandled Error",
                f"{type(exc).__name__}: {exc}",
            )
            _err_root.destroy()
        except Exception:
            pass
        sys.exit(1)
