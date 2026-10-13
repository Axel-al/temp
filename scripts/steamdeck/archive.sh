#!/usr/bin/env bash
set -euo pipefail
root=$(pwd)
package="$root/dist/artemis-steamos-x86_64"
sources="$root/.steamdeck/corresponding-sources"
mkdir -p "$sources" "$package/share/build-info"
cp -a .steamdeck/reports/. "$package/share/build-info/"
cp -a .steamdeck/source-archives/. "$sources/"
git archive --format=tar HEAD | tar -xf - -C "$sources"
export STEAMDECK_SOURCE_DIR="$sources"
# shellcheck disable=SC2016 # These variables belong to git's submodule shell.
git submodule foreach --recursive 'mkdir -p "$STEAMDECK_SOURCE_DIR/$displaypath"; git archive --format=tar HEAD | tar -xf - -C "$STEAMDECK_SOURCE_DIR/$displaypath"'
python3 - "$package/share/dependency-manifest.json" > "$sources/ubuntu-source-packages.txt" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for name, version in sorted({(p['source_package'], p['source_version']) for p in m['system_packages']}):
    print(f'{name}={version}')
PY
mkdir -p "$sources/ubuntu"
while IFS= read -r spec; do
  (cd "$sources/ubuntu" && apt-get source --download-only "$spec")
done < "$sources/ubuntu-source-packages.txt"
# Qt's SDK supplies ICU as a separate dependency. Redistribute its matching release source.
icu_so=$(find "$QT_ROOT/lib" -maxdepth 1 -type f -name 'libicuuc.so.*' | head -1)
if [[ -n $icu_so ]]; then
  version=${icu_so##*.so.}
  # Official Qt 6.8.3 Linux SDK uses ICU 73.2; fail rather than fetch mismatched sources.
  [[ $version == 73.2 ]] || { echo "Review corresponding ICU source version: $version"; exit 1; }
  curl -fL --retry 3 https://github.com/unicode-org/icu/releases/download/release-73-2/icu4c-73_2-src.tgz \
    -o "$sources/icu4c-73_2-src.tgz"
  tar -xOf "$sources/icu4c-73_2-src.tgz" icu/LICENSE > "$package/share/licenses/ICU-LICENSE"
fi
cp "$package/share/dependency-manifest.json" "$sources/"
cp -a .steamdeck/reports "$sources/build-reports"
cat > "$package/share/licenses/REDISTRIBUTION.txt" <<'EOF'
Artemis is free software under GPL version 3; see Artemis-LICENSE (or LICENSE).
This package uses dynamically linked Qt 6.8.3 (LGPLv3/GPLv3), FFmpeg 6.1.4
(LGPLv3 with --enable-version3, no GPL/nonfree components enabled), libplacebo
(LGPLv2.1+), SDL2/SDL_ttf (zlib), Opus (BSD) and other libraries listed in
share/dependency-manifest.json and their accompanying copyright notices.

The matching artemis-steamos-sources.tar.gz is provided in the SAME Actions
artifact as this binary. Keep and redistribute it alongside the binary.
It includes application/submodule code, exact upstream source archives, Ubuntu
source packages (including packaging patches), and the build scripts/config.
GitHub artifacts expire: archive BOTH packages if you plan to redistribute later.

You may inspect, modify, debug and replace the shared libraries in lib/ and
plugins/ and rebuild the application. There is no signature lock. No additional
restriction on reverse engineering for debugging modified libraries is imposed.
Third-party components retain their own licenses. No warranty is provided.
EOF
find "$sources" -type f -print0 | sort -z | xargs -0 sha256sum > .steamdeck/reports/source-checksums.txt
tar -C .steamdeck -czf dist/artemis-steamos-sources.tar.gz corresponding-sources
tar -C dist -czf dist/artemis-steamos-x86_64.tar.gz artemis-steamos-x86_64
(cd dist && sha256sum artemis-steamos-x86_64.tar.gz artemis-steamos-sources.tar.gz > SHA256SUMS)
