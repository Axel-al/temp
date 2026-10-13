#!/usr/bin/env bash
# Install a portable archive without root access or changes to system libraries.
set -euo pipefail
umask 022

die() { printf 'Install failed: %s\n' "$*" >&2; exit 1; }
if [[ $# -gt 0 ]]; then
    [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]] || die 'Usage: ./install.sh'
    printf '%s\n' 'Install Artemis in ~/.local/opt/artemis-steamos.' \
        'Adds ~/.local/bin/artemis-steamos and a desktop menu entry.' \
        'Updates switch the current payload atomically. Run uninstall.sh to remove it.'
    exit 0
fi
[[ $(id -u) -ne 0 ]] || die 'Run as your normal user, without sudo.'
[[ -n ${HOME:-} && -d $HOME && -O $HOME ]] || die 'HOME must be an existing directory owned by you.'
home_dir=$(cd -P -- "$HOME" && pwd)
[[ $home_dir != / && $home_dir != *$'\n'* && $home_dir != *$'\r'* ]] || die 'Unsupported HOME path.'
source_dir=$(cd -P -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
[[ -x $source_dir/bin/artemis && -x $source_dir/artemis && -x $source_dir/uninstall.sh ]] || die 'Run install.sh from the extracted, complete archive.'

install_dir="$home_dir/.local/opt/artemis-steamos"
bin_dir="$home_dir/.local/bin"
desktop_dir="$home_dir/.local/share/applications"
command_path="$bin_dir/artemis-steamos"
desktop_path="$desktop_dir/artemis-steamos.desktop"
owner_id=artemis-steamos-user-install-v1
desktop_id='# Managed by Artemis SteamOS installer v1'

# Reject a .local parent symlink that would redirect writes outside HOME.
for target in "$install_dir" "$bin_dir" "$desktop_dir"; do
    resolved=$(realpath -m -- "$target")
    [[ $resolved == "$home_dir/"* ]] || die "Destination resolves outside HOME: $target"
done
if [[ -e $install_dir || -L $install_dir ]]; then
    [[ -d $install_dir && ! -L $install_dir && -f $install_dir/.artemis-steamos-install && ! -L $install_dir/.artemis-steamos-install ]] || die "Refusing to replace an unrelated installation: $install_dir"
    [[ $(cat -- "$install_dir/.artemis-steamos-install") == "$owner_id" ]] || die 'Unrecognized installation ownership marker.'
else
    mkdir -p -- "$(dirname -- "$install_dir")"
    mkdir -- "$install_dir"
    printf '%s\n' "$owner_id" > "$install_dir/.artemis-steamos-install"
fi
[[ ! -L $install_dir/versions ]] || die 'The versions directory must not be a symlink.'
mkdir -p -- "$install_dir/versions" "$bin_dir" "$desktop_dir"
mkdir -- "$install_dir/.operation-lock" 2>/dev/null || die 'Another install/uninstall is running (or .operation-lock remains after an interrupted operation).'

staged=''
temporary_link=''
desktop_temp=''
command_temp=''
cleanup() {
    [[ -z $temporary_link ]] || rm -f -- "$temporary_link"
    [[ -z $desktop_temp ]] || rm -f -- "$desktop_temp"
    [[ -z $command_temp ]] || rm -f -- "$command_temp"
    if [[ -n $staged && $staged == "$install_dir/versions/release-"* && -d $staged && ! -L $staged ]]; then
        rm -rf -- "$staged"
    fi
    rmdir -- "$install_dir/.operation-lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e $command_path || -L $command_path ]]; then
    [[ -L $command_path && $(readlink -- "$command_path") == "$install_dir/current/artemis" ]] || die "Refusing to replace unrelated command: $command_path"
fi
if [[ -e $desktop_path || -L $desktop_path ]]; then
    if [[ ! -f $desktop_path || -L $desktop_path ]] || ! grep -Fxq -- "$desktop_id" "$desktop_path"; then
        die "Refusing to replace unrelated desktop entry: $desktop_path"
    fi
fi
for shortcut in artemis diagnose.sh uninstall.sh; do
    target="$install_dir/$shortcut"
    if [[ -e $target || -L $target ]]; then
        [[ -L $target && $(readlink -- "$target") == "current/$shortcut" ]] || die "Refusing to replace unrelated file: $target"
    fi
done
previous=''
if [[ -e $install_dir/current || -L $install_dir/current ]]; then
    [[ -L $install_dir/current ]] || die 'The installed current pointer is not a symlink.'
    previous=$(readlink -- "$install_dir/current")
    [[ $previous == versions/release-* && $previous != *'/../'* && $previous != *'/./'* && $previous != versions/*/* ]] || die 'Invalid installed payload pointer.'
    [[ -d $install_dir/$previous && ! -L $install_dir/$previous && -f $install_dir/$previous/.artemis-steamos-payload ]] || die 'The installed payload is not owned by this installer.'
    [[ $(cat -- "$install_dir/$previous/.artemis-steamos-payload") == "$owner_id" ]] || die 'Unrecognized payload ownership marker.'
fi

staged=$(mktemp -d -- "$install_dir/versions/release-XXXXXXXX")
cp -a -- "$source_dir/." "$staged/"
printf '%s\n' "$owner_id" > "$staged/.artemis-steamos-payload"
chmod u+x -- "$staged/artemis" "$staged/bin/artemis" "$staged/install.sh" "$staged/uninstall.sh" "$staged/diagnose.sh"

# Desktop Exec values have both Desktop Entry escaping and shell-like quoting.
desktop_exec=${command_path//\\/\\\\\\\\}
desktop_exec=${desktop_exec//\"/\\\\\\\"}
desktop_exec=${desktop_exec//\$/\\\\\$}
desktop_exec=${desktop_exec//\`/\\\\\`}
desktop_exec=${desktop_exec//%/%%}
icon_path="$install_dir/current/share/icons/artemis.png"
icon_path=${icon_path//\\/\\\\}
desktop_temp=$(mktemp -- "$desktop_dir/.artemis-steamos.desktop.XXXXXXXX")
cat > "$desktop_temp" <<EOF
$desktop_id
[Desktop Entry]
Name=Artemis (SteamOS)
Comment=Stream games from Apollo or Sunshine
Exec="$desktop_exec"
Icon=$icon_path
Terminal=false
Type=Application
Categories=Game;Network;RemoteAccess;
Keywords=artemis;stream;sunshine;apollo;remote play;
StartupNotify=true
EOF
chmod 644 -- "$desktop_temp"

temporary_link="$install_dir/.current-$$"
ln -s -- "versions/$(basename -- "$staged")" "$temporary_link"
mv -Tf -- "$temporary_link" "$install_dir/current"
temporary_link=''
staged=''
for shortcut in artemis diagnose.sh uninstall.sh; do
    [[ -L $install_dir/$shortcut ]] || ln -s -- "current/$shortcut" "$install_dir/$shortcut"
done
command_temp="$bin_dir/.artemis-steamos-$$"
ln -s -- "$install_dir/current/artemis" "$command_temp"
mv -Tf -- "$command_temp" "$command_path"
command_temp=''
mv -Tf -- "$desktop_temp" "$desktop_path"
desktop_temp=''

# Keep prior payloads until uninstall: a running session may still load plugins
# from its original directory after an update. No user settings are modified.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
fi
printf 'Installed Artemis.\nLaunch: %s\nDiagnostics: %s/diagnose.sh\nUninstall: %s/uninstall.sh\n' "$command_path" "$install_dir" "$install_dir"
printf '%s\n' 'For Gaming Mode, add the installed artemis-steamos launcher to Steam as a non-Steam game (native Linux; no Proton).'
[[ -z $previous ]] || printf '%s\n' 'Previous payloads were retained so running sessions can finish; uninstall removes all installed payloads.'
