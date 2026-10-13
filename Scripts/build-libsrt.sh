#!/usr/bin/env bash
# =============================================================================
#  build-libsrt.sh
#  Compila la biblioteca oficial Haivision SRT (libsrt) + mbedTLS como
#  librerías estáticas para iOS y genera Vendor/libsrt.xcframework.
#
#  Slices generados:
#    - ios-arm64                    (iPhone / iPad)
#    - ios-arm64_x86_64-simulator   (Simulador en Mac Apple Silicon e Intel)
#
#  Requisitos (macOS):  Xcode 15+,  cmake >= 3.21,  git
#      brew install cmake
#
#  Uso:
#      ./Scripts/build-libsrt.sh
#      SRT_VERSION=v1.5.4 MBEDTLS_VERSION=v3.6.2 ./Scripts/build-libsrt.sh
#
#  Notas de criptografía:
#    - SRT usa AES-CTR con claves de 128/192/256 bits (SRTO_PBKEYLEN 16/24/32).
#    - Se usa mbedTLS (Apache-2.0) en lugar de OpenSSL porque compila limpio
#      para iOS con CMake y no requiere scripts de terceros.
#    - Si tu versión de SRT no compilara contra mbedTLS 3.x, usá la rama 2.28 LTS:
#          MBEDTLS_VERSION=v2.28.9 ./Scripts/build-libsrt.sh
# =============================================================================
set -euo pipefail

SRT_VERSION="${SRT_VERSION:-v1.5.4}"
MBEDTLS_VERSION="${MBEDTLS_VERSION:-v3.6.2}"
IOS_MIN="${IOS_MIN:-16.0}"
# Simulador Intel (x86_64). En CI se desactiva (INCLUDE_X86_SIM=0) para ahorrar minutos.
INCLUDE_X86_SIM="${INCLUDE_X86_SIM:-1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/libsrt"
SRC="$WORK/src"
OUT_DIR="$ROOT/Vendor"
XCFRAMEWORK="$OUT_DIR/libsrt.xcframework"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

log() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }

command -v cmake >/dev/null || { echo "Falta cmake (brew install cmake)"; exit 1; }
command -v xcrun >/dev/null || { echo "Este script requiere macOS + Xcode"; exit 1; }

mkdir -p "$SRC" "$OUT_DIR"

# -----------------------------------------------------------------------------
# 1. Fuentes
# -----------------------------------------------------------------------------
if [ ! -d "$SRC/mbedtls" ]; then
  log "Clonando mbedTLS $MBEDTLS_VERSION"
  git clone --depth 1 --branch "$MBEDTLS_VERSION" --recurse-submodules --shallow-submodules \
      https://github.com/Mbed-TLS/mbedtls.git "$SRC/mbedtls"
fi
if [ ! -d "$SRC/srt" ]; then
  log "Clonando SRT $SRT_VERSION"
  git clone --depth 1 --branch "$SRT_VERSION" https://github.com/Haivision/srt.git "$SRC/srt"
fi

# -----------------------------------------------------------------------------
# 2. Compilación por slice (sdk + arquitectura)
# -----------------------------------------------------------------------------
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

  # Unifica libsrt + mbedTLS en una única .a para simplificar el linkeo.
  log "Fusionando librerías estáticas → $name"
  local libs=("$prefix/lib/libsrt.a" "$prefix/lib/libmbedtls.a" "$prefix/lib/libmbedx509.a" "$prefix/lib/libmbedcrypto.a")
  # mbedTLS 3.x puede generar estas auxiliares (vacías con la config por defecto).
  for extra in libeverest.a libp256m.a; do
    [ -f "$prefix/lib/$extra" ] && libs+=("$prefix/lib/$extra")
  done
  libtool -static -no_warning_for_no_symbols -o "$prefix/lib/libsrt-ios.a" "${libs[@]}"
}

build_slice iphoneos        arm64
build_slice iphonesimulator arm64
[ "$INCLUDE_X86_SIM" = "1" ] && build_slice iphonesimulator x86_64

# -----------------------------------------------------------------------------
# 3. Binario del simulador (universal si se compiló x86_64)
# -----------------------------------------------------------------------------
SIM_UNI="$WORK/install/iphonesimulator-universal"
mkdir -p "$SIM_UNI/lib"
SIM_LIBS=("$WORK/install/iphonesimulator-arm64/lib/libsrt-ios.a")
[ "$INCLUDE_X86_SIM" = "1" ] && SIM_LIBS+=("$WORK/install/iphonesimulator-x86_64/lib/libsrt-ios.a")
lipo -create "${SIM_LIBS[@]}" -output "$SIM_UNI/lib/libsrt-ios.a"

# -----------------------------------------------------------------------------
# 4. Headers públicos (solo srt/*.h; mbedTLS es un detalle interno)
# -----------------------------------------------------------------------------
HEADERS="$WORK/headers"
rm -rf "$HEADERS"; mkdir -p "$HEADERS/srt"
cp "$WORK/install/iphoneos-arm64/include/srt/"*.h "$HEADERS/srt/"

# -----------------------------------------------------------------------------
# 5. XCFramework
# -----------------------------------------------------------------------------
log "Creando $XCFRAMEWORK"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$WORK/install/iphoneos-arm64/lib/libsrt-ios.a" -headers "$HEADERS" \
  -library "$SIM_UNI/lib/libsrt-ios.a"                      -headers "$HEADERS" \
  -output "$XCFRAMEWORK"

log "Listo: $XCFRAMEWORK  (SRT $SRT_VERSION + mbedTLS $MBEDTLS_VERSION)"
