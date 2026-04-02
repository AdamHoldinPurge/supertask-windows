"""Preset picker dialog for SuperTask™."""
import tkinter as tk
from tkinter import ttk

from .presets import PRESET_NAMES, PRESET_DESCRIPTIONS


class PresetPickerDialog(tk.Toplevel):
    """Modal dialog showing a scrollable list of creative presets."""

    def __init__(self, parent):
        super().__init__(parent)
        self.title("Pick a Creative Direction")
        self.geometry("460x450")
        self.resizable(False, False)
        self.transient(parent)
        self.grab_set()

        self.result = None

        # --- Header ---
        header = tk.Label(
            self,
            text="Choose a preset or type your own direction",
            font=("Segoe UI", 11, "bold"),
            pady=10,
        )
        header.pack(fill="x")

        # --- Scrollable area ---
        container = ttk.Frame(self)
        container.pack(fill="both", expand=True, padx=8, pady=(0, 8))

        canvas = tk.Canvas(container, highlightthickness=0)
        scrollbar = ttk.Scrollbar(container, orient="vertical", command=canvas.yview)
        scrollable_frame = ttk.Frame(canvas)

        scrollable_frame.bind(
            "<Configure>",
            lambda e: canvas.configure(scrollregion=canvas.bbox("all")),
        )
        self._canvas_window = canvas.create_window(
            (0, 0), window=scrollable_frame, anchor="nw"
        )
        canvas.configure(yscrollcommand=scrollbar.set)

        # Make the inner frame stretch to canvas width
        canvas.bind(
            "<Configure>",
            lambda e: canvas.itemconfigure(self._canvas_window, width=e.width),
        )

        # Mousewheel scrolling
        def _on_mousewheel(event):
            canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

        def _on_mousewheel_linux(event):
            if event.num == 4:
                canvas.yview_scroll(-1, "units")
            elif event.num == 5:
                canvas.yview_scroll(1, "units")

        canvas.bind("<MouseWheel>", _on_mousewheel)  # Windows / macOS
        canvas.bind("<Button-4>", _on_mousewheel_linux)  # Linux scroll up
        canvas.bind("<Button-5>", _on_mousewheel_linux)  # Linux scroll down
        scrollable_frame.bind("<MouseWheel>", _on_mousewheel)
        scrollable_frame.bind("<Button-4>", _on_mousewheel_linux)
        scrollable_frame.bind("<Button-5>", _on_mousewheel_linux)

        scrollbar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)

        # --- Preset rows ---
        for name in PRESET_NAMES:
            if name == "Faithful":
                continue

            description = PRESET_DESCRIPTIONS.get(name, "")

            row = ttk.Frame(scrollable_frame)
            row.pack(fill="x", padx=8, pady=4)

            # Left side: name + description
            left = ttk.Frame(row)
            left.pack(side="left", fill="x", expand=True)

            name_label = tk.Label(
                left,
                text=name,
                font=("Segoe UI", 10, "bold"),
                anchor="w",
            )
            name_label.pack(fill="x")

            desc_label = tk.Label(
                left,
                text=description,
                font=("Segoe UI", 8),
                fg="#888888",
                anchor="w",
                justify="left",
                wraplength=300,
            )
            desc_label.pack(fill="x")

            # Bind mousewheel on row children too
            for widget in (row, left, name_label, desc_label):
                widget.bind("<MouseWheel>", _on_mousewheel)
                widget.bind("<Button-4>", _on_mousewheel_linux)
                widget.bind("<Button-5>", _on_mousewheel_linux)

            # Right side: select button
            select_btn = ttk.Button(
                row,
                text="Select",
                width=7,
                command=lambda n=name: self._select(n),
            )
            select_btn.pack(side="right", padx=(8, 0), pady=4)

            # Separator
            sep = ttk.Separator(scrollable_frame, orient="horizontal")
            sep.pack(fill="x", padx=8)

        # Focus this window
        self.focus_set()

    def _select(self, name):
        """Store the selected preset and close the dialog."""
        self.result = name
        self.destroy()

    def show(self):
        """Block until the dialog is closed, then return the selected preset name or None."""
        self.wait_window()
        return self.result


def pick_preset(parent):
    """Convenience function: open the preset picker and return the chosen name or None."""
    dialog = PresetPickerDialog(parent)
    return dialog.show()
