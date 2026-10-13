#!/usr/bin/env python3
"""Create the relocatable SteamOS package, without guessing missing libraries.

Run on the Ubuntu 22.04 build runner after compiling. QT_ROOT, DEPS_PREFIX and
ARTEMIS_BINARY must identify the Qt installation, custom dependencies and ELF.
The output is deliberately fixed below this checkout; existing output is an
error, rather than an invitation to recursively delete an arbitrary directory.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "dist" / "artemis-steamos-x86_64"
# The GPU stack and the C/C++ runtime must evolve with SteamOS. In particular,
# never let an Ubuntu libstdc++ shadow the newer one needed by SteamOS Mesa.
HOST_PATTERNS = [
    r"ld-linux.*", r"lib(c|m|pthread|dl|rt|resolv|util|anl|nss_.*)\.so\..*",
    r"libstdc\+\+\.so\..*", r"libgcc_s\.so\..*", r"libudev\.so\..*",
    r"libva(?:-.*)?\.so\..*", r"libdrm(?:_.*)?\.so\..*", r"libgbm\.so\..*",
    r"lib(?:GL|EGL|GLESv1_CM|GLESv2|GLX|OpenGL|GLdispatch)(?:_.*)?\.so\..*",
    r"libvulkan\.so\..*", r"libvdpau\.so\..*",
    # Mesa's current WSI can require newer Wayland/XCB entry points. Older
    # copies would interpose on the host driver even though Mesa stays external.
    r"libwayland(?:-.*)?\.so\..*",
    r"lib(?:X11(?:-xcb)?|Xext|Xfixes|Xrender|xshmfence)\.so\..*",
    # xcb-util helpers are independent libraries used by Qt, not libxcb's
    # protocol interfaces. Keep those helpers in the application package.
    r"libxcb(?:-(?!(?:cursor|icccm|image|keysyms|render-util|util)\.so)[a-z0-9-]+)?\.so\..*",
]
HOST_RE = re.compile("(?:" + "|".join(HOST_PATTERNS) + ")$")
REQUIRED_LIBRARIES = [
    "libavcodec.so.*", "libavformat.so.*", "libavutil.so.*", "libswscale.so.*",
    "libSDL2-2.0.so.*", "libSDL2_ttf-2.0.so.*", "libopus.so.*",
    "libplacebo.so.*", "libQt6Core.so.6", "libQt6Quick.so.6",
    "libssl.so.3", "libcrypto.so.3", "libasound.so.2", "libpulse.so.0",
]


def run(*args: str | Path, check: bool = True, env=None) -> str:
    result = subprocess.run([str(a) for a in args], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            check=False, env=env)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(map(str, args))}\n{result.stdout}")
    return result.stdout


def elf(path: Path) -> bool:
    if not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) == b"\x7fELF"


def main() -> None:
    qt = Path(os.environ["QT_ROOT"]).resolve(strict=True)
    deps = Path(os.environ["DEPS_PREFIX"]).resolve(strict=True)
    binary = Path(os.environ["ARTEMIS_BINARY"]).resolve(strict=True)
    if not elf(binary):
        raise RuntimeError(f"Not an ELF application: {binary}")
    OUT.mkdir(parents=True, exist_ok=False)
    for name in ("bin", "lib", "plugins", "qml", "share/licenses"):
        (OUT / name).mkdir(parents=True, exist_ok=True)
    origins: dict[str, Path] = {}
    queued: list[Path] = []
    copied: dict[str, Path] = {}
    host_required: set[str] = set()

    def copy_file(source: Path, target: Path) -> None:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        origins[str(target.relative_to(OUT))] = source.resolve()
        if elf(target):
            queued.append(target)

    def copy_tree(source: Path, target: Path) -> None:
        if not source.is_dir():
            return
        for entry in sorted(source.rglob("*")):
            if entry.is_file() and not entry.name.endswith((".a", ".o", ".obj", ".prl", ".la", ".debug")):
                # Qt ships build-only test resources beside its runtime QML.
                if "test" in entry.relative_to(source).parts:
                    continue
                copy_file(entry, target / entry.relative_to(source))

    def copy_library(source: Path) -> None:
        real = source.resolve(strict=True)
        name = real.name
        if HOST_RE.fullmatch(source.name) or HOST_RE.fullmatch(name):
            host_required.add(source.name)
            return
        if name in copied:
            if copied[name] != real and hashlib.sha256(copied[name].read_bytes()).digest() != hashlib.sha256(real.read_bytes()).digest():
                raise RuntimeError(f"Conflicting libraries named {name}: {real}, {copied[name]}")
        else:
            copied[name] = real
            copy_file(real, OUT / "lib" / name)
        dynamic = run("readelf", "-d", real)
        soname = re.search(r"\(SONAME\).*?\[(.*?)\]", dynamic)
        for alias in {source.name, soname.group(1) if soname else name}:
            if alias != name:
                dest = OUT / "lib" / alias
                if not dest.exists():
                    dest.symlink_to(name)
                elif dest.resolve() != (OUT / "lib" / name):
                    raise RuntimeError(f"Conflicting SONAME: {alias}")

    copy_file(binary, OUT / "bin/artemis")
    for name in ("Qt", "QtQml", "QtQuick", "Qt5Compat"):
        copy_tree(qt / "qml" / name, OUT / "qml" / name)
    required_platforms = ("libqxcb.so", "libqwayland-egl.so", "libqwayland-generic.so", "libqoffscreen.so")
    for name in required_platforms:
        copy_file(qt / "plugins/platforms" / name, OUT / "plugins/platforms" / name)
    for group in ("imageformats", "iconengines", "platforminputcontexts",
                  "styles", "tls", "networkinformation", "xcbglintegrations",
                  "wayland-decoration-client", "wayland-graphics-integration-client",
                  "wayland-shell-integration"):
        copy_tree(qt / "plugins" / group, OUT / "plugins" / group)
    # The application explicitly selects Qt Quick Material. Keep desktop portal
    # integration when supplied, without importing an unrelated GTK runtime.
    portal = qt / "plugins/platformthemes/libqxdgdesktopportal.so"
    if portal.is_file():
        copy_file(portal, OUT / "plugins/platformthemes" / portal.name)
    if not (OUT / "plugins/tls/libqopensslbackend.so").is_file():
        raise RuntimeError("Qt OpenSSL TLS backend is required")
    for module in ("QtQml/qmldir", "QtQuick/qmldir", "QtQuick/Controls/qmldir", "QtQuick/Layouts/qmldir"):
        if not (OUT / "qml" / module).is_file():
            raise RuntimeError(f"Missing required QML module: {module}")
    copy_tree(qt / "translations", OUT / "translations")
    (OUT / "bin/qt.conf").write_text(
        "[Paths]\nPrefix=..\nLibraries=lib\nPlugins=plugins\nQmlImports=qml\nTranslations=translations\n",
        encoding="utf-8")

    search_dirs = [deps / "lib", deps / "lib/x86_64-linux-gnu", qt / "lib"]
    ldconfig = run("ldconfig", "-p")
    cache = {}
    for soname, path in re.findall(r"^\s*(\S+)\s+\(.*?x86-64.*?\)\s+=>\s+(\S+)", ldconfig, re.M):
        cache.setdefault(soname, Path(path))

    def resolve_library(name: str) -> Path:
        for folder in search_dirs:
            if (folder / name).exists():
                return folder / name
        if name in cache:
            return cache[name]
        raise RuntimeError(f"Required dynamically loaded library unavailable: {name}")

    # Retain the requested FFmpeg runtime even when --as-needed removes an
    # otherwise unused library from the application's direct NEEDED entries.
    for name in ("libavcodec.so.60", "libavformat.so.60", "libavutil.so.58", "libswscale.so.7"):
        copy_library(resolve_library(name))
    # SDL and Qt load these by name, so they never appear in the application's
    # DT_NEEDED entries. PulseAudio works with SteamOS's PipeWire Pulse server.
    for name in ("libssl.so.3", "libcrypto.so.3", "libasound.so.2", "libpulse.so.0",
                 "libX11.so.6", "libXext.so.6", "libXcursor.so.1", "libXrandr.so.2",
                 "libXinerama.so.1", "libXi.so.6", "libXfixes.so.3", "libXrender.so.1",
                 "libXss.so.1", "libdbus-1.so.3", "libwayland-client.so.0",
                 "libwayland-cursor.so.0", "libwayland-egl.so.1", "libxkbcommon.so.0"):
        copy_library(resolve_library(name))
    build_env = dict(os.environ, LD_LIBRARY_PATH=":".join(map(str, [OUT / "lib", *search_dirs])))
    processed: set[Path] = set()
    while queued:
        target = queued.pop(0)
        if target in processed:
            continue
        processed.add(target)
        # Inspect the original file: its build RPATH may still be needed to
        # discover private dependencies such as libpulsecommon.
        original = origins[str(target.relative_to(OUT))]
        output = run("ldd", original, env=build_env)
        missing = re.findall(r"^\s*(\S+)\s+=> not found", output, re.M)
        if missing:
            raise RuntimeError(f"Unresolved build dependencies of {original}: {', '.join(missing)}")
        for name, path in re.findall(r"^\s*(\S+)\s+=>\s+(/\S+)\s+\(", output, re.M):
            if HOST_RE.fullmatch(name):
                host_required.add(name)
            elif not Path(path).is_relative_to(OUT):
                copy_library(Path(path))

    for pattern in REQUIRED_LIBRARIES:
        if not list((OUT / "lib").glob(pattern)):
            raise RuntimeError(f"Required application dependency was not bundled: {pattern}")
    # RUNPATH is not inherited. Every ELF (including each QML/Qt plugin) gets
    # its own origin-relative route back to the private library directory.
    for target in sorted(processed):
        relative_lib = os.path.relpath(OUT / "lib", target.parent)
        paths = ["$ORIGIN"]
        if relative_lib != ".":
            paths.append("$ORIGIN/" + relative_lib)
        run("patchelf", "--set-rpath", ":".join(paths), target)

    runtime = REPO / "scripts/steamdeck/runtime"
    for name in ("artemis", "install.sh", "uninstall.sh", "diagnose.sh"):
        source = runtime / name
        copy_file(source, OUT / name)
        (OUT / name).chmod(0o755)
    copy_file(REPO / "scripts/artemis.png", OUT / "share/icons/artemis.png")
    copy_file(REPO / "LICENSE", OUT / "share/licenses/Artemis-LICENSE")
    copy_tree(deps / "share/licenses", OUT / "share/licenses/build-dependencies")
    copy_tree(qt / "LICENSES", OUT / "share/licenses/Qt")
    copy_tree(REPO / ".steamdeck/reports", OUT / "share/build-info")
    copy_file(REPO / ".steamdeck/reports/build-info.txt", OUT / "build-info.txt")
    for name in ("README.md", "SOURCES.md"):
        source = REPO / "docs/steamdeck" / name
        if source.is_file():
            copy_file(source, OUT / name)
    if (REPO / "docs/steamdeck.md").is_file():
        copy_file(REPO / "docs/steamdeck.md", OUT / "README.md")

    package_records: dict[str, dict] = {}

    def record_system_package(owner: str) -> None:
        if owner in package_records:
            return
        fields = run("dpkg-query", "-W", "-f=${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\n", owner).strip().split("\t")
        if len(fields) != 4 or not all(fields):
            raise RuntimeError(f"Incomplete source provenance for {owner}: {fields}")
        notice = Path("/usr/share/doc") / owner.split(":")[0] / "copyright"
        if not notice.is_file():
            raise RuntimeError(f"Missing required copyright notice for {owner}")
        safe_name = owner.replace(":", "_")
        shutil.copy2(notice, OUT / "share/licenses" / f"{safe_name}.copyright")
        package_records[owner] = dict(zip(("binary_package", "binary_version", "source_package", "source_version"), fields))

    # The Jammy glslang backend uses static archives. They do not appear in
    # ldd, but their exact sources and copyright notices must accompany the
    # resulting FFmpeg/libplacebo binaries just like shared dependencies.
    static_packages = ["glslang-dev", "spirv-tools"]
    for owner in static_packages:
        record_system_package(owner)
    files = []
    for relative, original in sorted(origins.items()):
        target = OUT / relative
        if not elf(target):
            continue
        owner = None
        if original.is_relative_to(qt):
            icu = re.match(r"libicu\w+\.so\.(\d+(?:\.\d+)*)$", original.name)
            owner = "icu-" + icu.group(1) if icu else "qt-6.8.3"
        elif original.is_relative_to(deps):
            owner = "source-built-dependency"
        elif original == binary:
            owner = "artemis"
        else:
            candidates = [original]
            # Ubuntu's merged /usr can differ from paths recorded by dpkg.
            if str(original).startswith("/usr/lib/"):
                candidates.append(Path(str(original).removeprefix("/usr")))
            for candidate in candidates:
                query = run("dpkg-query", "-S", candidate, check=False)
                match = re.search(r"^(.+?): /", query, re.M)
                if match:
                    owner = match.group(1).split(", ")[0]
                    break
            if not owner:
                raise RuntimeError(f"Cannot identify redistribution origin of {original}")
            record_system_package(owner)
        files.append({"path": relative, "origin": str(original), "component": owner,
                      "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
    manifest = {
        "format": 1, "architecture": "x86_64", "glibc_ceiling": "2.35",
        "glibcxx_ceiling": "3.4.30", "cxxabi_ceiling": "1.3.13",
        "qt_version": "6.8.3", "host_sonames": sorted(host_required),
        "host_library_patterns": HOST_PATTERNS, "required_libraries": REQUIRED_LIBRARIES,
        "statically_linked_packages": static_packages,
        "system_packages": sorted(package_records.values(), key=lambda item: item["binary_package"]),
        "elf_files": files,
    }
    (OUT / "share/dependency-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Packaged {len(files)} ELF objects in {OUT}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, FileNotFoundError) as error:
        sys.exit(f"Packaging failed: {error}")
