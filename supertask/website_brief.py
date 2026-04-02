"""Website Builder Brief form for SuperTask™."""
import os
import tkinter as tk
from tkinter import ttk, filedialog

from PIL import Image, ImageTk

try:
    from tkinterdnd2 import DND_FILES

    HAS_DND = True
except ImportError:
    HAS_DND = False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_field(parent, title, hint):
    """Create a bold title label and a dim hint label, packed into *parent*."""
    title_label = tk.Label(
        parent,
        text=title,
        font=("Segoe UI", 10, "bold"),
        anchor="w",
    )
    title_label.pack(fill="x", padx=8, pady=(8, 0))

    hint_label = tk.Label(
        parent,
        text=hint,
        font=("Segoe UI", 8),
        fg="#888888",
        anchor="w",
        justify="left",
        wraplength=580,
    )
    hint_label.pack(fill="x", padx=8, pady=(0, 4))


def _make_text_area(parent, height=80):
    """Create a tk.Text widget with border and scrollbar. Returns the Text widget."""
    frame = ttk.Frame(parent)
    frame.pack(fill="x", padx=8, pady=(0, 4))

    scrollbar = ttk.Scrollbar(frame, orient="vertical")
    scrollbar.pack(side="right", fill="y")

    text = tk.Text(
        frame,
        height=max(1, height // 20),  # approximate line count from pixel height
        wrap="word",
        font=("Segoe UI", 9),
        relief="solid",
        borderwidth=1,
        yscrollcommand=scrollbar.set,
    )
    text.pack(fill="x", expand=True)
    scrollbar.configure(command=text.yview)

    return text


# ---------------------------------------------------------------------------
# ImageDropZone
# ---------------------------------------------------------------------------

class ImageDropZone(ttk.Frame):
    """Reusable widget for drag-and-drop image collection with thumbnails."""

    def __init__(self, parent, root_window=None):
        super().__init__(parent)
        self.file_list = []
        self.photo_refs = []  # prevent GC of PhotoImage objects
        self.root_window = root_window

        # Thumbnail grid
        self.thumb_frame = tk.Frame(self)
        self.thumb_frame.pack(fill="x", padx=4, pady=4)

        # Hint
        self.hint_label = tk.Label(
            self,
            text="Drag and drop images here",
            font=("Segoe UI", 9),
            fg="#888888",
        )
        self.hint_label.pack(pady=(0, 2))

        # Add button
        self.add_btn = ttk.Button(self, text="Add Files\u2026", command=self._on_add_files)
        self.add_btn.pack(pady=(0, 4))

        # DnD registration
        if HAS_DND and root_window:
            try:
                self.drop_target_register(DND_FILES)
                self.dnd_bind("<<Drop>>", self._on_drop)
            except Exception:
                pass  # graceful fallback if DnD unavailable

    # --- DnD ---

    def _on_drop(self, event):
        """Handle files dropped onto the zone."""
        try:
            paths = self.root_window.tk.splitlist(event.data)
        except Exception:
            paths = event.data.split()

        for p in paths:
            p = p.strip().strip('{}')
            if p and os.path.isfile(p) and p not in self.file_list:
                self.file_list.append(p)
        self._refresh()

    # --- File chooser ---

    def _on_add_files(self):
        paths = filedialog.askopenfilenames(
            filetypes=[
                ("Images", "*.png *.jpg *.jpeg *.svg *.webp *.gif"),
                ("All", "*.*"),
            ]
        )
        for p in paths:
            if p and p not in self.file_list:
                self.file_list.append(p)
        self._refresh()

    # --- Thumbnail rendering ---

    def _make_thumbnail(self, path):
        """Create a 72x72 thumbnail PhotoImage from *path*. Returns None on failure."""
        try:
            img = Image.open(path)
            img.thumbnail((72, 72))
            photo = ImageTk.PhotoImage(img)
            return photo
        except Exception:
            return None

    def _refresh(self):
        """Rebuild the thumbnail grid from self.file_list."""
        # Clear existing children
        for child in self.thumb_frame.winfo_children():
            child.destroy()
        self.photo_refs.clear()

        if not self.file_list:
            self.hint_label.configure(text="Drag and drop images here")
            return

        self.hint_label.configure(
            text=f"{len(self.file_list)} image{'s' if len(self.file_list) != 1 else ''} added"
        )

        cols = 6
        for idx, path in enumerate(list(self.file_list)):
            row_idx = idx // cols
            col_idx = idx % cols

            cell = tk.Frame(self.thumb_frame)
            cell.grid(row=row_idx, column=col_idx, padx=4, pady=4)

            photo = self._make_thumbnail(path)
            if photo:
                self.photo_refs.append(photo)
                img_label = tk.Label(cell, image=photo)
                img_label.pack()
            else:
                # Placeholder for unreadable images
                placeholder = tk.Label(
                    cell,
                    text="?",
                    width=10,
                    height=5,
                    relief="solid",
                    borderwidth=1,
                )
                placeholder.pack()

            # Filename (truncated)
            basename = os.path.basename(path)
            display_name = basename if len(basename) <= 10 else basename[:9] + "\u2026"
            name_label = tk.Label(
                cell,
                text=display_name,
                font=("Segoe UI", 7),
                fg="#666666",
            )
            name_label.pack()

            # Remove button
            remove_btn = tk.Label(
                cell,
                text="\u00d7",
                font=("Segoe UI", 9, "bold"),
                fg="#cc4444",
                cursor="hand2",
            )
            remove_btn.pack()
            remove_btn.bind("<Button-1>", lambda e, p=path: self._remove_file(p))

    def _remove_file(self, path):
        if path in self.file_list:
            self.file_list.remove(path)
        self._refresh()

    # --- Public API ---

    def get_files(self):
        """Return a copy of the current file list."""
        return list(self.file_list)

    def set_files(self, file_list):
        """Replace the file list and refresh thumbnails."""
        self.file_list = list(file_list)
        self._refresh()


# ---------------------------------------------------------------------------
# DynamicUrlList
# ---------------------------------------------------------------------------

class DynamicUrlList(ttk.Frame):
    """Reusable widget for add/remove URL entries."""

    def __init__(self, parent):
        super().__init__(parent)
        self.entries = []  # list of ttk.Entry widgets

        self.rows_frame = ttk.Frame(self)
        self.rows_frame.pack(fill="x")

        self.add_btn = ttk.Button(self, text="+ Add URL", command=lambda: self._add_row())
        self.add_btn.pack(anchor="w", padx=8, pady=(4, 8))

        # Start with one empty row
        self._add_row()

    def _add_row(self, text=""):
        """Add an entry row with a remove button."""
        row_frame = ttk.Frame(self.rows_frame)
        row_frame.pack(fill="x", padx=8, pady=2)

        entry = ttk.Entry(row_frame, font=("Segoe UI", 9))
        entry.pack(side="left", fill="x", expand=True)
        if text:
            entry.insert(0, text)

        remove_btn = ttk.Button(
            row_frame,
            text="Remove",
            width=7,
            command=lambda: self._remove_row(entry, row_frame),
        )
        remove_btn.pack(side="right", padx=(4, 0))

        self.entries.append(entry)

    def _remove_row(self, entry, row_frame):
        """Remove one URL row."""
        if entry in self.entries:
            self.entries.remove(entry)
        row_frame.destroy()

    # --- Public API ---

    def get_urls(self):
        """Return non-empty URL strings."""
        return [e.get().strip() for e in self.entries if e.get().strip()]

    def set_urls(self, url_list):
        """Clear all rows and populate from *url_list*."""
        # Destroy existing rows
        for child in self.rows_frame.winfo_children():
            child.destroy()
        self.entries.clear()

        for url in url_list:
            self._add_row(text=url)

        # Always end with an empty row for convenience
        if not url_list:
            self._add_row()


# ---------------------------------------------------------------------------
# WebsiteBriefDialog
# ---------------------------------------------------------------------------

class WebsiteBriefDialog(tk.Toplevel):
    """Modal dialog with Brand DNA, Inspirations, and Master Prompt sections."""

    def __init__(self, parent, initial_master_prompt="", existing_data=None, root_window=None):
        super().__init__(parent)
        self.title("Website Builder Brief")
        self.geometry("640x720")
        self.resizable(True, True)
        self.transient(parent)
        self.grab_set()

        self.result = None
        self._root_window = root_window or parent

        # --- Outer scrollable container ---
        outer = ttk.Frame(self)
        outer.pack(fill="both", expand=True)

        canvas = tk.Canvas(outer, highlightthickness=0)
        scrollbar = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        scrollable = ttk.Frame(canvas)

        scrollable.bind(
            "<Configure>",
            lambda e: canvas.configure(scrollregion=canvas.bbox("all")),
        )
        self._canvas_window = canvas.create_window(
            (0, 0), window=scrollable, anchor="nw"
        )
        canvas.configure(yscrollcommand=scrollbar.set)

        # Stretch inner frame to canvas width
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

        def _bind_mousewheel(widget):
            widget.bind("<MouseWheel>", _on_mousewheel)
            widget.bind("<Button-4>", _on_mousewheel_linux)
            widget.bind("<Button-5>", _on_mousewheel_linux)

        _bind_mousewheel(canvas)
        _bind_mousewheel(scrollable)

        scrollbar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)

        # ===================================================================
        # SECTION 1: Your Brand
        # ===================================================================
        brand_frame = ttk.LabelFrame(scrollable, text="Your Brand", padding=8)
        brand_frame.pack(fill="x", padx=12, pady=(12, 4))

        # Brand Description
        _make_field(
            brand_frame,
            "Brand Description",
            "Describe your brand, product, or business in a few sentences.",
        )
        self.brand_desc_text = _make_text_area(brand_frame, height=80)

        # Brand Logos
        _make_field(
            brand_frame,
            "Brand Logos",
            "Upload your logo files (PNG, SVG, etc.).",
        )
        self.brand_logos_zone = ImageDropZone(brand_frame, root_window=self._root_window)
        self.brand_logos_zone.pack(fill="x", padx=8, pady=(0, 4))

        # Reference Images
        _make_field(
            brand_frame,
            "Reference Images",
            "Upload any brand images, style guides, or visual references.",
        )
        self.brand_refs_zone = ImageDropZone(brand_frame, root_window=self._root_window)
        self.brand_refs_zone.pack(fill="x", padx=8, pady=(0, 4))

        # Brand Websites
        _make_field(
            brand_frame,
            "Brand Websites",
            "Links to your existing website, social media, or online presence.",
        )
        self.brand_urls_list = DynamicUrlList(brand_frame)
        self.brand_urls_list.pack(fill="x", padx=8, pady=(0, 4))

        # Brand Notes
        _make_field(
            brand_frame,
            "Brand Notes",
            "Explain any media or links you've added \u2014 provide context, preferences, anything relevant.",
        )
        self.brand_notes_text = _make_text_area(brand_frame, height=50)

        # ===================================================================
        # SECTION 2: Inspirations
        # ===================================================================
        inspo_frame = ttk.LabelFrame(scrollable, text="Inspirations", padding=8)
        inspo_frame.pack(fill="x", padx=12, pady=4)

        # Inspiration Websites
        _make_field(
            inspo_frame,
            "Inspiration Websites",
            "Links to websites whose design you admire or want to reference.",
        )
        self.inspo_urls_list = DynamicUrlList(inspo_frame)
        self.inspo_urls_list.pack(fill="x", padx=8, pady=(0, 4))

        # Inspiration Images / Screenshots
        _make_field(
            inspo_frame,
            "Reference Images / Screenshots",
            "Upload screenshots or images that capture the look and feel you want.",
        )
        self.inspo_images_zone = ImageDropZone(inspo_frame, root_window=self._root_window)
        self.inspo_images_zone.pack(fill="x", padx=8, pady=(0, 4))

        # Inspiration Notes
        _make_field(
            inspo_frame,
            "Inspiration Notes",
            "Explain what you like about the references above \u2014 what to borrow, what to avoid.",
        )
        self.inspo_notes_text = _make_text_area(inspo_frame, height=50)

        # ===================================================================
        # SECTION 3: Master Prompt
        # ===================================================================
        prompt_frame = ttk.LabelFrame(scrollable, text="Master Prompt", padding=8)
        prompt_frame.pack(fill="x", padx=12, pady=4)

        _make_field(
            prompt_frame,
            "What do you want the website to be?",
            "This is your main brief. Describe the site in as much detail as you can \u2014 pages, features, tone, goals.",
        )
        self.master_prompt_text = _make_text_area(prompt_frame, height=120)

        if initial_master_prompt:
            self.master_prompt_text.insert("1.0", initial_master_prompt)

        # ===================================================================
        # Button bar
        # ===================================================================
        btn_bar = ttk.Frame(scrollable)
        btn_bar.pack(fill="x", padx=12, pady=(8, 16))

        cancel_btn = ttk.Button(btn_bar, text="Cancel", command=self._on_cancel)
        cancel_btn.pack(side="right", padx=(4, 0))

        save_btn = ttk.Button(btn_bar, text="Save Brief", command=self._on_save)
        save_btn.pack(side="right")

        # ===================================================================
        # Populate from existing data
        # ===================================================================
        if existing_data:
            self._populate(existing_data)

        self.focus_set()

    # --- Text helpers ---

    @staticmethod
    def _get_text(text_widget):
        """Extract all text from a tk.Text widget, stripped."""
        return text_widget.get("1.0", "end-1c").strip()

    # --- Data in / out ---

    def get_data(self):
        """Collect all form data into a dictionary."""
        return {
            "brand_dna": self._get_text(self.brand_desc_text),
            "brand_logos": self.brand_logos_zone.get_files(),
            "brand_reference_images": self.brand_refs_zone.get_files(),
            "brand_urls": self.brand_urls_list.get_urls(),
            "brand_notes": self._get_text(self.brand_notes_text),
            "inspiration_urls": self.inspo_urls_list.get_urls(),
            "inspiration_images": self.inspo_images_zone.get_files(),
            "inspiration_notes": self._get_text(self.inspo_notes_text),
            "master_prompt": self._get_text(self.master_prompt_text),
        }

    def _populate(self, data):
        """Fill all fields from a data dict (as returned by get_data)."""
        if data.get("brand_dna"):
            self.brand_desc_text.insert("1.0", data["brand_dna"])

        if data.get("brand_logos"):
            self.brand_logos_zone.set_files(data["brand_logos"])

        if data.get("brand_reference_images"):
            self.brand_refs_zone.set_files(data["brand_reference_images"])

        if data.get("brand_urls"):
            self.brand_urls_list.set_urls(data["brand_urls"])

        if data.get("brand_notes"):
            self.brand_notes_text.insert("1.0", data["brand_notes"])

        if data.get("inspiration_urls"):
            self.inspo_urls_list.set_urls(data["inspiration_urls"])

        if data.get("inspiration_images"):
            self.inspo_images_zone.set_files(data["inspiration_images"])

        if data.get("inspiration_notes"):
            self.inspo_notes_text.insert("1.0", data["inspiration_notes"])

        if data.get("master_prompt"):
            self.master_prompt_text.delete("1.0", "end")
            self.master_prompt_text.insert("1.0", data["master_prompt"])

    # --- Actions ---

    def _on_save(self):
        self.result = self.get_data()
        self.destroy()

    def _on_cancel(self):
        self.destroy()

    def show(self):
        """Block until dialog closes, then return collected data or None."""
        self.wait_window()
        return self.result
