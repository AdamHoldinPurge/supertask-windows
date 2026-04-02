# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec file for SuperTask™
# Uses onedir mode for reliable tkinterdnd2 DLL loading.
# Inno Setup bundles the output directory into a single installer.

import os
import sys

block_cipher = None

# Find tkinterdnd2 package location for bundling
try:
    import tkinterdnd2
    tkdnd_path = os.path.dirname(tkinterdnd2.__file__)
    tkdnd_data = [(tkdnd_path, 'tkinterdnd2')]
except ImportError:
    tkdnd_data = []

a = Analysis(
    ['launch.py'],
    pathex=[],
    binaries=[],
    datas=[
        ('supertask/icon.png', 'supertask'),
        ('supertask/icon.ico', 'supertask'),
    ] + tkdnd_data,
    hiddenimports=[
        'tkinterdnd2',
        'PIL',
        'PIL.Image',
        'PIL.ImageTk',
        'psutil',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='SuperTask',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon='supertask/icon.ico',
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='SuperTask',
)
