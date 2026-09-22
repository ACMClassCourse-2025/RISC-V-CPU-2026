"""Assemble the hardware tools; Python, G++, Make and binutils stay on the host."""
from pathlib import Path
import re
import shutil
import subprocess

out = Path('/output/CPU2026-Tools.AppDir')
if out.exists():
    shutil.rmtree(out)
(out / 'bin').mkdir(parents=True)
(out / 'lib').mkdir()
shutil.copytree('/opt/yosys', out / 'yosys')
shutil.copytree('/opt/asap7', out / 'asap7')
shutil.copytree('/opt/opensta', out / 'opensta', ignore=shutil.ignore_patterns('include', 'lib'))
# Tcl needs its script library even when the shared object is bundled.
shutil.copytree('/usr/share/tcltk/tcl8.6', out / 'opensta/tcl8.6')
# Package the build image's Verilator installation for local student use.
shutil.copytree('/usr/share/verilator/include', out / 'verilator/include')
(out / 'verilator/bin').mkdir()
shutil.copy('/usr/bin/verilator_bin', out / 'verilator/bin/verilator_bin')
shutil.copy('/usr/share/verilator/bin/verilator_includer',
            out / 'verilator/bin/verilator_includer')
# Explicit loader execution makes /proc/self/exe refer to lib/ld-linux.
# Yosys resolves its data and default ABC relative to that executable.
(out / 'lib/share').symlink_to('../yosys/share/yosys', target_is_directory=True)
(out / 'lib/yosys-abc').symlink_to('../bin/yosys-abc')
shutil.copy('/opt/versions.txt', out / 'versions.txt')
with (out / 'versions.txt').open('a') as versions:
    versions.write(subprocess.check_output(['verilator', '--version'], text=True))
(out / 'distro-packages.txt').write_text(subprocess.check_output(
    ['dpkg-query', '-W', '-f=${Package} ${Version}\n'], text=True))
shutil.copytree('/usr/share/common-licenses', out / 'licenses/common')
# ldd includes transitive dependencies; avoid exporting LD_LIBRARY_PATH globally,
# which could break the host compiler, shell or Python.
for elf in (out / 'yosys/bin/yosys', out / 'yosys/bin/yosys-abc', out / 'opensta/bin/sta',
            out / 'verilator/bin/verilator_bin'):
    result = subprocess.run(['ldd', str(elf)], text=True, capture_output=True)
    if result.returncode or 'not found' in result.stdout:
        raise RuntimeError(f'ldd failed for {elf}: {result.stdout} {result.stderr}')
    for library in re.findall(r'(?:=>\s+|^\s*)(/\S+)', result.stdout, re.MULTILINE):
        shutil.copy(library, out / 'lib' / Path(library).name)
shutil.copytree('/usr/share/doc', out / 'licenses/distro', ignore_dangling_symlinks=True,
                ignore=shutil.ignore_patterns('*.pdf', 'examples'))
for name in ('yosys', 'yosys-abc'):
    wrapper = out / 'bin' / name
    wrapper.write_text('''#!/bin/sh
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "$base/lib/ld-linux-x86-64.so.2" --library-path "$base/lib" "$base/yosys/bin/NAME" "$@"
'''.replace('NAME', name))
    wrapper.chmod(0o755)
(out / 'bin/sta').write_text('''#!/bin/sh
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export TCL_LIBRARY="$base/opensta/tcl8.6"
exec "$base/lib/ld-linux-x86-64.so.2" --library-path "$base/lib" "$base/opensta/bin/sta" "$@"
''')
(out / 'bin/sta').chmod(0o755)
(out / 'bin/verilator').write_text('''#!/bin/sh
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export VERILATOR_ROOT="$base/verilator"
exec "$base/lib/ld-linux-x86-64.so.2" --library-path "$base/lib" "$base/verilator/bin/verilator_bin" "$@"
''')
(out / 'bin/verilator').chmod(0o755)
(out / 'AppRun').write_text('''#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CPU2026_APPDIR="$base"
export CPU2026_ASAP7_LIB="$base/asap7/lib"
command=${1:---help}
[ "$#" -eq 0 ] || shift
case "$command" in
    verilator|yosys|sta) exec "$base/bin/$command" "$@" ;;
    abc|yosys-abc) exec "$base/bin/yosys-abc" "$@" ;;
    exec)
        [ "$#" -gt 0 ] || { echo 'exec requires a host command' >&2; exit 2; }
        exec "$@"
        ;;
    --version) cat "$base/versions.txt" ;;
    --help|-h)
        echo 'CPU 2026 hardware tools for Linux x86-64'
        echo 'Use make build/test/perf/run/synth in your framework checkout.'
        echo 'Direct tools: AppImage verilator|yosys|abc|sta [arguments]'
        echo 'AppImage exec COMMAND [arguments] runs host tools with bundled hardware tools discoverable.'
        echo 'Requires host Python 3.10+, GNU Make, G++ (C++17), and binutils.'
        ;;
    *) echo "Unknown command: $command (use --help)" >&2; exit 2 ;;
esac
''')
(out / 'AppRun').chmod(0o755)
(out / 'cpu2026-tools.desktop').write_text('''[Desktop Entry]
Type=Application
Name=CPU 2026 Hardware Tools
Exec=AppRun
Icon=cpu2026-tools
Categories=Development;
Terminal=true
''')
(out / 'cpu2026-tools.svg').write_text('''<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"><rect x="16" y="16" width="96" height="96" rx="12" fill="#2563eb"/><text x="64" y="73" text-anchor="middle" font-family="sans-serif" font-size="26" fill="white">CPU</text></svg>''')
print(out)
