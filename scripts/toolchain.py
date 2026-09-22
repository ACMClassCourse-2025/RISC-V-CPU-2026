"""Select native tools or enter the course hardware-tool AppImage."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

DEFAULT_APPIMAGE = Path(__file__).resolve().parents[1] / 'cpu2026-tools-x86_64.AppImage'


def executable(value):
    """Resolve one executable, not a shell command; overrides never silently fall back."""
    found = shutil.which(os.path.expanduser(str(value)))
    if not found:
        raise ValueError(f'executable not found or not executable: {value}')
    # Preserve the final symlink name: clang++ and similar drivers use argv[0].
    return os.path.abspath(found)


def enter_appimage(path):
    """Keep the image mounted for the entire script, including tool subprocesses."""
    if os.environ.get('CPU2026_APPDIR') or not path:
        return
    image = Path(path).expanduser().resolve()
    if not image.exists():
        # The OJ and native installations can use the system tools.
        return
    command = [executable(image), 'exec', sys.executable,
               str(Path(sys.argv[0]).resolve()), *sys.argv[1:]]
    raise SystemExit(subprocess.call(command))


def packaged_tool(name):
    directory = os.environ.get('CPU2026_APPDIR')
    return executable(Path(directory) / 'bin' / name) if directory else None
