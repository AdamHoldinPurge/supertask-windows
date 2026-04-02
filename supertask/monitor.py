"""Tkinter status/monitor window for SuperTask™.

Displays real-time session information, activity logs, and provides
controls to stop or close the running loop engine.
"""

import os
import time
import re
import threading
import tkinter as tk
from tkinter import ttk, messagebox

from supertask.constants import APP_NAME, IS_WINDOWS
from supertask.process_manager import kill_process_tree


def _format_time(seconds):
    """Format a duration in seconds as HH:MM:SS."""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


class MonitorWindow(tk.Toplevel):
    """A Toplevel window that monitors a running LoopEngine session.

    Polls the loop engine and its log files every 3 seconds to display
    current status, session info, and activity log output.

    Args:
        parent: The root Tk window.
        config: Dict with keys work_dir, model, mode, num_variants,
                variant_presets, time_limit, config_dir.
        loop_engine: A running LoopEngine thread instance.
    """

    def __init__(self, parent, config, loop_engine):
        super().__init__(parent)

        self.parent = parent
        self.config = config
        self.loop_engine = loop_engine

        # Window setup
        work_dir_name = os.path.basename(config['work_dir'])
        self.title(f"{APP_NAME} \u2014 {work_dir_name}")
        self.geometry("500x550")
        self.minsize(450, 450)
        self.protocol("WM_DELETE_WINDOW", self._on_close)

        # Build the UI
        self._build_header()
        self._build_status_frame()
        self._build_info_frame()
        self._build_activity_frame()
        self._build_button_bar()

        # Start polling
        self.after(500, self._refresh)

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------

    def _build_header(self):
        """Header frame with app name and work directory path."""
        header = ttk.Frame(self)
        header.pack(fill=tk.X, padx=10, pady=(10, 5))

        title_label = ttk.Label(
            header, text=APP_NAME,
            font=("TkDefaultFont", 16, "bold"),
        )
        title_label.pack(anchor=tk.W)

        path_label = ttk.Label(
            header, text=self.config['work_dir'],
            font=("TkDefaultFont", 9),
            foreground="grey",
        )
        path_label.pack(anchor=tk.W)

    def _build_status_frame(self):
        """Status frame with status text and progress bar."""
        status_frame = ttk.LabelFrame(self, text="Status")
        status_frame.pack(fill=tk.X, padx=10, pady=5)

        self._status_var = tk.StringVar(value="Starting...")
        status_label = ttk.Label(
            status_frame, textvariable=self._status_var,
            font=("TkDefaultFont", 10),
        )
        status_label.pack(fill=tk.X, padx=8, pady=(6, 2))

        self._progress = ttk.Progressbar(
            status_frame, mode="indeterminate", length=300,
        )
        self._progress.pack(fill=tk.X, padx=8, pady=(2, 8))
        self._progress.start(20)

    def _build_info_frame(self):
        """Session info frame with a grid of key-value labels."""
        info_frame = ttk.LabelFrame(self, text="Session Info")
        info_frame.pack(fill=tk.X, padx=10, pady=5)

        # Define the info rows
        self._info_vars = {}
        rows = [
            ("Model:", self.config['model']),
            ("Mode:", self.config['mode']),
            ("Cycle:", "0"),
            ("Iterations:", "0"),
            ("Time elapsed:", "00:00:00"),
            ("Time remaining:", "Unlimited" if self.config['time_limit'] == 0 else "Calculating..."),
        ]

        # Add variant row if multi-variant
        if self.config['num_variants'] > 1:
            rows.append(("Current variant:", "..."))

        for i, (label_text, initial_value) in enumerate(rows):
            key_label = ttk.Label(
                info_frame, text=label_text,
                font=("TkDefaultFont", 9, "bold"),
            )
            key_label.grid(row=i, column=0, sticky=tk.W, padx=(8, 4), pady=2)

            var = tk.StringVar(value=initial_value)
            val_label = ttk.Label(
                info_frame, textvariable=var,
                font=("TkDefaultFont", 9),
            )
            val_label.grid(row=i, column=1, sticky=tk.W, padx=(4, 8), pady=2)

            self._info_vars[label_text] = var

        # Add some bottom padding to the frame
        info_frame.grid_columnconfigure(1, weight=1)

    def _build_activity_frame(self):
        """Activity log frame with a read-only text widget."""
        activity_frame = ttk.LabelFrame(self, text="Activity")
        activity_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)

        # Text widget with scrollbar
        text_frame = ttk.Frame(activity_frame)
        text_frame.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

        scrollbar = ttk.Scrollbar(text_frame, orient=tk.VERTICAL)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        self._activity_text = tk.Text(
            text_frame,
            height=12,
            wrap=tk.WORD,
            font=("Consolas", 9) if IS_WINDOWS else ("Courier", 9),
            state=tk.DISABLED,
            yscrollcommand=scrollbar.set,
            background="#1e1e1e",
            foreground="#d4d4d4",
            insertbackground="#d4d4d4",
            selectbackground="#264f78",
            borderwidth=1,
            relief=tk.SUNKEN,
        )
        self._activity_text.pack(fill=tk.BOTH, expand=True)
        scrollbar.config(command=self._activity_text.yview)

    def _build_button_bar(self):
        """Bottom button bar with Stop, Force Stop, and Close buttons."""
        btn_frame = ttk.Frame(self)
        btn_frame.pack(fill=tk.X, padx=10, pady=(5, 10))

        self._stop_btn = ttk.Button(
            btn_frame, text="Stop Gracefully",
            command=self._on_stop_gracefully,
        )
        self._stop_btn.pack(side=tk.LEFT, padx=(0, 5))

        self._force_stop_btn = ttk.Button(
            btn_frame, text="Force Stop",
            command=self._on_force_stop,
        )
        self._force_stop_btn.pack(side=tk.LEFT, padx=(0, 5))

        self._close_btn = ttk.Button(
            btn_frame, text="Close",
            command=self._on_close,
        )
        self._close_btn.pack(side=tk.RIGHT)

    # ------------------------------------------------------------------
    # Polling / refresh
    # ------------------------------------------------------------------

    def _refresh(self):
        """Poll the loop engine and update all display elements."""
        try:
            # 1. Read STATUS file
            status_text = self._read_status_file()
            if status_text:
                self._status_var.set(status_text)

            # 2. Update cycle/iteration counts
            self._info_vars["Cycle:"].set(str(self.loop_engine.cycle))
            self._info_vars["Iterations:"].set(str(self.loop_engine.total_iters))

            # 3. Calculate elapsed and remaining time
            elapsed = time.time() - self.loop_engine.start_time
            self._info_vars["Time elapsed:"].set(_format_time(elapsed))

            if self.loop_engine.time_limit == 0:
                self._info_vars["Time remaining:"].set("Unlimited")
            else:
                remaining = max(0, self.loop_engine.time_limit - elapsed)
                self._info_vars["Time remaining:"].set(_format_time(remaining))

            # 4. Read CURRENT_VARIANT if multi-variant
            if self.config['num_variants'] > 1:
                variant_text = self._read_current_variant()
                self._info_vars["Current variant:"].set(variant_text)

            # 5. Read loop.log and update activity text
            log_lines = self._read_loop_log()
            self._update_activity_text(log_lines)

            # 6. Check if loop engine is still alive
            if not self.loop_engine.is_alive():
                self._status_var.set("Stopped")
                self._progress.stop()
                self._stop_btn.configure(state=tk.DISABLED)

        except tk.TclError:
            # Window has been destroyed — stop refreshing
            return

        # 7. Re-schedule
        self.after(3000, self._refresh)

    # ------------------------------------------------------------------
    # File reading helpers
    # ------------------------------------------------------------------

    def _read_status_file(self):
        """Read the STATUS file from root_log_dir. Returns text or None."""
        try:
            status_path = self.loop_engine.root_log_dir / "STATUS"
            return status_path.read_text(encoding="utf-8").strip()
        except (FileNotFoundError, OSError):
            return None

    def _read_current_variant(self):
        """Read CURRENT_VARIANT file. Returns variant string or '...'."""
        try:
            variant_path = self.loop_engine.root_log_dir / "CURRENT_VARIANT"
            v_num = variant_path.read_text(encoding="utf-8").strip()
            # Try to show the preset name alongside the number
            try:
                v_int = int(v_num)
                if 1 <= v_int <= len(self.config['variant_presets']):
                    preset = self.config['variant_presets'][v_int - 1]
                    return f"{v_num} ({preset})"
            except (ValueError, IndexError):
                pass
            return v_num
        except (FileNotFoundError, OSError):
            return "..."

    def _read_loop_log(self):
        """Read the last 20 lines of loop.log. Returns a string."""
        try:
            log_path = self.loop_engine.root_log_dir / "loop.log"
            content = log_path.read_text(encoding="utf-8")
            lines = content.strip().splitlines()
            last_lines = lines[-20:]
            return "\n".join(last_lines)
        except (FileNotFoundError, OSError):
            return ""

    def _update_activity_text(self, text):
        """Replace the activity text widget content and scroll to bottom."""
        self._activity_text.configure(state=tk.NORMAL)
        self._activity_text.delete("1.0", tk.END)
        if text:
            self._activity_text.insert(tk.END, text)
        self._activity_text.see(tk.END)
        self._activity_text.configure(state=tk.DISABLED)

    # ------------------------------------------------------------------
    # Button handlers
    # ------------------------------------------------------------------

    def _on_stop_gracefully(self):
        """Request the loop engine to stop gracefully."""
        self.loop_engine.request_stop()
        self._stop_btn.configure(text="Stopping...", state=tk.DISABLED)
        self._status_var.set("Stop requested \u2014 finishing current task...")

    def _on_force_stop(self):
        """Force-kill the entire process tree after user confirmation."""
        confirmed = messagebox.askyesno(
            "Force Stop",
            "This will forcefully terminate all running processes.\n\n"
            "Any work in progress will be lost. Continue?",
            parent=self,
        )
        if confirmed:
            kill_process_tree(os.getpid())

    def _on_close(self):
        """Handle window close — warn if loop is still running."""
        if self.loop_engine.is_alive():
            result = messagebox.askyesno(
                "Loop Still Running",
                "The loop is still running. Stop it and close?",
                parent=self,
            )
            if result:
                self.loop_engine.request_stop()
                self.destroy()
            # If no, do nothing — keep window open
        else:
            self.destroy()


def show(parent, config, loop_engine):
    """Create and display a MonitorWindow.

    Args:
        parent: The root Tk window.
        config: Session configuration dict.
        loop_engine: The running LoopEngine instance.

    Returns:
        The MonitorWindow instance.
    """
    window = MonitorWindow(parent, config, loop_engine)
    window.lift()
    window.focus_force()
    return window
