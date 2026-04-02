"""Init and launch orchestration for SuperTask™.

Replaces launcher.sh — pure Python, no bash dependency.
Handles session validation, directory setup, PLAN.md initialization via
Claude CLI, and LoopEngine startup.
"""

import os
import json
import shutil
import subprocess
import threading
import time
from pathlib import Path
from datetime import datetime

import tkinter as tk
from tkinter import messagebox
import tkinter.ttk as ttk

from .constants import find_claude_cli, DEFAULT_TIMEOUT, ICON_PATH, IS_WINDOWS
from .process_manager import check_existing_session
from .prompts import build_init_prompt, build_creative_injection, build_brief_addon
from .presets import get_preset_description
from .loop_engine import LoopEngine


# ---------------------------------------------------------------------------
# Progress dialog helper
# ---------------------------------------------------------------------------

def _show_progress(parent, title, message):
    """Create a non-resizable progress dialog with an indeterminate progressbar.

    Args:
        parent: The parent tkinter window.
        title: Window title string.
        message: Label text displayed above the progressbar.

    Returns:
        The Toplevel widget so the caller can destroy it when done.
    """
    dialog = tk.Toplevel(parent)
    dialog.title(title)
    dialog.transient(parent)
    dialog.resizable(False, False)

    # Content
    frame = ttk.Frame(dialog, padding=20)
    frame.pack(fill='both', expand=True)

    label = ttk.Label(frame, text=message, wraplength=350)
    label.pack(pady=(0, 12))

    progress = ttk.Progressbar(frame, mode='indeterminate', length=300)
    progress.pack()
    progress.start(15)

    # Center on parent
    dialog.update_idletasks()
    pw = parent.winfo_width()
    ph = parent.winfo_height()
    px = parent.winfo_x()
    py = parent.winfo_y()
    dw = dialog.winfo_width()
    dh = dialog.winfo_height()
    x = px + (pw - dw) // 2
    y = py + (ph - dh) // 2
    dialog.geometry(f'+{x}+{y}')

    # Prevent closing via window manager
    dialog.protocol('WM_DELETE_WINDOW', lambda: None)

    return dialog


# ---------------------------------------------------------------------------
# Init thread helper
# ---------------------------------------------------------------------------

class _InitThread(threading.Thread):
    """Runs Claude CLI init calls in a background thread.

    Sets ``done_event`` when finished. If any error occurs it is stored
    in ``self.error``.  Per-variant errors are collected in ``self.errors``
    (list of tuples ``(variant_num, error_message)``).
    """

    def __init__(self, config, claude_cli):
        super().__init__(daemon=True)
        self.config = config
        self.claude_cli = claude_cli
        self.done_event = threading.Event()
        self.error = None        # Fatal error string, or None
        self.errors = []         # [(variant_num, msg), ...]

    def run(self):
        try:
            self._init_all_variants()
        except Exception as exc:
            self.error = str(exc)
        finally:
            self.done_event.set()

    def _init_all_variants(self):
        config = self.config
        work_dir = Path(config['work_dir'])
        num_variants = config['num_variants']
        variant_presets = config['variant_presets']
        model = config['model']
        config_dir = config['config_dir']
        mission = config['mission']
        website_brief = config.get('website_brief')

        # Load brief data from disk if it was saved
        brief_data = None
        brief_path = work_dir / 'autoloop-logs' / 'website_brief.json'
        if brief_path.exists():
            try:
                brief_data = json.loads(brief_path.read_text(encoding='utf-8'))
            except (json.JSONDecodeError, OSError):
                pass

        env = {**os.environ, 'CLAUDE_CONFIG_DIR': config_dir}

        for v in range(1, num_variants + 1):
            # Determine variant directory
            if num_variants == 1:
                v_dir = work_dir
            else:
                v_dir = work_dir / f'variant_{v}'

            preset_name = variant_presets[v - 1]
            preset_desc = get_preset_description(preset_name)

            creative_addon = build_creative_injection(preset_name, preset_desc)
            brief_addon = build_brief_addon(brief_data)

            prompt = build_init_prompt(
                mission=mission,
                preset=preset_name,
                variant_num=v,
                num_variants=num_variants,
                creative_addon=creative_addon,
                brief_addon=brief_addon,
            )

            cmd = [
                self.claude_cli, '-p', prompt,
                '--dangerously-skip-permissions',
                '--model', model,
                '--max-turns', '100',
                '--output-format', 'json',
            ]

            try:
                run_kwargs = {}
                if IS_WINDOWS:
                    run_kwargs['creationflags'] = subprocess.CREATE_NO_WINDOW

                result = subprocess.run(
                    cmd,
                    cwd=str(v_dir),
                    env=env,
                    capture_output=True,
                    text=True,
                    encoding='utf-8',
                    timeout=DEFAULT_TIMEOUT,
                    **run_kwargs,
                )
                # Write init log
                log_dir = v_dir / 'autoloop-logs'
                log_dir.mkdir(parents=True, exist_ok=True)
                log_file = log_dir / 'init.log'
                log_file.write_text(
                    result.stdout + '\n' + result.stderr,
                    encoding='utf-8',
                )
                if result.returncode != 0:
                    self.errors.append((
                        v,
                        f'Claude CLI exited with code {result.returncode}',
                    ))
            except subprocess.TimeoutExpired:
                self.errors.append((v, 'Init timed out'))
            except Exception as exc:
                self.errors.append((v, str(exc)))


# ---------------------------------------------------------------------------
# Image file extensions for brief asset copying
# ---------------------------------------------------------------------------

_IMAGE_EXTENSIONS = {
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff', '.tif',
    '.webp', '.svg', '.ico', '.avif',
}


def _is_image_file(path_str):
    """Return True if the path looks like an image file."""
    return Path(path_str).suffix.lower() in _IMAGE_EXTENSIONS


# ---------------------------------------------------------------------------
# Main launch function
# ---------------------------------------------------------------------------

def launch(parent, config):
    """Validate, initialise, and start a SuperTask autonomous loop.

    Args:
        parent: The parent tkinter window (used for dialogs).
        config: Dict from ConfigDialog.get_config() with keys:
            config_dir, mission, work_dir, num_variants, variant_presets,
            max_cycles, max_iters, model, mode, website_brief, time_limit.

    Returns:
        A running LoopEngine instance, or None if the launch was
        cancelled or failed.
    """
    work_dir = Path(config['work_dir'])
    mission = config['mission']
    num_variants = config['num_variants']
    model = config['model']
    mode = config['mode']
    time_limit = config['time_limit']

    # ------------------------------------------------------------------
    # 1. Check existing session
    # ------------------------------------------------------------------
    existing = check_existing_session()
    if existing is not None:
        pid, session_dir = existing
        answer = messagebox.askyesno(
            'Session Already Running',
            f'A SuperTask session is already running for:\n\n'
            f'{session_dir or "unknown directory"}\n\n'
            f'Open the monitor instead?',
            parent=parent,
        )
        if answer:
            return None  # Caller handles opening the monitor
        return None

    # ------------------------------------------------------------------
    # 2. Validate inputs
    # ------------------------------------------------------------------
    if not work_dir.is_dir():
        messagebox.showerror(
            'Invalid Directory',
            f'The working directory does not exist:\n\n{work_dir}',
            parent=parent,
        )
        return None

    if not mission or not mission.strip():
        messagebox.showerror(
            'Missing Mission',
            'Please enter a mission before launching.',
            parent=parent,
        )
        return None

    claude_cli = find_claude_cli()
    if not claude_cli:
        messagebox.showerror(
            'Claude CLI Not Found',
            'Could not locate the claude CLI.\n\n'
            'Install it with:\n'
            'npm install -g @anthropic-ai/claude-code',
            parent=parent,
        )
        return None

    # ------------------------------------------------------------------
    # 3. Setup directories
    # ------------------------------------------------------------------
    root_log_dir = work_dir / 'autoloop-logs'
    root_log_dir.mkdir(parents=True, exist_ok=True)

    # Archive old session if one exists
    timestamp_str = datetime.now().strftime('%Y%m%d_%H%M%S')

    if num_variants == 1:
        if (work_dir / 'PLAN.md').exists():
            archive_dir = root_log_dir / f'archive_{timestamp_str}'
            archive_dir.mkdir(parents=True, exist_ok=True)
            shutil.move(str(work_dir / 'PLAN.md'), str(archive_dir / 'PLAN.md'))
            # Also archive existing logs
            for log_item in root_log_dir.iterdir():
                if log_item.name.startswith('archive_'):
                    continue
                if log_item.name == 'assets':
                    continue
                try:
                    shutil.move(str(log_item), str(archive_dir / log_item.name))
                except (OSError, shutil.Error):
                    pass
    else:
        # Multi-variant: check if variant_1/PLAN.md exists
        if (work_dir / 'variant_1' / 'PLAN.md').exists():
            archive_dir = root_log_dir / f'archive_{timestamp_str}'
            archive_dir.mkdir(parents=True, exist_ok=True)
            for v in range(1, num_variants + 1):
                v_dir = work_dir / f'variant_{v}'
                if v_dir.exists():
                    try:
                        shutil.move(str(v_dir), str(archive_dir / f'variant_{v}'))
                    except (OSError, shutil.Error):
                        pass

        # Create variant directories
        for v in range(1, num_variants + 1):
            v_dir = work_dir / f'variant_{v}'
            v_dir.mkdir(parents=True, exist_ok=True)
            (v_dir / 'autoloop-logs').mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # 4. Handle website brief
    # ------------------------------------------------------------------
    website_brief = config.get('website_brief')
    if website_brief is not None:
        assets_dir = root_log_dir / 'assets'
        assets_dir.mkdir(parents=True, exist_ok=True)

        # Copy image files from brief and update paths
        for key in ('brand_logos', 'brand_reference_images', 'inspiration_images'):
            file_list = website_brief.get(key)
            if not file_list or not isinstance(file_list, list):
                continue

            updated_paths = []
            for file_path in file_list:
                src = Path(file_path)
                if src.exists() and src.is_file():
                    dest = assets_dir / src.name
                    # Handle name collisions
                    if dest.exists():
                        stem = src.stem
                        suffix = src.suffix
                        counter = 1
                        while dest.exists():
                            dest = assets_dir / f'{stem}_{counter}{suffix}'
                            counter += 1
                    shutil.copy2(str(src), str(dest))
                    updated_paths.append(str(dest))
                else:
                    # Keep original path if source doesn't exist
                    updated_paths.append(file_path)

            website_brief[key] = updated_paths

        # Save brief as JSON
        brief_path = root_log_dir / 'website_brief.json'
        brief_path.write_text(
            json.dumps(website_brief, indent=2, ensure_ascii=False),
            encoding='utf-8',
        )

        # Update config so downstream consumers see the saved brief
        config['website_brief'] = website_brief

    # ------------------------------------------------------------------
    # 5. Init PLAN.md for each variant
    # ------------------------------------------------------------------
    progress_dialog = _show_progress(
        parent,
        'Initializing',
        f'Initializing PLAN.md for {num_variants} variant{"s" if num_variants > 1 else ""}...\n'
        f'This may take a minute or two.',
    )

    init_thread = _InitThread(config, claude_cli)
    init_thread.start()

    # Poll until init is done, keeping the UI responsive
    def _poll_init():
        if init_thread.done_event.is_set():
            progress_dialog.destroy()
            _on_init_complete(parent, config, init_thread)
        else:
            parent.after(200, _poll_init)

    # We need to handle the rest of the flow after init completes.
    # Store a result container that _on_init_complete will fill.
    _result = {'engine': None, 'finished': threading.Event()}

    def _on_init_complete(par, cfg, thread):
        try:
            result = _finish_launch(par, cfg, thread)
            _result['engine'] = result
        finally:
            _result['finished'].set()

    parent.after(200, _poll_init)

    # Block until init + confirmation is done (process tk events meanwhile)
    while not _result['finished'].is_set():
        parent.update()
        time.sleep(0.05)

    return _result['engine']


def _finish_launch(parent, config, init_thread):
    """Complete the launch sequence after init finishes.

    Called from the main thread after the _InitThread has set done_event.

    Returns:
        A running LoopEngine, or None.
    """
    work_dir = Path(config['work_dir'])
    num_variants = config['num_variants']
    mission = config['mission']
    model = config['model']
    mode = config['mode']
    time_limit = config['time_limit']

    # Check for fatal init error
    if init_thread.error:
        messagebox.showerror(
            'Initialization Failed',
            f'A fatal error occurred during initialization:\n\n'
            f'{init_thread.error}',
            parent=parent,
        )
        return None

    # Report per-variant errors (non-fatal, but warn)
    if init_thread.errors:
        error_lines = '\n'.join(
            f'  Variant {v}: {msg}' for v, msg in init_thread.errors
        )
        messagebox.showwarning(
            'Initialization Warnings',
            f'Some variants had errors during init:\n\n{error_lines}\n\n'
            f'Continuing anyway — check if PLAN.md was created.',
            parent=parent,
        )

    # ------------------------------------------------------------------
    # 6. Verify PLAN.md exists for each variant
    # ------------------------------------------------------------------
    missing = []
    for v in range(1, num_variants + 1):
        if num_variants == 1:
            plan_path = work_dir / 'PLAN.md'
        else:
            plan_path = work_dir / f'variant_{v}' / 'PLAN.md'

        if not plan_path.exists():
            missing.append(v)

    if missing:
        if num_variants == 1:
            detail = f'PLAN.md was not created in:\n{work_dir}'
        else:
            detail = 'PLAN.md missing for variant(s): ' + ', '.join(
                str(v) for v in missing
            )
        messagebox.showerror(
            'Initialization Failed',
            f'{detail}\n\n'
            f'The Claude CLI may have failed or timed out.\n'
            f'Check autoloop-logs/init.log for details.',
            parent=parent,
        )
        return None

    # ------------------------------------------------------------------
    # 7. Show confirmation
    # ------------------------------------------------------------------
    # Build time limit label
    time_limit_label = 'No limit'
    if time_limit > 0:
        hours = time_limit // 3600
        minutes = (time_limit % 3600) // 60
        if hours > 0 and minutes > 0:
            time_limit_label = f'{hours}h {minutes}m'
        elif hours > 0:
            time_limit_label = f'{hours} hour{"s" if hours > 1 else ""}'
        else:
            time_limit_label = f'{minutes} minutes'

    mission_preview = mission[:100] + '...' if len(mission) > 100 else mission

    confirm = messagebox.askyesno(
        'SuperTask\u2122 Ready',
        f'Mission: {mission_preview}\n'
        f'Directory: {config["work_dir"]}\n'
        f'Model: {model}\n'
        f'Mode: {mode}\n'
        f'Variants: {num_variants}\n'
        f'Time Limit: {time_limit_label}\n\n'
        f'Start the autonomous loop?',
        parent=parent,
    )

    if not confirm:
        return None

    # ------------------------------------------------------------------
    # 8. Start loop
    # ------------------------------------------------------------------
    engine = LoopEngine(config)
    engine.start()

    # ------------------------------------------------------------------
    # 9. Return engine
    # ------------------------------------------------------------------
    return engine
