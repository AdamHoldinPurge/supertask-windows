"""Core autonomous loop engine for SuperTask™.
Replaces loop.sh — runs Ralph/Replan/Polish cycles in a background thread."""

import os
import re
import time
import subprocess
import threading
import logging
from datetime import datetime
from pathlib import Path

from .constants import (
    DEFAULT_INTERVAL, DEFAULT_TIMEOUT, DEFAULT_REPLAN_TIMEOUT,
    DEFAULT_REPLAN_PAUSE, MAX_RALPH_ITERS_PER_CYCLE, IS_WINDOWS,
    find_claude_cli,
)
from .process_manager import create_lock, remove_lock
from .prompts import (
    build_ralph_prompt, build_replan_prompt, build_polish_prompt,
    build_time_context, build_creative_injection, build_brief_addon,
    WEBSITE_BUILDER_ADDON,
)
from .presets import get_preset_description

logger = logging.getLogger('supertask.loop')


class LoopEngine(threading.Thread):
    """Background thread that drives the Ralph/Replan/Polish autonomous loop.

    Runs as a daemon thread so the main process can exit cleanly.
    Responds to stop signals within 1 second via threaded Event + file sentinel.
    """

    def __init__(self, config: dict):
        super().__init__(daemon=True)

        # Unpack config
        self.work_dir = config['work_dir']
        self.model = config['model']
        self.mode = config['mode']
        self.num_variants = config['num_variants']
        self.variant_presets = config['variant_presets']
        self.max_cycles = config['max_cycles']
        self.max_iters = config['max_iters']
        self.time_limit = config['time_limit']
        self.config_dir = config['config_dir']
        self.website_brief = config.get('website_brief')

        # Internal state
        self.stop_event = threading.Event()
        self.start_time = time.time()
        self.cycle = 0
        self.total_iters = 0
        self.root_log_dir = Path(self.work_dir) / 'autoloop-logs'

        # Locate claude CLI — must exist
        self.claude_cli = find_claude_cli()
        if not self.claude_cli:
            raise FileNotFoundError(
                'Could not find the claude CLI. '
                'Install it with: npm install -g @anthropic-ai/claude-code'
            )

    # ------------------------------------------------------------------
    # Path helpers
    # ------------------------------------------------------------------

    def get_variant_dir(self, v: int) -> Path:
        """Return the working directory for variant v."""
        if self.num_variants == 1:
            return Path(self.work_dir)
        return Path(self.work_dir) / f'variant_{v}'

    def get_variant_plan(self, v: int) -> Path:
        """Return the PLAN.md path for variant v."""
        return self.get_variant_dir(v) / 'PLAN.md'

    def get_variant_logs(self, v: int) -> Path:
        """Return the log directory for variant v."""
        if self.num_variants == 1:
            return self.root_log_dir
        return self.get_variant_dir(v) / 'autoloop-logs'

    def get_variant_preset(self, v: int) -> str:
        """Return the preset name for variant v (1-indexed)."""
        return self.variant_presets[v - 1]

    # ------------------------------------------------------------------
    # Status helpers
    # ------------------------------------------------------------------

    def set_status(self, text: str):
        """Write a one-line status to root_log_dir/STATUS."""
        try:
            status_file = self.root_log_dir / 'STATUS'
            status_file.write_text(text, encoding='utf-8')
        except OSError as e:
            logger.warning('Failed to write STATUS: %s', e)

    def log_event(self, text: str):
        """Append a timestamped line to root_log_dir/loop.log."""
        try:
            ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            log_file = self.root_log_dir / 'loop.log'
            with open(log_file, 'a', encoding='utf-8') as f:
                f.write(f'[{ts}] {text}\n')
        except OSError as e:
            logger.warning('Failed to write loop.log: %s', e)

    # ------------------------------------------------------------------
    # Stop / limit checks
    # ------------------------------------------------------------------

    def request_stop(self):
        """Signal the loop to stop gracefully."""
        self.stop_event.set()
        try:
            stop_file = self.root_log_dir / 'STOP_SIGNAL'
            stop_file.write_text('STOP', encoding='utf-8')
        except OSError:
            pass

    def _check_stop(self) -> bool:
        """Return True if a stop has been requested (event or file)."""
        if self.stop_event.is_set():
            return True
        stop_file = self.root_log_dir / 'STOP_SIGNAL'
        if stop_file.exists():
            self.stop_event.set()
            return True
        return False

    def _check_time_limit(self) -> bool:
        """Return True if the time limit has been reached."""
        if self.time_limit == 0:
            return False
        return (time.time() - self.start_time) >= self.time_limit

    # ------------------------------------------------------------------
    # Task completion detection
    # ------------------------------------------------------------------

    def _variant_ralph_is_done(self, v: int) -> bool:
        """Check if Ralph has signalled completion or all tasks are done.

        Returns True if ralph_signal.txt exists in the variant log dir,
        OR if PLAN.md has no unchecked tasks remaining.
        """
        v_logs = self.get_variant_logs(v)
        signal_file = v_logs / 'ralph_signal.txt'
        if signal_file.exists():
            return True

        plan_file = self.get_variant_plan(v)
        if plan_file.exists():
            try:
                content = plan_file.read_text(encoding='utf-8')
                # Look for unchecked task lines: "1. [ ] ..."
                if re.search(r'^\s*\d+\.\s*\[ \]', content, re.MULTILINE):
                    return False
                # No unchecked tasks found — all done
                return True
            except OSError:
                pass

        return False

    # ------------------------------------------------------------------
    # Claude CLI runner
    # ------------------------------------------------------------------

    def _run_claude(self, prompt: str, cwd: Path, log_file: Path,
                    timeout: int | None = None) -> int:
        """Run the claude CLI as a subprocess and capture output.

        Args:
            prompt: The full prompt text to pass via -p.
            cwd: Working directory for the subprocess.
            log_file: Path to write stdout+stderr output.
            timeout: Subprocess timeout in seconds (default: DEFAULT_TIMEOUT).

        Returns:
            Exit code (0=success, 124=timeout, 1=error).
        """
        env = {**os.environ, 'CLAUDE_CONFIG_DIR': self.config_dir}
        if IS_WINDOWS:
            env['PATH'] = os.environ.get('PATH', '')

        cmd = [
            self.claude_cli, '-p', prompt,
            '--dangerously-skip-permissions',
            '--model', self.model,
            '--max-turns', '100',
            '--output-format', 'json',
        ]

        try:
            kwargs = {}
            if IS_WINDOWS:
                kwargs['creationflags'] = subprocess.CREATE_NO_WINDOW

            result = subprocess.run(
                cmd, cwd=str(cwd), env=env,
                capture_output=True, text=True,
                encoding='utf-8',
                timeout=timeout or DEFAULT_TIMEOUT,
                **kwargs,
            )
            # Write combined output to log file
            log_file.parent.mkdir(parents=True, exist_ok=True)
            log_file.write_text(
                result.stdout + '\n' + result.stderr,
                encoding='utf-8',
            )
            return result.returncode
        except subprocess.TimeoutExpired:
            log_file.parent.mkdir(parents=True, exist_ok=True)
            log_file.write_text('TIMEOUT\n', encoding='utf-8')
            return 124
        except Exception as e:
            logger.error('Claude CLI error: %s', e)
            log_file.parent.mkdir(parents=True, exist_ok=True)
            log_file.write_text(f'ERROR: {e}\n', encoding='utf-8')
            return 1

    # ------------------------------------------------------------------
    # Polish phase
    # ------------------------------------------------------------------

    def _run_polish(self, v: int):
        """Run the Polish phase for a single variant."""
        v_dir = self.get_variant_dir(v)
        v_logs = self.get_variant_logs(v)
        v_preset = self.get_variant_preset(v)
        creative_text = build_creative_injection(v_preset, get_preset_description(v_preset))
        brief_addon = build_brief_addon(self.website_brief)

        if self.num_variants > 1:
            variant_label = f'You are working on Variant {v} of {self.num_variants} ({v_preset}). '
        else:
            variant_label = ''

        prompt = build_polish_prompt(variant_label, creative_text, brief_addon)

        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        log_file = v_logs / f'polish_{timestamp}.log'

        self.set_status(f'Polishing variant {v}' if self.num_variants > 1 else 'Polishing and finalizing')
        exit_code = self._run_claude(prompt, v_dir, log_file)
        self.log_event(f'Polish V{v} (exit: {exit_code})')

    def _run_polish_all(self):
        """Run the Polish phase for every variant."""
        for v in range(1, self.num_variants + 1):
            if self.num_variants > 1:
                (self.root_log_dir / 'CURRENT_VARIANT').write_text(
                    str(v), encoding='utf-8',
                )
            self._run_polish(v)

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    def run(self):
        """Main thread entry point — drives the Ralph/Replan/Polish loop."""

        # 1. Create log directory
        self.root_log_dir.mkdir(parents=True, exist_ok=True)

        # 2. Write SESSION file
        session_file = self.root_log_dir / 'SESSION'
        presets_str = ', '.join(self.variant_presets)
        session_file.write_text(
            f'START_TIME={int(self.start_time)}\n'
            f'TIME_LIMIT={self.time_limit}\n'
            f'NUM_VARIANTS={self.num_variants}\n'
            f'VARIANT_PRESETS={presets_str}\n'
            f'MODEL={self.model}\n'
            f'MODE={self.mode}\n'
            f'CONFIG_DIR={self.config_dir}\n',
            encoding='utf-8',
        )

        # 3. Create lock file
        create_lock(self.work_dir, os.getpid())

        # 4. Build addons once at startup
        website_addon = WEBSITE_BUILDER_ADDON if self.mode == 'Website Builder' else ''
        brief_addon = build_brief_addon(self.website_brief)

        # 5. Main loop
        try:
            while True:
                self.cycle += 1

                # Check time limit
                if self._check_time_limit():
                    self.set_status('Time limit reached — finishing up')
                    self.request_stop()

                # Check stop before new cycle
                if self._check_stop():
                    self.set_status('Polishing and finalizing')
                    self._run_polish_all()
                    break

                # Iterate variants (round-robin)
                for v in range(1, self.num_variants + 1):
                    v_dir = self.get_variant_dir(v)
                    v_logs = self.get_variant_logs(v)
                    v_preset = self.get_variant_preset(v)
                    creative_text = build_creative_injection(
                        v_preset, get_preset_description(v_preset),
                    )

                    if self.num_variants > 1:
                        (self.root_log_dir / 'CURRENT_VARIANT').write_text(
                            str(v), encoding='utf-8',
                        )

                    os.makedirs(str(v_logs), exist_ok=True)

                    # Check stop/time before each variant
                    if self._check_time_limit():
                        self.request_stop()
                    if self._check_stop():
                        break

                    # --------------------------------------------------
                    # PHASE 1: RALPH (execute tasks)
                    # --------------------------------------------------
                    variant_label = (
                        f'[V{v}/{self.num_variants} {v_preset}] '
                        if self.num_variants > 1 else ''
                    )
                    ralph_iter = 0

                    while True:
                        if self._check_time_limit():
                            self.request_stop()
                        if self._check_stop():
                            break
                        if self._variant_ralph_is_done(v):
                            self.set_status(f'{variant_label}All tasks complete')
                            break

                        ralph_iter += 1
                        self.total_iters += 1
                        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
                        log_file = v_logs / f'ralph_c{self.cycle}_i{ralph_iter}_{timestamp}.log'

                        self.set_status(
                            f'{variant_label}Executing task '
                            f'(cycle {self.cycle}, iter {ralph_iter})'
                        )

                        time_ctx = build_time_context(self.start_time, self.time_limit)
                        variant_ctx = (
                            f'You are working on Variant {v} of {self.num_variants} ({v_preset}). '
                            if self.num_variants > 1 else ''
                        )

                        prompt = build_ralph_prompt(
                            time_ctx, variant_ctx, creative_text,
                            website_addon, brief_addon,
                        )
                        exit_code = self._run_claude(prompt, v_dir, log_file)

                        self.log_event(
                            f'{variant_label}Cycle {self.cycle}, '
                            f'Ralph iter {ralph_iter} (exit: {exit_code})'
                        )

                        if ralph_iter >= MAX_RALPH_ITERS_PER_CYCLE:
                            break

                        if self.max_iters > 0 and self.total_iters >= self.max_iters:
                            self.request_stop()
                            break

                        # Sleep between iterations — check stop every second
                        for _ in range(DEFAULT_INTERVAL):
                            if self._check_stop():
                                break
                            time.sleep(1)

                    if self._check_stop():
                        break

                    # --------------------------------------------------
                    # PHASE 2: REPLAN (strategic planning for next cycle)
                    # --------------------------------------------------
                    self.set_status(f'{variant_label}Pausing before replan...')
                    for _ in range(DEFAULT_REPLAN_PAUSE):
                        if self._check_stop():
                            break
                        time.sleep(1)

                    if self._check_stop():
                        break

                    self.set_status(f'{variant_label}Planning next cycle')
                    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
                    replan_log = v_logs / f'replan_c{self.cycle}_{timestamp}.log'

                    time_ctx = build_time_context(self.start_time, self.time_limit)
                    variant_ctx = (
                        f'You are working on Variant {v} of {self.num_variants} ({v_preset}). '
                        if self.num_variants > 1 else ''
                    )

                    prompt = build_replan_prompt(
                        time_ctx, variant_ctx, creative_text, brief_addon,
                    )
                    exit_code = self._run_claude(
                        prompt, v_dir, replan_log,
                        timeout=DEFAULT_REPLAN_TIMEOUT,
                    )

                    self.log_event(
                        f'{variant_label}Cycle {self.cycle} REPLAN (exit: {exit_code})'
                    )

                # After variant loop — check stop
                if self._check_stop():
                    self.set_status('Polishing and finalizing')
                    self._run_polish_all()
                    break

                # Check max cycles
                if self.max_cycles > 0 and self.cycle >= self.max_cycles:
                    self.set_status('Max cycles reached — polishing')
                    self._run_polish_all()
                    break

                self.set_status(f'Cycle {self.cycle} complete — starting next')

        finally:
            # Cleanup — always runs even on exceptions
            remove_lock(self.work_dir)
            self.set_status('Stopped')
            try:
                session_file = self.root_log_dir / 'SESSION'
                with open(session_file, 'a', encoding='utf-8') as f:
                    f.write(f'END_TIME={int(time.time())}\n')
            except OSError as e:
                logger.warning('Failed to write END_TIME to SESSION: %s', e)
