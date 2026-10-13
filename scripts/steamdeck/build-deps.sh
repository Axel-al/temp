#!/usr/bin/env bash
set -euo pipefail
root=$(pwd)
export DEPS_PREFIX=${DEPS_PREFIX:-$root/.steamdeck/prefix}
export QT_ROOT=${QT_ROOT:-$root/.steamdeck/qt/6.8.3/gcc_64}
mkdir -p .steamdeck/{sources,source-archives,reports} "$DEPS_PREFIX/share/licenses"
python3 -m venv .steamdeck/tools
.steamdeck/tools/bin/pip install aqtinstall==3.3.0 meson==1.5.2 Jinja2==3.1.6
export PATH="$root/.steamdeck/tools/bin:$DEPS_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib"
aqt install-qt linux desktop 6.8.3 linux_gcc_64 -O "$root/.steamdeck/qt" \
  --archives qtbase qtdeclarative qtsvg qtwayland qtshadertools qtimageformats qttranslations icu

checkout() {
  local name=$1 url=$2 revision=$3
  git init ".steamdeck/sources/$name"
  git -C ".steamdeck/sources/$name" remote add origin "$url"
  git -C ".steamdeck/sources/$name" fetch --depth 1 origin "$revision"
  git -C ".steamdeck/sources/$name" checkout --detach FETCH_HEAD
  test "$(git -C ".steamdeck/sources/$name" rev-parse HEAD)" = "$revision"
  git -C ".steamdeck/sources/$name" submodule update --init --recursive
  printf '%s\t%s\t%s\n' "$name" "$url" "$revision" >> .steamdeck/reports/source-lock.tsv
  tar --exclude=.git -C .steamdeck/sources -czf ".steamdeck/source-archives/$name.tar.gz" "$name"
  mkdir -p "$DEPS_PREFIX/share/licenses/$name"
  find ".steamdeck/sources/$name" -maxdepth 1 -type f \( -iname '*license*' -o -iname '*copying*' -o -iname '*copyright*' \) \
    -exec cp -t "$DEPS_PREFIX/share/licenses/$name" {} +
}
checkout SDL2 https://github.com/libsdl-org/SDL.git 5d249570393f7a37e037abf22cd6012a4cc56a71
cmake -S .steamdeck/sources/SDL2 -B .steamdeck/sdl-build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF -DSDL_VULKAN=ON -DSDL_WAYLAND=ON \
  -DSDL_X11=ON -DSDL_ALSA=ON -DSDL_PULSEAUDIO=ON -DSDL_PIPEWIRE=ON
cmake --build .steamdeck/sdl-build --parallel 4
cmake --install .steamdeck/sdl-build
checkout SDL2_ttf https://github.com/libsdl-org/SDL_ttf.git 2a891473eaf05ba1707a4b7913e6c4db7de7458a
cmake -S .steamdeck/sources/SDL2_ttf -B .steamdeck/ttf-build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=ON -DSDL2TTF_SAMPLES=OFF -DSDL2TTF_VENDORED=OFF
cmake --build .steamdeck/ttf-build --parallel 4
cmake --install .steamdeck/ttf-build

checkout Vulkan-Headers https://github.com/KhronosGroup/Vulkan-Headers.git b379292b2ab6df5771ba9870d53cf8b2c9295daf
cmake -S .steamdeck/sources/Vulkan-Headers -B .steamdeck/vulkan-headers-build -G Ninja -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX"
cmake --install .steamdeck/vulkan-headers-build
# Modern headers, with the system Vulkan loader. The loader and GPU ICDs are never redistributed.
cat > "$DEPS_PREFIX/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$DEPS_PREFIX
Name: Vulkan
Description: Vulkan 1.3.290 headers with host loader
Version: 1.3.290
Libs: -lvulkan
Cflags: -I\${prefix}/include
EOF
checkout libplacebo https://github.com/haasn/libplacebo.git 9c4b6bbd7a1e223ffdd61affc4e5d463d42d4345
meson setup .steamdeck/placebo-build .steamdeck/sources/libplacebo \
  --prefix "$DEPS_PREFIX" --libdir lib --buildtype release -Ddefault_library=shared \
  -Dvulkan=enabled -Dshaderc=enabled -Dglslang=disabled -Dopengl=disabled -Ddemos=false -Dtests=false
ninja -C .steamdeck/placebo-build -j4
ninja -C .steamdeck/placebo-build install
checkout FFmpeg https://github.com/FFmpeg/FFmpeg.git 34277e12e80031c7f89494ba543684bc1dd0be8f
(
  cd .steamdeck/sources/FFmpeg
  ./configure --prefix="$DEPS_PREFIX" --libdir="$DEPS_PREFIX/lib" \
    --enable-shared --disable-static --disable-doc --disable-debug \
    --disable-autodetect --enable-pthreads --enable-vaapi --enable-vdpau --enable-vulkan \
    --enable-libdrm --enable-libdav1d --enable-openssl --enable-version3 \
    --extra-cflags="-I$DEPS_PREFIX/include" --extra-ldflags="-L$DEPS_PREFIX/lib" \
    2>&1 | tee "$root/.steamdeck/reports/ffmpeg-configure.log"
  make -j4
  make install
  cp ffbuild/config.mak "$root/.steamdeck/reports/ffmpeg-config.mak"
)
for module in qtbase qtdeclarative qtsvg qtwayland qtshadertools qtimageformats qttranslations; do
  archive="$module-everywhere-src-6.8.3.tar.xz"
  url="https://download.qt.io/archive/qt/6.8/6.8.3/submodules/$archive"
  curl -fL --retry 3 "$url" -o ".steamdeck/source-archives/$archive"
  curl -fL --retry 3 "$url.sha256" -o ".steamdeck/source-archives/$archive.sha256"
  (cd .steamdeck/source-archives && sha256sum -c "$archive.sha256")
  mkdir -p "$DEPS_PREFIX/share/licenses/Qt/$module"
  tar -tf ".steamdeck/source-archives/$archive" | grep -Ei '/(LICENSES/|[^/]*(LICENSE|COPYING|COPYRIGHT)[^/]*$)' > ".steamdeck/$module-notices.txt"
  tar -xf ".steamdeck/source-archives/$archive" -C "$DEPS_PREFIX/share/licenses/Qt/$module" \
    -T ".steamdeck/$module-notices.txt"
done
# Source archives remain alongside the binaries for LGPL/GPL redistribution.
cp .steamdeck/reports/source-lock.tsv "$DEPS_PREFIX/share/licenses/"
