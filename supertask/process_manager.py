"""Cross-platform process and lock file management."""
import os
import signal
import hashlib
import time
import psutil
from pathlib import Path
from .constants import LOCK_DIR, IS_WINDOWS


def get_lock_path(work_dir):
    """Hash work_dir with md5, return LOCK_DIR / 'autoloop-{hash[:8]}.lock'."""
    dir_hash = hashlib.md5(str(work_dir).encode()).hexdigest()[:8]
    return LOCK_DIR / f"autoloop-{dir_hash}.lock"


def check_existing_session():
    """Check for any running autoloop session.

    Iterates all autoloop-*.lock files in LOCK_DIR. For each, checks if the
    PID inside is still alive.

    Returns:
        Tuple of (pid, work_dir) for the first running session found, or None.
    """
    try:
        for lock_file in LOCK_DIR.glob("autoloop-*.lock"):
            try:
                pid = int(lock_file.read_text(encoding='utf-8').strip())
                if is_pid_alive(pid):
                    # Read the work_dir from the sidecar file
                    sidecar = lock_file.with_suffix(".lock.dir")
                    work_dir = ""
                    if sidecar.exists():
                        work_dir = sidecar.read_text(encoding='utf-8').strip()
                    return (pid, work_dir)
            except (ValueError, OSError):
                continue
    except OSError:
        pass
    return None


def create_lock(work_dir, pid):
    """Write PID to lock file and work_dir to .dir sidecar."""
    lock_path = get_lock_path(work_dir)
    lock_path.write_text(str(pid), encoding='utf-8')
    sidecar = lock_path.with_suffix(".lock.dir")
    sidecar.write_text(str(work_dir), encoding='utf-8')


def remove_lock(work_dir):
    """Delete lock file and sidecar. Silently ignore if missing."""
    lock_path = get_lock_path(work_dir)
    try:
        lock_path.unlink()
    except FileNotFoundError:
        pass
    sidecar = lock_path.with_suffix(".lock.dir")
    try:
        sidecar.unlink()
    except FileNotFoundError:
        pass


def is_pid_alive(pid):
    """Check if a process with the given PID is alive.

    Uses psutil.pid_exists and psutil.Process.is_running().
    Handles NoSuchProcess and AccessDenied gracefully.

    Returns:
        True if the process exists and is running, False otherwise.
    """
    try:
        if not psutil.pid_exists(pid):
            return False
        proc = psutil.Process(pid)
        return proc.is_running()
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return False


def kill_process_tree(pid):
    """Kill a process and all its children.

    Sends SIGTERM (or terminate() on Windows) to all children and the parent,
    waits 2 seconds, then sends SIGKILL (or kill() on Windows) to any
    survivors. Handles NoSuchProcess gracefully. Cleans up any lock files
    that reference the killed PID.

    Args:
        pid: Process ID of the parent process to kill.
    """
    try:
        parent = psutil.Process(pid)
    except psutil.NoSuchProcess:
        _cleanup_locks_for_pid(pid)
        return

    # Gather all children recursively
    try:
        children = parent.children(recursive=True)
    except psutil.NoSuchProcess:
        children = []

    # All processes to terminate: children + parent
    all_procs = children + [parent]

    # Phase 1: SIGTERM / terminate()
    for proc in all_procs:
        try:
            if IS_WINDOWS:
                proc.terminate()
            else:
                proc.send_signal(signal.SIGTERM)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    # Wait 2 seconds for graceful shutdown
    time.sleep(2)

    # Phase 2: SIGKILL / kill() for survivors
    for proc in all_procs:
        try:
            if proc.is_running():
                if IS_WINDOWS:
                    proc.kill()
                else:
                    proc.send_signal(signal.SIGKILL)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    # Clean up lock files referencing this PID
    _cleanup_locks_for_pid(pid)


def _cleanup_locks_for_pid(pid):
    """Remove any lock files whose stored PID matches the given PID."""
    try:
        for lock_file in LOCK_DIR.glob("autoloop-*.lock"):
            try:
                stored_pid = int(lock_file.read_text(encoding='utf-8').strip())
                if stored_pid == pid:
                    lock_file.unlink(missing_ok=True)
                    sidecar = lock_file.with_suffix(".lock.dir")
                    sidecar.unlink(missing_ok=True)
            except (ValueError, OSError):
                continue
    except OSError:
        pass
