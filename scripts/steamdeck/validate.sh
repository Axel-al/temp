#!/usr/bin/env bash
# Inspect every executable/library/plugin with only the packaged library path.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
package_dir=${1:-"$repo_dir/dist/artemis-steamos-x86_64"}
package_dir=$(cd -- "$package_dir" && pwd -P)
report_dir="$package_dir/share/build-info"
mkdir -p -- "$report_dir"
export LD_LIBRARY_PATH="$package_dir/lib"
unset QT_PLUGIN_PATH QML2_IMPORT_PATH QML_IMPORT_PATH QT_QPA_PLATFORM_PLUGIN_PATH
python3 - "$package_dir" "$report_dir" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
reports = Path(sys.argv[2])
manifest = json.loads((root / "share/dependency-manifest.json").read_text())
host = re.compile("(?:" + "|".join(manifest["host_library_patterns"]) + ")$")
ceiling = tuple(map(int, manifest["glibc_ceiling"].split(".")))
ceilings = {"GLIBC": ceiling,
            "GLIBCXX": tuple(map(int, manifest["glibcxx_ceiling"].split("."))),
            "CXXABI": tuple(map(int, manifest["cxxabi_ceiling"].split(".")))}
failures = []
abi = {"GLIBC": set(), "GLIBCXX": set(), "CXXABI": set()}
elf_files = []
lddtree = shutil.which("lddtree")

def command(*args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, env=os.environ)
    return result.returncode, result.stdout

for item in root.rglob("*"):
    if item.is_symlink():
        if not item.exists() or not item.resolve().is_relative_to(root):
            failures.append(f"Broken or external symlink: {item.relative_to(root)}")
        continue
    if item.is_file():
        with item.open("rb") as stream:
            if stream.read(4) == b"\x7fELF":
                elf_files.append(item)

with (reports / "elf-audit.txt").open("w") as audit:
    for item in sorted(elf_files):
        relative = str(item.relative_to(root))
        audit.write(f"\n===== {relative} =====\n")
        if host.fullmatch(item.name):
            failures.append(f"Host runtime or GPU library must not be bundled: {relative}")
        code, header = command("readelf", "-h", str(item))
        if code or "Advanced Micro Devices X86-64" not in header:
            failures.append(f"Not a valid Linux x86_64 ELF: {relative}")
        code, dynamic = command("readelf", "-d", str(item))
        audit.write(dynamic)
        if code:
            failures.append(f"readelf failed: {relative}")
        routes = re.findall(r"\((?:RUNPATH|RPATH)\).*?\[(.*?)\]", dynamic)
        if not routes:
            failures.append(f"No private library RUNPATH: {relative}")
        for route in routes:
            for entry in route.split(":"):
                if entry != "$ORIGIN" and not entry.startswith("$ORIGIN/"):
                    failures.append(f"Non-relative or empty loader path in {relative}: {entry}")
                destination = Path(entry.replace("$ORIGIN", str(item.parent))).resolve()
                if not destination.is_relative_to(root):
                    failures.append(f"Loader path escapes package in {relative}: {entry}")
        for needed in re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic):
            if "/" in needed:
                failures.append(f"Absolute or relative filename in NEEDED {relative}: {needed}")
        code, dependencies = command("ldd", str(item))
        audit.write(dependencies)
        if code or "not found" in dependencies:
            failures.append(f"Unresolved dependencies: {relative}\n{dependencies}")
        for name, location in re.findall(r"^\s*(\S+)\s+=>\s+(/\S+)\s+\(", dependencies, re.M):
            if not host.fullmatch(name) and not Path(location).resolve().is_relative_to(root):
                failures.append(f"Unbundled application dependency: {relative}: {name} => {location}")
        code, versions = command("readelf", "--version-info", str(item))
        if code:
            failures.append(f"Cannot inspect ABI versions: {relative}")
        for namespace, version in re.findall(r"\b(GLIBCXX|GLIBC|CXXABI)_([0-9]+(?:\.[0-9]+)+)", versions):
            abi[namespace].add(version)
            if tuple(map(int, version.split("."))) > ceilings[namespace]:
                limit = ".".join(map(str, ceilings[namespace]))
                failures.append(f"{relative} requires {namespace}_{version}, exceeds {limit}")
        if "GLIBC_PRIVATE" in versions:
            failures.append(f"Private glibc ABI reference: {relative}")
        if lddtree:
            code, tree = command(lddtree, str(item))
            audit.write(tree)
            if code or re.search(r"=>\s+(?:None|not found)", tree):
                failures.append(f"Unresolved lddtree dependencies: {relative}\n{tree}")

for pattern in manifest["required_libraries"]:
    if not list((root / "lib").glob(pattern)):
        failures.append(f"Missing required application library: {pattern}")
for name in ("platforms/libqxcb.so", "platforms/libqwayland-egl.so",
             "platforms/libqwayland-generic.so", "platforms/libqoffscreen.so",
             "tls/libqopensslbackend.so", "imageformats/libqsvg.so"):
    if not (root / "plugins" / name).is_file():
        failures.append(f"Missing required Qt plugin: {name}")
for name in ("QtQml/qmldir", "QtQuick/qmldir", "QtQuick/Controls/qmldir",
             "QtQuick/Controls/Material/qmldir", "QtQuick/Layouts/qmldir"):
    if not (root / "qml" / name).is_file():
        failures.append(f"Missing required QML import: {name}")
for name in ("artemis", "install.sh", "uninstall.sh", "diagnose.sh"):
    if not (root / name).is_file() or not os.access(root / name, os.X_OK):
        failures.append(f"Missing/non-executable runtime script: {name}")

summary = {
    "elf_count": len(elf_files),
    "max_required_versions": {
        ns: max(values, key=lambda v: tuple(map(int, v.split('.')))) if values else None
        for ns, values in abi.items()
    },
    "glibc_ceiling": manifest["glibc_ceiling"],
    "lddtree_checked": bool(lddtree),
    "host_sonames": manifest["host_sonames"],
    "steamdeck_hardware_tested": False,
    "failures": failures,
}
serialized = json.dumps(summary, indent=2) + "\n"
(reports / "abi-summary.json").write_text(serialized)
(root / "share/abi-summary.json").write_text(serialized)
print(serialized)
if not elf_files:
    sys.exit("No packaged ELF files to validate")
if failures:
    sys.exit("Portable package validation failed")
PY
