#!/bin/sh
# build.sh
#
# Compiles a fully-static rtorrent binary inside an Alpine Linux container.
#
# Required environment variables:
#   VERSION_NUM   rtorrent / libtorrent version without the leading 'v'
#                 (e.g.  0.16.12)
#   RTORRENT_SHA  Git commit hash for rtorrent in case of a nightly build (e.g. 1a2b3c4)
#   LIBTORRENT_SHA Git commit hash for libtorrent in case of a nightly build (e.g. 1a2b3c4)
#   ARCH          Output filename suffix that identifies the target CPU
#                 (e.g.  amd64  or  arm64)
# Optional environment variables:
#   WITH_OPTION   extra build parameter for rtorrent (default: --with-xmlrpc-tinyxml2)
#   SUFFIX        Extra suffix for the output file

set -eux

: "${VERSION_NUM:=}"
: "${RTORRENT_SHA:=}"
: "${LIBTORRENT_SHA:=}"
: "${ARCH:?ARCH must be set (e.g. amd64 or arm64)}"
: "${WITH_OPTION:=--with-xmlrpc-tinyxml2}"
: "${SUFFIX:=}"

if [ -z "${VERSION_NUM}" ] && { [ -z "${RTORRENT_SHA}" ] || [ -z "${LIBTORRENT_SHA}" ]; }; then
    echo "VERSION_NUM must be set for release builds, or RTORRENT_SHA and LIBTORRENT_SHA must be set for nightly builds." >&2
    exit 1
fi

# Set architecture-specific compiler flags
case "${ARCH}" in
    amd64|x86_64)
        ARCH_CFLAGS="-march=x86-64-v2"
        ZLIB_AVX2="OFF"
        ;;
    amd64-gracemont|x86_64-gracemont)
        ARCH_CFLAGS="-march=gracemont -mtune=gracemont"
        ZLIB_AVX2="ON"
        ;;
    amd64-tremont|x86_64-tremont)
        ARCH_CFLAGS="-march=tremont -mtune=tremont"
        ZLIB_AVX2="OFF"
        ;;
    amd64-v3|x86_64-v3)
        ARCH_CFLAGS="-march=x86-64-v3"
        ZLIB_AVX2="ON"
        ;;
    arm64|aarch64)
        ARCH_CFLAGS="-march=armv8-a"
        ZLIB_AVX2="OFF"
        ;;
    *)
        ARCH_CFLAGS=""
        ZLIB_AVX2="OFF"
        ;;
esac
BASE_CFLAGS="${ARCH_CFLAGS} -static -O3 -pipe"

# ---------------------------------------------------------------------------
# 0. Common curl options
# ---------------------------------------------------------------------------
CURL="curl -fsS --retry 10 --retry-delay 5 --connect-timeout 10"
CURL_DL="curl -fsSLO --retry 10 --retry-delay 5 --connect-timeout 10"

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
apk add --no-cache \
    autoconf \
    autoconf-archive \
    automake \
    build-base \
    cmake \
    cppunit-dev \
    curl \
    gawk \
    gettext-dev \
    git \
    jq \
    libtool \
    ninja \
    pkgconf \
    python3

export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ===========================================================================
# Part 1: Get dependency version information
# ===========================================================================

echo "=== Fetching dependency version information ==="

MUSL_VERSION=$(${CURL} "https://api.github.com/repos/ifduyue/musl/tags" | jq -r '.[0].name')
echo "musl version: ${MUSL_VERSION}"

RPMALLOC_VERSION=$(${CURL} "https://api.github.com/repos/mjansson/rpmalloc/releases/latest" | jq -r '.tag_name')
echo "rpmalloc version: ${RPMALLOC_VERSION}"

ZLIB_NG_VERSION=$(${CURL} "https://api.github.com/repos/zlib-ng/zlib-ng/releases/latest" | jq -r '.tag_name')
echo "zlib-ng version: ${ZLIB_NG_VERSION}"

LIBRESSL_VERSION=$(${CURL} "https://api.github.com/repos/libressl/portable/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "libressl version: ${LIBRESSL_VERSION}"

NGHTTP2_VERSION=$(${CURL} "https://api.github.com/repos/nghttp2/nghttp2/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "nghttp2 version: ${NGHTTP2_VERSION}"

LIBPSL_VERSION=$(${CURL} "https://api.github.com/repos/rockdaboot/libpsl/releases/latest" | jq -r '.tag_name')
echo "libpsl version: ${LIBPSL_VERSION}"

CARES_VERSION=$(${CURL} "https://api.github.com/repos/c-ares/c-ares/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "c-ares version: ${CARES_VERSION}"

CURL_TAG=$(${CURL} "https://api.github.com/repos/curl/curl/releases/latest" | jq -r '.tag_name')
CURL_VERSION=$(echo "$CURL_TAG" | sed 's/curl-//' | tr '_' '.')
echo "curl version: ${CURL_VERSION}"

# ===========================================================================
# Part 2: Download dependencies and extract
# ===========================================================================

echo "=== Downloading and extracting dependencies ==="

mkdir -p /build
cd /build

# musl
${CURL_DL} "https://github.com/ifduyue/musl/archive/refs/tags/${MUSL_VERSION}.tar.gz"
tar xf "${MUSL_VERSION}.tar.gz"
MUSL_DIR=$(tar tzf "${MUSL_VERSION}.tar.gz" | head -1 | cut -d/ -f1)

# rpmalloc
${CURL_DL} "https://github.com/mjansson/rpmalloc/archive/refs/tags/${RPMALLOC_VERSION}.tar.gz"
tar xf "${RPMALLOC_VERSION}.tar.gz"

# zlib-ng
${CURL_DL} "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ZLIB_NG_VERSION}.tar.gz"
tar xf "${ZLIB_NG_VERSION}.tar.gz"

# libressl
${CURL_DL} "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VERSION}.tar.gz"
tar xf "libressl-${LIBRESSL_VERSION}.tar.gz"

# nghttp2
${CURL_DL} "https://github.com/nghttp2/nghttp2/archive/refs/tags/v${NGHTTP2_VERSION}.tar.gz"
tar xf "v${NGHTTP2_VERSION}.tar.gz"

# ncurses
${CURL_DL} "https://invisible-island.net/archives/ncurses/ncurses.tar.gz"
tar xf ncurses.tar.gz
NCURSES_DIR=$(tar tzf ncurses.tar.gz | head -1 | cut -d/ -f1)

# libpsl
${CURL_DL} "https://github.com/rockdaboot/libpsl/releases/download/${LIBPSL_VERSION}/libpsl-${LIBPSL_VERSION}.tar.gz"
tar xf "libpsl-${LIBPSL_VERSION}.tar.gz"

# c-ares
${CURL_DL} "https://github.com/c-ares/c-ares/releases/download/v${CARES_VERSION}/c-ares-${CARES_VERSION}.tar.gz"
tar xf "c-ares-${CARES_VERSION}.tar.gz"

# curl
${CURL_DL} "https://github.com/curl/curl/archive/refs/tags/curl-${CURL_VERSION//./_}.tar.gz"
tar xf "curl-${CURL_VERSION//./_}.tar.gz"

# libtorrent
if [ -n "${VERSION_NUM}" ]; then
    ${CURL_DL} "https://github.com/rakshasa/rtorrent/releases/download/v${VERSION_NUM}/libtorrent-${VERSION_NUM}.tar.gz"
    tar xf "libtorrent-${VERSION_NUM}.tar.gz"
else
    git clone --filter=blob:none --single-branch https://github.com/rakshasa/libtorrent.git
    cd libtorrent
    git checkout "$LIBTORRENT_SHA"
    cd /build
fi

# rtorrent
if [ -n "${VERSION_NUM}" ]; then
    ${CURL_DL} "https://github.com/rakshasa/rtorrent/releases/download/v${VERSION_NUM}/rtorrent-${VERSION_NUM}.tar.gz"
    tar xf "rtorrent-${VERSION_NUM}.tar.gz"
else
    git clone --filter=blob:none --single-branch https://github.com/rakshasa/rtorrent.git
    cd rtorrent
    git checkout "$RTORRENT_SHA"
    cd /build
fi

# ===========================================================================
# Part 3: Compile all dependencies and rtorrent
# ===========================================================================

echo "=== Compiling all components ==="

# ---------------------------------------------------------------------------
# 3.1 Build musl libc (C standard library)
# ---------------------------------------------------------------------------
echo "Building musl libc ${MUSL_VERSION}"

cd /build/${MUSL_DIR}

./configure \
    --prefix=/usr/local \
    --disable-shared \
    CFLAGS="${ARCH_CFLAGS} -O3 -pipe"

make -j"$(nproc)"
make install

# Ensure subsequent builds find our musl libc first
export LIBRARY_PATH="/usr/local/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CPATH="/usr/local/include${CPATH:+:$CPATH}"

# ---------------------------------------------------------------------------
# 3.2 Build rpmalloc (modern heap memory allocator)
# ---------------------------------------------------------------------------
echo "Building rpmalloc ${RPMALLOC_VERSION}"

cd /build/rpmalloc-${RPMALLOC_VERSION}

# Map ARCH to rpmalloc architecture name
case "${ARCH}" in
    amd64*|x86_64*)  RPMALLOC_ARCH="x86-64"  ;;
    arm64|aarch64)   RPMALLOC_ARCH="arm64"    ;;
    *)               RPMALLOC_ARCH=""         ;;
esac

python3 configure.py --lto -c release --toolchain gcc ${RPMALLOC_ARCH:+-a "${RPMALLOC_ARCH}"}

ninja -j"$(nproc)" "lib/linux/release/${RPMALLOC_ARCH}/librpmalloc.a"

# Copy the static library (override symbols already included via rpmalloc.c #include "malloc.c")
mkdir -p /usr/local/lib
cp -f "lib/linux/release/${RPMALLOC_ARCH}/librpmalloc.a" /usr/local/lib/

# ---------------------------------------------------------------------------
# 3.3 Build zlib-ng (zlib replacement with optimizations)
# ---------------------------------------------------------------------------
echo "Building zlib-ng ${ZLIB_NG_VERSION}"

cd /build/zlib-ng-${ZLIB_NG_VERSION}

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DZLIB_COMPAT=ON \
    -DWITH_AVX512=OFF \
    -DWITH_AVX2=${ZLIB_AVX2} \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# Remove the system zlib .pc file so pkg-config prefers zlib-ng
rm -f /usr/lib/pkgconfig/zlib.pc 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3.4 Build LibreSSL (replaces OpenSSL)
# ---------------------------------------------------------------------------
echo "Building LibreSSL ${LIBRESSL_VERSION}"

cd /build/libressl-${LIBRESSL_VERSION}

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DLIBRESSL_APPS=OFF \
    -DLIBRESSL_TESTS=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# ---------------------------------------------------------------------------
# 3.5 Build nghttp2 (HTTP/2 library)
# ---------------------------------------------------------------------------
echo "Building nghttp2 ${NGHTTP2_VERSION}"

cd /build/nghttp2-${NGHTTP2_VERSION}

autoreconf -fi
./configure \
    --enable-static \
    --disable-shared \
    --disable-debug \
    --enable-lib-only \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install

# ---------------------------------------------------------------------------
# 3.6 Build ncurses (terminal handling library)
# ---------------------------------------------------------------------------
echo "Building ncurses"

cd /build/${NCURSES_DIR}

# Need to run the configure script from a separate build directory
mkdir -p build && cd build

../configure \
    --prefix=/usr/local \
    --enable-static \
    --disable-shared \
    --enable-pc-files \
    --with-pkg-config-libdir=/usr/local/lib/pkgconfig \
    --without-debug \
    --without-manpages \
    --with-termlib \
    --disable-big-core \
    --disable-big-strings \
    --disable-relink \
    --disable-rpath \
    --without-ada \
    --without-tests \
    --without-progs \
    --with-fallback="linux" \
    --disable-full-macros \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install.libs install.includes

# ---------------------------------------------------------------------------
# 3.7 Build libpsl (Public Suffix List library)
# ---------------------------------------------------------------------------
echo "Building libpsl ${LIBPSL_VERSION}"

cd /build/libpsl-${LIBPSL_VERSION}

./configure \
    --prefix=/usr/local \
    --enable-static \
    --disable-shared \
    --disable-gtk-doc \
    --disable-runtime \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install

# ---------------------------------------------------------------------------
# 3.8 Build c-ares (asynchronous DNS resolver)
# ---------------------------------------------------------------------------
echo "Building c-ares ${CARES_VERSION}"

cd /build/c-ares-${CARES_VERSION}

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DCARES_STATIC=ON \
    -DCARES_SHARED=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# ---------------------------------------------------------------------------
# 3.9 Build curl (HTTP/HTTPS tool and library)
# ---------------------------------------------------------------------------
echo "Building curl ${CURL_VERSION}"

cd /build/curl-curl-${CURL_VERSION//./_}

autoreconf -fi
./configure \
    --prefix=/usr/local \
    --enable-static \
    --disable-shared \
    --disable-debug \
    --disable-unix-sockets \
    --disable-headers-api \
    --disable-alt-svc \
    --disable-hsts \
    --without-brotli \
    --with-openssl \
    --with-nghttp2 \
    --without-nghttp3 \
    --without-ngtcp2 \
    --without-openssl-quic \
    --with-zlib \
    --enable-ares \
    --enable-ipv6 \
    --disable-ldap \
    --disable-ldaps \
    --disable-manual \
    --disable-docs \
    --disable-ipfs \
    --disable-dict \
    --disable-gopher \
    --disable-imap \
    --disable-mqtt \
    --disable-pop3 \
    --disable-rtsp \
    --disable-smb \
    --disable-smtp \
    --disable-telnet \
    --disable-tftp \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install

# ---------------------------------------------------------------------------
# 3.10 Build libtorrent (same version tag as rtorrent)
# ---------------------------------------------------------------------------
echo "Building libtorrent"

if [ -n "${VERSION_NUM}" ]; then
    cd /build/libtorrent-${VERSION_NUM}
else
    cd /build/libtorrent
fi

autoreconf -fi
./configure \
    --enable-static \
    --disable-shared \
    --disable-debug \
    --enable-pthread-setstacksize \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install

# ---------------------------------------------------------------------------
# 3.11 Build rtorrent (same version tag as libtorrent)
# ---------------------------------------------------------------------------
echo "Building rtorrent"

if [ -n "${VERSION_NUM}" ]; then
    cd /build/rtorrent-${VERSION_NUM}
else
    cd /build/rtorrent
fi

autoreconf -fi
./configure \
    ${WITH_OPTION} \
    --enable-static \
    --disable-shared \
    --disable-debug \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS} -flto" \
    CXXFLAGS="${BASE_CFLAGS} -flto"

make -j"$(nproc)" LDFLAGS="-all-static -Wl,--as-needed -flto -lrpmalloc"

# ---------------------------------------------------------------------------
# 3.12 Copy and verify the output binary
# ---------------------------------------------------------------------------
OUTPUT="/output/rtorrent-linux-${ARCH}${SUFFIX}"

cp src/rtorrent "${OUTPUT}"
strip "${OUTPUT}"

echo "=== Build complete ==="
file "${OUTPUT}"
ls -lh "${OUTPUT}"
