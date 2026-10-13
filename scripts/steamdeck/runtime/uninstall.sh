#!/usr/bin/env bash
# Remove only this installer's files; keep pairing data and application settings.
set -euo pipefail

die() { printf 'Uninstall failed: %s\n' "$*" >&2; exit 1; }
if [[ $# -gt 0 ]]; then
    [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]] || die 'Usage: ./uninstall.sh'
    printf '%s\n' 'Remove the user installation at ~/.local/opt/artemis-steamos.' \
        'Artemis settings, pairing data, and the downloaded archive are retained.'
    exit 0
fi
[[ $(id -u) -ne 0 ]] || die 'Run as your normal user, without sudo.'
[[ -n ${HOME:-} && -d $HOME && -O $HOME ]] || die 'HOME must be an existing directory owned by you.'
home_dir=$(cd -P -- "$HOME" && pwd)
[[ $home_dir != / ]] || die 'Unsupported HOME path.'
install_dir="$home_dir/.local/opt/artemis-steamos"
command_path="$home_dir/.local/bin/artemis-steamos"
desktop_dir="$home_dir/.local/share/applications"
desktop_path="$desktop_dir/artemis-steamos.desktop"
owner_id=artemis-steamos-user-install-v1
desktop_id='# Managed by Artemis SteamOS installer v1'
for target in "$install_dir" "$(dirname -- "$command_path")" "$desktop_dir"; do
    resolved=$(realpath -m -- "$target")
    [[ $resolved == "$home_dir/"* ]] || die "Destination resolves outside HOME: $target"
done
[[ -d $install_dir && ! -L $install_dir && -f $install_dir/.artemis-steamos-install && ! -L $install_dir/.artemis-steamos-install ]] || die 'No installation owned by this installer was found.'
[[ $(cat -- "$install_dir/.artemis-steamos-install") == "$owner_id" ]] || die 'Unrecognized installation ownership marker.'
[[ -d $install_dir/versions && ! -L $install_dir/versions ]] || die 'Invalid installed versions directory.'
mkdir -- "$install_dir/.operation-lock" 2>/dev/null || die 'Another install/uninstall is running (or .operation-lock remains after an interrupted operation).'
trap 'rmdir -- "$install_dir/.operation-lock" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Validate every payload before removing any. Do not follow substituted symlinks.
shopt -s nullglob dotglob
payloads=("$install_dir/versions/"*)
for payload in "${payloads[@]}"; do
    [[ $payload == "$install_dir/versions/release-"* && -d $payload && ! -L $payload && -f $payload/.artemis-steamos-payload && ! -L $payload/.artemis-steamos-payload ]] || die "Refusing to remove an unrecognized payload: $payload"
    [[ $(cat -- "$payload/.artemis-steamos-payload") == "$owner_id" ]] || die 'Unrecognized payload ownership marker.'
done
if [[ -L $command_path && $(readlink -- "$command_path") == "$install_dir/current/artemis" ]]; then
    rm -- "$command_path"
elif [[ -e $command_path || -L $command_path ]]; then
    printf 'Preserving unrelated command: %s\n' "$command_path"
fi
if [[ -f $desktop_path && ! -L $desktop_path ]] && grep -Fxq -- "$desktop_id" "$desktop_path"; then
    rm -- "$desktop_path"
elif [[ -e $desktop_path || -L $desktop_path ]]; then
    printf 'Preserving unrelated desktop entry: %s\n' "$desktop_path"
fi
for shortcut in artemis diagnose.sh uninstall.sh; do
    if [[ -L $install_dir/$shortcut && $(readlink -- "$install_dir/$shortcut") == "current/$shortcut" ]]; then
        rm -- "$install_dir/$shortcut"
    fi
done
if [[ -L $install_dir/current ]]; then
    pointer=$(readlink -- "$install_dir/current")
    if [[ $pointer == versions/release-* && $pointer != versions/*/* ]]; then
        rm -- "$install_dir/current"
    fi
fi
for payload in "${payloads[@]}"; do
    # Every absolute target is under the validated, non-symlink installation.
    rm -rf -- "$payload"
done
rmdir -- "$install_dir/versions"
rm -- "$install_dir/.artemis-steamos-install"
rmdir -- "$install_dir/.operation-lock"
trap - EXIT
if ! rmdir -- "$install_dir" 2>/dev/null; then
    printf 'Preserved additional files in: %s\n' "$install_dir"
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
fi
printf '%s\n' 'Artemis was uninstalled. Application settings and pairing data were retained.'
