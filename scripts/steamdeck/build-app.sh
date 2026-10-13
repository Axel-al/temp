#!/usr/bin/env bash
set -euo pipefail
root=$(pwd)
export PATH="$QT_ROOT/bin:$DEPS_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib:$QT_ROOT/lib"
mkdir -p .steamdeck/build .steamdeck/reports
cd .steamdeck/build
"$QT_ROOT/bin/qmake6" "$root/artemis.pro" CONFIG+=release CONFIG-=debug_and_release \
  'QMAKE_CXXFLAGS+=-fPIC' 'QMAKE_CFLAGS+=-fPIC' 2>&1 | tee ../reports/qmake.log
for feature in HAVE_FFMPEG HAVE_LIBVA HAVE_LIBVA_X11 HAVE_LIBVA_WAYLAND HAVE_LIBVA_DRM HAVE_DRM HAVE_LIBPLACEBO_VULKAN HAVE_EGL HAS_WAYLAND HAS_X11; do
  grep -q -- "-D$feature\b" app/Makefile || { echo "Missing required feature: $feature"; exit 1; }
done
make -j4 2>&1 | tee ../reports/build.log
"$DEPS_PREFIX/bin/ffmpeg" -hide_banner -decoders > ../reports/ffmpeg-decoders.txt
"$DEPS_PREFIX/bin/ffmpeg" -hide_banner -hwaccels > ../reports/ffmpeg-hwaccels.txt
for codec in h264 hevc av1; do grep -qw "$codec" ../reports/ffmpeg-decoders.txt; done
grep -qw vaapi ../reports/ffmpeg-hwaccels.txt
grep -qw vulkan ../reports/ffmpeg-hwaccels.txt
pkg-config --modversion libavcodec libavutil libplacebo sdl2 SDL2_ttf opus > ../reports/dependency-versions.txt
dpkg-query -W > ../reports/ubuntu-packages.tsv
