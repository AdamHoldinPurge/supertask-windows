"""Main Tkinter configuration dialog for SuperTask™."""
import os
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

from .constants import (
    MODEL_OPTIONS, MODE_OPTIONS, MAX_CYCLES_OPTIONS, MAX_ITERS_OPTIONS,
    TIME_LIMIT_OPTIONS, TIME_LIMIT_MAP, ICON_PATH,
)
from .accounts import (
    get_accounts, login_new_account, find_next_slot,
    get_login_command, save_account,
)
from .preset_picker import pick_preset
from .website_brief import WebsiteBriefDialog


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_FONT = ("Segoe UI", 9)
_FONT_BOLD = ("Segoe UI", 9, "bold")
_FONT_HINT = ("Segoe UI", 8)
_PAD_X = 12
_PAD_Y = 4

_ADD_ACCOUNT_LABEL = "+ Add Account\u2026"


class ConfigDialog(tk.Toplevel):
    """Modal configuration dialog for launching a SuperTask session."""

    def __init__(self, parent):
        super().__init__(parent)
        self.title("SuperTask\u2122 \u2014 Configure Launch")
        self.geometry("520x680")
        self.resizable(False, True)
        self.transient(parent)

        # Set icon if available
        try:
            if os.path.isfile(ICON_PATH):
                self._icon_img = tk.PhotoImage(file=ICON_PATH)
                self.iconphoto(False, self._icon_img)
        except Exception:
            pass

        self.result = None

        # Internal state
        self._accounts = []          # list of (email, plan, config_dir)
        self._website_brief = None   # dict or None

        # Build the UI
        self._build_ui()

        # Populate accounts
        self._refresh_accounts()

        # Ensure the window is mapped before grabbing
        self.update_idletasks()
        self.deiconify()
        self.wait_visibility()
        self.grab_set()
        self.focus_set()

        # Centre on screen (parent is withdrawn)
        self.update_idletasks()
        sw = self.winfo_screenwidth()
        sh = self.winfo_screenheight()
        w = self.winfo_width()
        h = self.winfo_height()
        x = (sw - w) // 2
        y = (sh - h) // 2
        self.geometry(f"+{max(0, x)}+{max(0, y)}")

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------

    def _build_ui(self):
        """Lay out all widgets using grid inside a scrollable frame."""
        # Outer container with canvas for scrolling on small screens
        outer = ttk.Frame(self)
        outer.pack(fill="both", expand=True)

        canvas = tk.Canvas(outer, highlightthickness=0)
        scrollbar = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        self._form = ttk.Frame(canvas)

        self._form.bind(
            "<Configure>",
            lambda e: canvas.configure(scrollregion=canvas.bbox("all")),
        )
        self._canvas_window = canvas.create_window(
            (0, 0), window=self._form, anchor="nw",
        )
        canvas.configure(yscrollcommand=scrollbar.set)
        canvas.bind(
            "<Configure>",
            lambda e: canvas.itemconfigure(self._canvas_window, width=e.width),
        )

        # Mousewheel
        def _mw(event):
            canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

        def _mw_linux(event):
            if event.num == 4:
                canvas.yview_scroll(-1, "units")
            elif event.num == 5:
                canvas.yview_scroll(1, "units")

        for w in (canvas, self._form):
            w.bind("<MouseWheel>", _mw)
            w.bind("<Button-4>", _mw_linux)
            w.bind("<Button-5>", _mw_linux)

        scrollbar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)

        form = self._form
        form.columnconfigure(1, weight=1)

        row = 0

        # ============================================================
        # Account
        # ============================================================
        lbl = tk.Label(form, text="Account", font=_FONT_BOLD, anchor="w")
        lbl.grid(row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y)

        self._account_var = tk.StringVar()
        self._account_combo = ttk.Combobox(
            form, textvariable=self._account_var,
            state="readonly", font=_FONT,
        )
        self._account_combo.grid(
            row=row, column=1, sticky="ew", padx=_PAD_X, pady=_PAD_Y,
        )
        self._account_combo.bind("<<ComboboxSelected>>", self._on_account_selected)
        row += 1

        # ============================================================
        # Mission
        # ============================================================
        lbl = tk.Label(form, text="Mission", font=_FONT_BOLD, anchor="w")
        lbl.grid(row=row, column=0, columnspan=2, sticky="w", padx=_PAD_X, pady=(_PAD_Y + 4, 0))
        row += 1

        hint = tk.Label(
            form, text="What should Claude build, fix, or do?",
            font=_FONT_HINT, fg="#888888", anchor="w",
        )
        hint.grid(row=row, column=0, columnspan=2, sticky="w", padx=_PAD_X, pady=(0, 2))
        row += 1

        self._mission_text = tk.Text(
            form, height=4, wrap="word", font=_FONT,
            relief="solid", borderwidth=1,
        )
        self._mission_text.grid(
            row=row, column=0, columnspan=2, sticky="ew",
            padx=_PAD_X, pady=(0, _PAD_Y),
        )
        row += 1

        # ============================================================
        # Working Directory
        # ============================================================
        lbl = tk.Label(form, text="Working Directory", font=_FONT_BOLD, anchor="w")
        lbl.grid(row=row, column=0, columnspan=2, sticky="w", padx=_PAD_X, pady=(_PAD_Y, 0))
        row += 1

        hint = tk.Label(
            form, text="Where Claude should work (project folder).",
            font=_FONT_HINT, fg="#888888", anchor="w",
        )
        hint.grid(row=row, column=0, columnspan=2, sticky="w", padx=_PAD_X, pady=(0, 2))
        row += 1

        dir_frame = ttk.Frame(form)
        dir_frame.grid(
            row=row, column=0, columnspan=2, sticky="ew",
            padx=_PAD_X, pady=(0, _PAD_Y),
        )
        dir_frame.columnconfigure(0, weight=1)

        self._workdir_var = tk.StringVar()
        self._workdir_entry = ttk.Entry(
            dir_frame, textvariable=self._workdir_var, font=_FONT,
        )
        self._workdir_entry.grid(row=0, column=0, sticky="ew")

        browse_btn = ttk.Button(
            dir_frame, text="Browse\u2026", command=self._browse_workdir,
        )
        browse_btn.grid(row=0, column=1, sticky="e", padx=(4, 0))
        row += 1

        # ============================================================
        # Separator
        # ============================================================
        sep = ttk.Separator(form, orient="horizontal")
        sep.grid(
            row=row, column=0, columnspan=2, sticky="ew",
            padx=_PAD_X, pady=8,
        )
        row += 1

        # ============================================================
        # Variations
        # ============================================================
        lbl = tk.Label(form, text="Variations", font=_FONT_BOLD, anchor="w")
        lbl.grid(row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y)

        self._variations_var = tk.StringVar(value="1")
        self._variations_combo = ttk.Combobox(
            form, textvariable=self._variations_var,
            values=["1", "2", "3"], state="readonly",
            font=_FONT, width=6,
        )
        self._variations_combo.grid(
            row=row, column=1, sticky="w", padx=_PAD_X, pady=_PAD_Y,
        )
        self._variations_combo.bind("<<ComboboxSelected>>", self._on_variations_changed)
        row += 1

        # --- Variant 1 row (only shown when variations >= 2) ---
        self._var1_row = row
        self._var1_label = tk.Label(
            form, text="Variation 1", font=_FONT, anchor="w",
        )
        self._var1_label.grid(row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y)

        var1_frame = ttk.Frame(form)
        var1_frame.grid(row=row, column=1, sticky="ew", padx=_PAD_X, pady=_PAD_Y)
        var1_frame.columnconfigure(0, weight=1)
        self._var1_frame = var1_frame

        self._var1_preset_var = tk.StringVar()
        self._var1_entry = ttk.Entry(
            var1_frame, textvariable=self._var1_preset_var,
            state="readonly", font=_FONT,
        )
        self._var1_entry.grid(row=0, column=0, sticky="ew")

        self._var1_btn = ttk.Button(
            var1_frame, text="Presets\u2026",
            command=lambda: self._pick_variant_preset(self._var1_preset_var),
        )
        self._var1_btn.grid(row=0, column=1, sticky="e", padx=(4, 0))

        # Initially hidden
        self._var1_label.grid_remove()
        self._var1_frame.grid_remove()
        row += 1

        # --- Variant 2 row (only shown when variations >= 3) ---
        self._var2_row = row
        self._var2_label = tk.Label(
            form, text="Variation 2", font=_FONT, anchor="w",
        )
        self._var2_label.grid(row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y)

        var2_frame = ttk.Frame(form)
        var2_frame.grid(row=row, column=1, sticky="ew", padx=_PAD_X, pady=_PAD_Y)
        var2_frame.columnconfigure(0, weight=1)
        self._var2_frame = var2_frame

        self._var2_preset_var = tk.StringVar()
        self._var2_entry = ttk.Entry(
            var2_frame, textvariable=self._var2_preset_var,
            state="readonly", font=_FONT,
        )
        self._var2_entry.grid(row=0, column=0, sticky="ew")

        self._var2_btn = ttk.Button(
            var2_frame, text="Presets\u2026",
            command=lambda: self._pick_variant_preset(self._var2_preset_var),
        )
        self._var2_btn.grid(row=0, column=1, sticky="e", padx=(4, 0))

        # Initially hidden
        self._var2_label.grid_remove()
        self._var2_frame.grid_remove()
        row += 1

        # ============================================================
        # Separator
        # ============================================================
        sep2 = ttk.Separator(form, orient="horizontal")
        sep2.grid(
            row=row, column=0, columnspan=2, sticky="ew",
            padx=_PAD_X, pady=8,
        )
        row += 1

        # ============================================================
        # Max Cycles
        # ============================================================
        lbl = tk.Label(form, text="Max Cycles", font=_FONT, anchor="w")
        lbl.grid(row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y)

        self._cycles_var = tk.StringVar(value="Infinite")
        self._cycles_combo = ttk.Combobox(
            form, textvariable=self._cycles_var,
            values=MAX_CYCLES_OPTIONS, state="readonly",
            font=_FONT, width=10,
        )
        self._cycles_combo.grid(
            row=row, column=1, sticky="w", padx=_PAD_X, pady=_PAD_Y,
        )
        row += 1

        # ============================================================
        # Max Iterations
        # ============================================================
        lbl = tk.Label(form, text="Max Iterations", font=_FONT, anchor="w")
        lbl.grid(row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y)

        self._iters_var = tk.StringVar(value="Infinite")
        self._iters_combo = ttk.Combobox(
            form, textvariable=self._iters_var,
            values=MAX_ITERS_OPTIONS, state="readonly",
            font=_FONT, width=10,
        )
        self._iters_combo.grid(
            row=row, column=1, sticky="w", padx=_PAD_X, pady=_PAD_Y,
        )
        row += 1

        # ============================================================
        # Model
        # ============================================================
        lbl = tk.Label(form, text="Model", font=_FONT, anchor="w")
        lbl.grid(row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y)

        self._model_var = tk.StringVar(value="opus")
        self._model_combo = ttk.Combobox(
            form, textvariable=self._model_var,
            values=MODEL_OPTIONS, state="readonly",
            font=_FONT, width=10,
        )
        self._model_combo.grid(
            row=row, column=1, sticky="w", padx=_PAD_X, pady=_PAD_Y,
        )
        row += 1

        # ============================================================
        # Mode
        # ============================================================
        lbl = tk.Label(form, text="Mode", font=_FONT, anchor="w")
        lbl.grid(row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y)

        self._mode_var = tk.StringVar(value="General")
        self._mode_combo = ttk.Combobox(
            form, textvariable=self._mode_var,
            values=MODE_OPTIONS, state="readonly",
            font=_FONT, width=16,
        )
        self._mode_combo.grid(
            row=row, column=1, sticky="w", padx=_PAD_X, pady=_PAD_Y,
        )
        self._mode_combo.bind("<<ComboboxSelected>>", self._on_mode_changed)
        row += 1

        # ============================================================
        # Website Brief row (conditionally visible)
        # ============================================================
        self._brief_row = row
        self._brief_label = tk.Label(
            form, text="Website Brief", font=_FONT, anchor="w",
        )
        self._brief_label.grid(
            row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y,
        )

        brief_frame = ttk.Frame(form)
        brief_frame.grid(
            row=row, column=1, sticky="ew", padx=_PAD_X, pady=_PAD_Y,
        )
        self._brief_frame = brief_frame

        self._brief_btn = ttk.Button(
            brief_frame, text="Edit Brief\u2026", command=self._edit_website_brief,
        )
        self._brief_btn.pack(side="left")

        self._brief_status = tk.Label(
            brief_frame, text="(not set)", font=_FONT_HINT, fg="#888888",
        )
        self._brief_status.pack(side="left", padx=(8, 0))

        # Initially hidden
        self._brief_label.grid_remove()
        self._brief_frame.grid_remove()
        row += 1

        # ============================================================
        # Time Limit
        # ============================================================
        lbl = tk.Label(form, text="Time Limit", font=_FONT, anchor="w")
        lbl.grid(row=row, column=0, sticky="w", padx=_PAD_X, pady=_PAD_Y)

        self._time_var = tk.StringVar(value="No limit")
        self._time_combo = ttk.Combobox(
            form, textvariable=self._time_var,
            values=TIME_LIMIT_OPTIONS, state="readonly",
            font=_FONT, width=14,
        )
        self._time_combo.grid(
            row=row, column=1, sticky="w", padx=_PAD_X, pady=_PAD_Y,
        )
        row += 1

        # ============================================================
        # Separator
        # ============================================================
        sep3 = ttk.Separator(form, orient="horizontal")
        sep3.grid(
            row=row, column=0, columnspan=2, sticky="ew",
            padx=_PAD_X, pady=8,
        )
        row += 1

        # ============================================================
        # Button bar
        # ============================================================
        btn_bar = ttk.Frame(form)
        btn_bar.grid(
            row=row, column=0, columnspan=2, sticky="ew",
            padx=_PAD_X, pady=(4, _PAD_X),
        )

        cancel_btn = ttk.Button(btn_bar, text="Cancel", command=self._on_cancel)
        cancel_btn.pack(side="right", padx=(4, 0))

        launch_btn = ttk.Button(btn_bar, text="Launch", command=self._on_launch)
        launch_btn.pack(side="right")

    # ------------------------------------------------------------------
    # Account handling
    # ------------------------------------------------------------------

    def _refresh_accounts(self):
        """Probe all accounts and rebuild the account combobox."""
        self._accounts = get_accounts()

        display_values = []
        for email, plan, _config_dir in self._accounts:
            display_values.append(f"{email} ({plan})")
        display_values.append(_ADD_ACCOUNT_LABEL)

        self._account_combo["values"] = display_values

        # Auto-select the first real account if available
        if self._accounts:
            self._account_combo.current(0)

    def _on_account_selected(self, _event=None):
        """Handle account combobox selection, including the Add Account action."""
        value = self._account_var.get()
        if value == _ADD_ACCOUNT_LABEL:
            self._add_account_flow()

    def _add_account_flow(self):
        """Walk the user through adding a new Claude account."""
        slot = find_next_slot()
        if slot is None:
            messagebox.showerror(
                "Account Limit",
                "All 20 account slots are in use. Remove an account before adding a new one.",
                parent=self,
            )
            # Reset selection to first account (or nothing)
            if self._accounts:
                self._account_combo.current(0)
            else:
                self._account_var.set("")
            return

        config_dir = login_new_account(slot)
        command = get_login_command(config_dir)

        messagebox.showinfo(
            "Login Required",
            f"Run this command in a terminal:\n\n{command}\n\n"
            "Click OK when login is complete.",
            parent=self,
        )

        # Re-probe accounts to detect the new login
        old_count = len(self._accounts)
        self._refresh_accounts()

        # Check if a new account appeared
        if len(self._accounts) > old_count:
            # Select the newly added account (last real entry)
            self._account_combo.current(len(self._accounts) - 1)

            # Persist it
            newest = self._accounts[-1]
            email, plan, cfg = newest
            save_account(slot, email, plan, cfg)
        else:
            # Login was not detected; revert selection
            if self._accounts:
                self._account_combo.current(0)
            else:
                self._account_var.set("")

    # ------------------------------------------------------------------
    # Browse working directory
    # ------------------------------------------------------------------

    def _browse_workdir(self):
        """Open a folder chooser for the working directory."""
        initial = self._workdir_var.get() or os.path.expanduser("~")
        chosen = filedialog.askdirectory(
            initialdir=initial,
            title="Select Working Directory",
            parent=self,
        )
        if chosen:
            self._workdir_var.set(chosen)

    # ------------------------------------------------------------------
    # Variations visibility
    # ------------------------------------------------------------------

    def _on_variations_changed(self, _event=None):
        """Show/hide variant preset rows based on the selected count."""
        count = int(self._variations_var.get())

        if count >= 2:
            self._var1_label.grid()
            self._var1_frame.grid()
        else:
            self._var1_label.grid_remove()
            self._var1_frame.grid_remove()

        if count >= 3:
            self._var2_label.grid()
            self._var2_frame.grid()
        else:
            self._var2_label.grid_remove()
            self._var2_frame.grid_remove()

    def _pick_variant_preset(self, target_var):
        """Open the preset picker and store the result in *target_var*."""
        chosen = pick_preset(self)
        if chosen:
            target_var.set(chosen)

    # ------------------------------------------------------------------
    # Mode visibility (Website Brief)
    # ------------------------------------------------------------------

    def _on_mode_changed(self, _event=None):
        """Show/hide the Website Brief row when mode changes."""
        if self._mode_var.get() == "Website Builder":
            self._brief_label.grid()
            self._brief_frame.grid()
        else:
            self._brief_label.grid_remove()
            self._brief_frame.grid_remove()

    def _edit_website_brief(self):
        """Open the Website Brief dialog and store its result."""
        mission_text = self._mission_text.get("1.0", "end-1c").strip()
        dlg = WebsiteBriefDialog(
            self,
            initial_master_prompt=mission_text if not self._website_brief else "",
            existing_data=self._website_brief,
            root_window=self.master,
        )
        result = dlg.show()
        if result is not None:
            self._website_brief = result
            self._brief_status.configure(text="(brief saved)", fg="#228B22")
        # If cancelled, keep previous brief state

    # ------------------------------------------------------------------
    # Validation & result
    # ------------------------------------------------------------------

    def _validate(self):
        """Validate form inputs. Returns True if valid, else shows an error."""
        # Account
        idx = self._account_combo.current()
        if idx < 0 or idx >= len(self._accounts):
            messagebox.showerror(
                "No Account Selected",
                "Please select a Claude account before launching.",
                parent=self,
            )
            return False

        # Mission
        mission = self._mission_text.get("1.0", "end-1c").strip()
        if not mission:
            messagebox.showerror(
                "Mission Required",
                "Please describe a mission for Claude.",
                parent=self,
            )
            return False

        # Working directory
        workdir = self._workdir_var.get().strip()
        if not workdir or not os.path.isdir(workdir):
            messagebox.showerror(
                "Invalid Working Directory",
                "Please select a valid project folder.",
                parent=self,
            )
            return False

        # Variation presets
        num_variants = int(self._variations_var.get())
        if num_variants >= 2 and not self._var1_preset_var.get().strip():
            messagebox.showerror(
                "Preset Required",
                "Please choose a preset for Variation 1.",
                parent=self,
            )
            return False
        if num_variants >= 3 and not self._var2_preset_var.get().strip():
            messagebox.showerror(
                "Preset Required",
                "Please choose a preset for Variation 2.",
                parent=self,
            )
            return False

        return True

    def get_config(self):
        """Build and return the configuration dictionary from current form state."""
        idx = self._account_combo.current()
        _email, _plan, config_dir = self._accounts[idx]

        mission = self._mission_text.get("1.0", "end-1c").strip()
        workdir = self._workdir_var.get().strip()
        num_variants = int(self._variations_var.get())

        # Build preset list: variant 0 is always "Faithful"
        variant_presets = ["Faithful"]
        if num_variants >= 2:
            variant_presets.append(self._var1_preset_var.get().strip())
        if num_variants >= 3:
            variant_presets.append(self._var2_preset_var.get().strip())

        # Max cycles
        cycles_str = self._cycles_var.get()
        max_cycles = 0 if cycles_str == "Infinite" else int(cycles_str)

        # Max iterations
        iters_str = self._iters_var.get()
        max_iters = 0 if iters_str == "Infinite" else int(iters_str)

        # Time limit
        time_limit = TIME_LIMIT_MAP.get(self._time_var.get(), 0)

        return {
            "config_dir": config_dir,
            "mission": mission,
            "work_dir": workdir,
            "num_variants": num_variants,
            "variant_presets": variant_presets,
            "max_cycles": max_cycles,
            "max_iters": max_iters,
            "model": self._model_var.get(),
            "mode": self._mode_var.get(),
            "website_brief": self._website_brief,
            "time_limit": time_limit,
        }

    # ------------------------------------------------------------------
    # Button actions
    # ------------------------------------------------------------------

    def _on_launch(self):
        """Validate and close with result."""
        if not self._validate():
            return
        self.result = self.get_config()
        self.destroy()

    def _on_cancel(self):
        """Close without result."""
        self.result = None
        self.destroy()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def show(self):
        """Display the dialog modally and return the config dict or None."""
        self.wait_window()
        return self.result
