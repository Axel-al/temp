#!/usr/bin/env bash
set -euo pipefail
mkdir -p .steamdeck/reports
work=$(mktemp -d '/tmp/artemis smoke.XXXXXX')
trap 'rm -rf -- "$work"' EXIT
cp -a dist/artemis-steamos-x86_64 "$work/package"
mkdir -p "$work/home" "$work/runtime"
chmod 700 "$work/runtime"
# A different path, clean home, no SDK environment and deliberately hostile Qt paths.
run_clean() {
  env -i PATH=/usr/bin:/bin HOME="$work/home" XDG_RUNTIME_DIR="$work/runtime" \
    QT_PLUGIN_PATH=/nonexistent QML_IMPORT_PATH=/nonexistent LD_LIBRARY_PATH=/nonexistent \
    "$@"
}
run_clean "$work/package/artemis" --version 2>&1 | tee .steamdeck/reports/version.txt
grep -q '0.6.7' .steamdeck/reports/version.txt
for platform in offscreen xcb; do
  set +e
  if [[ $platform == xcb ]]; then
    run_clean xvfb-run -a env QT_QPA_PLATFORM=xcb QT_QUICK_BACKEND=software QT_DEBUG_PLUGINS=1 \
      timeout --signal=TERM --kill-after=5 20 "$work/package/artemis" > ".steamdeck/reports/gui-$platform.log" 2>&1
  else
    run_clean env QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_DEBUG_PLUGINS=1 \
      timeout --signal=TERM --kill-after=5 20 "$work/package/artemis" > ".steamdeck/reports/gui-$platform.log" 2>&1
  fi
  status=$?
  set -e
  cat ".steamdeck/reports/gui-$platform.log"
  [[ $status == 124 ]] || { echo "GUI exited before the 20-second smoke window: $status"; exit 1; }
  if grep -Ei 'QQmlApplicationEngine failed|module .* is not installed|error while loading shared libraries|Could not load the Qt platform plugin|Cannot load library.*(not found|undefined symbol)' ".steamdeck/reports/gui-$platform.log"; then
    exit 1
  fi
  grep -q "$work/package/plugins/platforms/" ".steamdeck/reports/gui-$platform.log"
done
# Exercise the user installer without touching the runner's real home.
run_clean "$work/package/install.sh"
run_clean "$work/home/.local/bin/artemis-steamos" --version
run_clean "$work/package/install.sh"
run_clean "$work/home/.local/opt/artemis-steamos/uninstall.sh"
test ! -e "$work/home/.local/bin/artemis-steamos"
printf 'Relocated CLI, offscreen GUI, X11 GUI, user install/update/uninstall passed. No GPU streaming tested.\n' \
  > .steamdeck/reports/smoke-summary.txt
