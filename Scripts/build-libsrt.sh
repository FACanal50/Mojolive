#!/usr/bin/env bash
set -euo pipefail

SRT_VERSION="${SRT_VERSION:-v1.5.4}"
MBEDTLS_VERSION="${MBEDTLS_VERSION:-v3.6.2}"
IOS_MIN="${IOS_MIN:-16.0}"
INCLUDE_X86_SIM="${INCLUDE_X86_SIM:-1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/libsrt"
SRC="$WORK/src"
OUT_DIR="$ROOT/Vendor"
XCFRAMEWORK="$OUT_DIR/libsrt.xcframework"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

log() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }

command -v cmake >/dev/null || { echo "Falta cmake"; exit 1; }
command -v xcrun >/dev/null || { echo "Requiere macOS"; exit 1; }

mkdir -p "$SRC" "$OUT_DIR"

if [ ! -d "$SRC/mbedtls" ]; then
  log "Clonando mbedTLS $MBEDTLS_VERSION"
  git clone --depth 1 --branch "$MBEDTLS_VERSION" --recurse-submodules --shallow-submodules https://github.com/Mbed-TLS/mbedtls.git "$SRC/mbedtls"
fi
if [ ! -d "$SRC/srt" ]; then
  log "Clonando SRT $SRT_VERSION"
  git clone --depth 1 --branch "$SRT_VERSION" https://github.com/Haivision/srt.git "$SRC/srt"
fi

build_slice() {
  local sdk="$1" arch="$2"
  local name="$sdk-$arch"
  local prefix="$WORK/install/$name"
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  local common=(
    -G "Unix Makefiles"
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_SYSROOT="$sysroot"
    -DCMAKE_OSX_ARCHITECTURES="$arch"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DCMAKE_FIND_ROOT_PATH="$prefix"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  )

  log "mbedTLS → $name"
  cmake -S "$SRC/mbedtls" -B "$WORK/build/$name/mbedtls" "${common[@]}" \
        -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
        -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
        -DMBEDTLS_FATAL_WARNINGS=OFF
  cmake --build "$WORK/build/$name/mbedtls" --target install -j "$JOBS"

  log "SRT → $name"
  cmake -S "$SRC/srt" -B "$WORK/build/$name/srt" "${common[@]}" \
        -DENABLE_APPS=OFF -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
        -DENABLE_CXX11=ON -DENABLE_ENCRYPTION=ON \
        -DUSE_ENCLIB=mbedtls \
        -DSSL_INCLUDE_DIRS="$prefix/include" \
        -DSSL_LIBRARY_DIRS="$prefix/lib" \
        -DSSL_LIBRARIES="mbedtls;mbedx509;mbedcrypto" \
        -DENABLE_LOGGING=ON -DENABLE_HEAVY_LOGGING=OFF \
        -DENABLE_BONDING=OFF
  cmake --build "$WORK/build/$name/srt" --target install -j "$JOBS"

  log "Fusionando librerías estáticas → $name"
  local libs=("$prefix/lib/libsrt.a" "$prefix/lib/libmbedtls.a" "$prefix/lib/libmbedx509.a" "$prefix/lib/libmbedcrypto.a")
  for extra in libeverest.a libp256m.a; do
    [ -f "$prefix/lib/$extra" ] && libs+=("$prefix/lib/$extra")
  done
  libtool -static -no_warning_for_no_symbols -o "$prefix/lib/libsrt-ios.a" "${libs[@]}"
}

build_slice iphoneos        arm64
build_slice iphonesimulator arm64
[ "$INCLUDE_X86_SIM" = "1" ] && build_slice iphonesimulator x86_64

SIM_UNI="$WORK/install/iphonesimulator-universal"
mkdir -p "$SIM_UNI/lib"
SIM_LIBS=("$WORK/install/iphonesimulator-arm64/lib/libsrt-ios.a")
[ "$INCLUDE_X86_SIM" = "1" ] && SIM_LIBS+=("$WORK/install/iphonesimulator-x86_64/lib/libsrt-ios.a")
lipo -create "${SIM_LIBS[@]}" -output "$SIM_UNI/lib/libsrt-ios.a"

HEADERS="$WORK/headers"
rm -rf "$HEADERS"; mkdir -p "$HEADERS/srt"
cp "$WORK/install/iphoneos-arm64/include/srt/"*.h "$HEADERS/srt/"

log "Creando $XCFRAMEWORK"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$WORK/install/iphoneos-arm64/lib/libsrt-ios.a" -headers "$HEADERS" \
  -library "$SIM_UNI/lib/libsrt-ios.a"                      -headers "$HEADERS" \
  -output "$XCFRAMEWORK"

log "Listo: $XCFRAMEWORK"