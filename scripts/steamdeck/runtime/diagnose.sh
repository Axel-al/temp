#!/usr/bin/env bash
# Read-only diagnostics. No host list, pairing/config files, environment dump,
# network discovery, package installation, or modifications to SteamOS.
set -uo pipefail

if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then
        printf '%s\n' 'Usage: ./diagnose.sh > artemis-diagnostics.txt 2>&1' \
            'Checks the archive, host ABI, display session, VA-API and Vulkan.' \
            'Optional system tools are used only if installed. No sudo or network access.' \
            'Exit status 1 means package dependencies/structure are incomplete; GPU checks are advisory.'
        exit 0
    fi
    printf 'Usage: ./diagnose.sh > artemis-diagnostics.txt 2>&1\n' >&2
    exit 2
fi
source_path=${BASH_SOURCE[0]}
while [[ -L $source_path ]]; do
    source_dir=$(cd -P -- "$(dirname -- "$source_path")" && pwd)
    source_path=$(readlink -- "$source_path")
    [[ $source_path = /* ]] || source_path="$source_dir/$source_path"
done
app_dir=$(cd -P -- "$(dirname -- "$source_path")" && pwd)
failures=0

section() { printf '\n== %s ==\n' "$*"; }
host_tool() {
    env -u LD_LIBRARY_PATH -u QT_PLUGIN_PATH -u QT_QPA_PLATFORM_PLUGIN_PATH \
        -u QML_IMPORT_PATH -u QML2_IMPORT_PATH "$@"
}
limited_host_tool() {
    if command -v timeout >/dev/null 2>&1; then
        host_tool timeout 20s "$@"
    else
        printf 'Skipping %s: timeout is unavailable.\n' "$1"
        return 0
    fi
}

report() {
    section 'Artemis SteamOS diagnostics'
    date -u '+UTC: %Y-%m-%dT%H:%M:%SZ'
    uname -srmo
    if [[ -r /etc/os-release ]]; then
        grep -E '^(NAME|ID|VERSION|VERSION_ID|PRETTY_NAME|VARIANT_ID)=' /etc/os-release
    fi
    getconf GNU_LIBC_VERSION 2>&1 || true
    printf 'This report does not validate streaming, HDR, audio, input, or GPU decoding.\n'
    for info in build-info.txt BUILDINFO.txt; do
        if [[ -f $app_dir/$info ]]; then
            section "$info"
            cat -- "$app_dir/$info"
        fi
    done

    section 'Display and GPU access'
    [[ -n ${WAYLAND_DISPLAY:-} ]] && printf 'Wayland display is set.\n' || printf 'Wayland display is not set.\n'
    [[ -n ${DISPLAY:-} ]] && printf 'X11 display is set.\n' || printf 'X11 display is not set.\n'
    [[ -n ${QT_QPA_PLATFORM:-} ]] && printf 'A Qt platform override is set.\n' || printf 'Qt platform will be selected automatically.\n'
    [[ -n ${GAMESCOPE_WAYLAND_DISPLAY:-} ]] && printf 'A Gamescope Wayland display is set.\n'
    shopt -s nullglob
    local node
    local render_nodes=(/dev/dri/renderD*)
    [[ ${#render_nodes[@]} -gt 0 ]] || printf 'No DRM render nodes found.\n'
    for node in "${render_nodes[@]}"; do
        printf '%s: readable=%s writable=%s\n' "$(basename -- "$node")" "$([[ -r $node ]] && echo yes || echo no)" "$([[ -w $node ]] && echo yes || echo no)"
    done

    section 'Package structure'
    local entry
    for entry in bin/artemis lib plugins qml share/licenses; do
        if [[ -e $app_dir/$entry ]]; then
            printf 'OK: %s\n' "$entry"
        else
            printf 'MISSING: %s\n' "$entry"
            failures=$((failures + 1))
        fi
    done
    local pattern
    local matches
    for pattern in 'libavcodec.so.*' 'libavutil.so.*' 'libswscale.so.*' 'libQt6Core.so.*' 'libSDL2*.so*' 'libopus.so.*' 'libplacebo.so.*'; do
        mapfile -t matches < <(find "$app_dir/lib" -maxdepth 1 -name "$pattern" -printf '%f\n' 2>/dev/null | sort)
        if [[ ${#matches[@]} -gt 0 ]]; then
            printf '%s: %s\n' "$pattern" "${matches[*]}"
        else
            printf 'MISSING required application library: %s\n' "$pattern"
            failures=$((failures + 1))
        fi
    done

    section 'ELF dependency closure (application and dynamically loaded plugins)'
    if ! command -v ldd >/dev/null 2>&1 || ! command -v readelf >/dev/null 2>&1; then
        printf 'ldd/readelf unavailable: ELF checks could not be completed.\n'
        failures=$((failures + 1))
    else
        local elf output highest='' version version_text
        local elf_count=0
        while IFS= read -r -d '' elf; do
            readelf -h -- "$elf" >/dev/null 2>&1 || continue
            elf_count=$((elf_count + 1))
            printf '\n%s\n' "${elf#"$app_dir/"}"
            readelf -d -- "$elf" 2>/dev/null | grep -E '\((NEEDED|RPATH|RUNPATH)\)' || true
            if output=$(LD_LIBRARY_PATH="$app_dir/lib" ldd -- "$elf" 2>&1); then
                if [[ $output == *'not found'* ]]; then
                    failures=$((failures + 1))
                fi
            else
                failures=$((failures + 1))
            fi
            printf '%s\n' "$output"
            version_text=$(readelf --version-info -- "$elf" 2>/dev/null | sed -n '/Version needs section/,$p')
            version=$(printf '%s\n' "$version_text" | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -Vu | tail -n 1)
            if [[ -n $version ]]; then
                highest=$(printf '%s\n%s\n' "$highest" "$version" | sort -V | tail -n 1)
            fi
        done < <(find "$app_dir/bin" "$app_dir/lib" "$app_dir/plugins" "$app_dir/qml" -type f -print0 2>/dev/null)
        printf '\nELF files inspected: %s\nHighest required GLIBC symbol: %s\n' "$elf_count" "${highest:-unavailable}"
    fi

    section 'Transitive dependency tree'
    if command -v lddtree >/dev/null 2>&1; then
        LD_LIBRARY_PATH="$app_dir/lib" lddtree "$app_dir/bin/artemis" 2>&1 || true
    else
        printf 'Optional lddtree is not installed.\n'
    fi
    section 'Host VA-API (advisory)'
    if command -v vainfo >/dev/null 2>&1; then
        limited_host_tool vainfo --display drm 2>&1 || printf 'VA-API probe failed or timed out; inspect render-node permissions and host drivers.\n'
    else
        printf 'Optional vainfo is not installed.\n'
    fi
    section 'Host Vulkan (advisory)'
    if command -v vulkaninfo >/dev/null 2>&1; then
        limited_host_tool vulkaninfo --summary 2>&1 || printf 'Vulkan probe failed or timed out; inspect host drivers and session.\n'
    else
        printf 'Optional vulkaninfo is not installed.\n'
    fi
    section 'Result'
    printf 'Package/dependency check failures: %s\n' "$failures"
    printf 'GPU probes use host drivers. They do not prove that Artemis can decode or present a stream.\n'
    [[ $failures -eq 0 ]]
}

# Redact the home directory from library paths in a report intended for sharing.
# Bash string replacement does not interpret a home path as a regular expression.
report 2>&1 | while IFS= read -r line; do
    if [[ -n ${HOME:-} ]]; then
        printf '%s\n' "${line//"$HOME"/'[HOME]'}"
    else
        printf '%s\n' "$line"
    fi
done
