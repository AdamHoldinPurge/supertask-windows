"""Shared constants and configuration for SuperTask™."""
import os
import sys
import shutil
import tempfile
from pathlib import Path

APP_NAME = 'SuperTask\u2122'
APP_VERSION = '1.0.0'

# Directories
HOME = Path.home()
LOCK_DIR = Path(tempfile.gettempdir())
ACCOUNTS_DIR = HOME / '.supertask' / 'accounts'
ACCOUNTS_FILE = ACCOUNTS_DIR / 'accounts.json'
CONFIG_BASE = str(HOME / '.claude-supertask')
DEFAULT_CLAUDE_CONFIG = str(HOME / '.claude')
ICON_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'icon.png')
ICON_ICO_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'icon.ico')

# Option lists
MAX_CYCLES_OPTIONS = ['Infinite', '1', '2', '3', '5', '10', '25', '50', '100']
MAX_ITERS_OPTIONS = ['Infinite', '1', '3', '5', '8', '10', '15', '20', '30', '50']
MODEL_OPTIONS = ['opus', 'sonnet', 'haiku']
MODE_OPTIONS = ['General', 'Website Builder']
TIME_LIMIT_OPTIONS = [
    'No limit', '30 minutes', '1 hour', '2 hours',
    '4 hours', '8 hours', '12 hours', '24 hours',
]
TIME_LIMIT_MAP = {
    'No limit': 0, '30 minutes': 1800, '1 hour': 3600,
    '2 hours': 7200, '4 hours': 14400, '8 hours': 28800,
    '12 hours': 43200, '24 hours': 86400,
}

# Loop defaults
DEFAULT_MODEL = 'opus'
DEFAULT_INTERVAL = 30
DEFAULT_TIMEOUT = 1800
DEFAULT_REPLAN_TIMEOUT = 900
DEFAULT_REPLAN_PAUSE = 60
MAX_RALPH_ITERS_PER_CYCLE = 50

IS_WINDOWS = sys.platform == 'win32'


def find_claude_cli():
    """Locate the claude CLI binary. Returns path or None."""
    # Check common locations
    if IS_WINDOWS:
        candidates = ['claude.cmd', 'claude.exe', 'claude']
    else:
        candidates = ['claude']

    # Check PATH
    for name in candidates:
        path = shutil.which(name)
        if path:
            return path

    # Check common install locations
    local_bin = HOME / '.local' / 'bin' / 'claude'
    if local_bin.exists():
        return str(local_bin)

    if IS_WINDOWS:
        appdata = os.environ.get('APPDATA', '')
        if appdata:
            npm_claude = Path(appdata) / 'npm' / 'claude.cmd'
            if npm_claude.exists():
                return str(npm_claude)

    return None
