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
    amd64|x86_64)  ARCH_CFLAGS="-march=x86-64-v2"  ;;
    arm64|aarch64) ARCH_CFLAGS="-march=armv8-a"    ;;
    *)             ARCH_CFLAGS=""                   ;;
esac
BASE_CFLAGS="${ARCH_CFLAGS} -flto -static -O3 -pipe"

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

# ---------------------------------------------------------------------------
# 2. Build zlib-ng (zlib replacement with optimizations)
# ---------------------------------------------------------------------------
ZLIB_NG_VERSION=$(curl -fsS "https://api.github.com/repos/zlib-ng/zlib-ng/releases/latest" | jq -r '.tag_name')
echo "Latest zlib-ng version: ${ZLIB_NG_VERSION}"

mkdir -p /build
cd /build
curl -fsSLO "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ZLIB_NG_VERSION}.tar.gz"
tar xf "${ZLIB_NG_VERSION}.tar.gz"
cd "zlib-ng-${ZLIB_NG_VERSION}"

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DZLIB_COMPAT=ON \
    -DWITH_AVX512=OFF \
    -DWITH_AVX2=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# Remove the system zlib .pc file so pkg-config prefers zlib-ng
rm -f /usr/lib/pkgconfig/zlib.pc 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Build LibreSSL (replaces OpenSSL)
# ---------------------------------------------------------------------------
LIBRESSL_VERSION=$(curl -fsS "https://api.github.com/repos/libressl/portable/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "Latest LibreSSL version: ${LIBRESSL_VERSION}"

cd /build
curl -fsSLO "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VERSION}.tar.gz"
tar xf "libressl-${LIBRESSL_VERSION}.tar.gz"
cd "libressl-${LIBRESSL_VERSION}"

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
# 4. Build nghttp2 (HTTP/2 library)
# ---------------------------------------------------------------------------
NGHTTP2_VERSION=$(curl -fsS "https://api.github.com/repos/nghttp2/nghttp2/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "Latest nghttp2 version: ${NGHTTP2_VERSION}"

cd /build
curl -fsSLO "https://github.com/nghttp2/nghttp2/archive/refs/tags/v${NGHTTP2_VERSION}.tar.gz"
tar xf "v${NGHTTP2_VERSION}.tar.gz"
cd "nghttp2-${NGHTTP2_VERSION}"

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
# 5. Build ncurses (terminal handling library)
# ---------------------------------------------------------------------------

cd /build
curl -fsSLO "https://invisible-island.net/archives/ncurses/ncurses.tar.gz"
tar xf ncurses.tar.gz
NCURSES_DIR=$(tar tzf ncurses.tar.gz | head -1 | cut -d/ -f1)
cd "$NCURSES_DIR"

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
# 6. Build libpsl (Public Suffix List library)
# ---------------------------------------------------------------------------
LIBPSL_VERSION=$(curl -fsS "https://api.github.com/repos/rockdaboot/libpsl/releases/latest" | jq -r '.tag_name')
echo "Latest libpsl version: ${LIBPSL_VERSION}"

cd /build
curl -fsSLO "https://github.com/rockdaboot/libpsl/releases/download/${LIBPSL_VERSION}/libpsl-${LIBPSL_VERSION}.tar.gz"
tar xf "libpsl-${LIBPSL_VERSION}.tar.gz"
cd "libpsl-${LIBPSL_VERSION}"

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
# 7. Build curl (HTTP/HTTPS tool and library)
# ---------------------------------------------------------------------------
CURL_TAG=$(curl -fsS "https://api.github.com/repos/curl/curl/releases/latest" | jq -r '.tag_name')
CURL_VERSION=$(echo "$CURL_TAG" | sed 's/curl-//' | tr '_' '.')
echo "Latest curl version: ${CURL_VERSION}"

cd /build
curl -fsSLO "https://github.com/curl/curl/archive/refs/tags/curl-${CURL_VERSION//./_}.tar.gz"
tar xf "curl-${CURL_VERSION//./_}.tar.gz"
cd "curl-curl-${CURL_VERSION//./_}"

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
    --disable-ares \
    --without-brotli \
    --with-openssl \
    --with-nghttp2 \
    --without-nghttp3 \
    --without-ngtcp2 \
    --without-openssl-quic \
    --with-zlib \
    --enable-ipv6 \
    --disable-ldap \
    --disable-ldaps \
    --disable-manual \
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
# 8. Build rpmalloc (modern heap memory allocator)
# ---------------------------------------------------------------------------
RPMALLOC_VERSION=$(curl -fsS "https://api.github.com/repos/mjansson/rpmalloc/releases/latest" | jq -r '.tag_name')
echo "Latest rpmalloc version: ${RPMALLOC_VERSION}"

cd /build
curl -fsSLO "https://github.com/mjansson/rpmalloc/archive/refs/tags/${RPMALLOC_VERSION}.tar.gz"
tar xf "${RPMALLOC_VERSION}.tar.gz"
cd "rpmalloc-${RPMALLOC_VERSION}"

CFLAGS="${BASE_CFLAGS}" python3 configure.py --override

ninja -j"$(nproc)"

# Copy the static library manually (install target may not exist)
mkdir -p /usr/local/lib
cp -f "bin/$(uname -m)-linux/release/librpmalloc.a" /usr/local/lib/
cp -f "bin/$(uname -m)-linux/release/librpmallocwrap.a" /usr/local/lib/ 2>/dev/null || true

# ---------------------------------------------------------------------------
# 9. Build libtorrent (same version tag as rtorrent)
# ---------------------------------------------------------------------------
cd /build

# If VERSION_NUM is set, we download the source tarball for that version. This is the default behavior for release builds.
# If VERSION_NUM is not set, we clone the git repository and checkout the specified commit. This is used for nightly builds that do not have a version tag.
if [ -n "${VERSION_NUM}" ]; then
    curl -fsSLO \
        "https://github.com/rakshasa/rtorrent/releases/download/v${VERSION_NUM}/libtorrent-${VERSION_NUM}.tar.gz"
    tar xf "libtorrent-${VERSION_NUM}.tar.gz"
    cd "libtorrent-${VERSION_NUM}"
else
    git clone --filter=blob:none --single-branch https://github.com/rakshasa/libtorrent.git
    cd libtorrent
    git checkout "$LIBTORRENT_SHA"
fi

autoreconf -fi
./configure \
    --enable-static \
    --disable-shared \
    --disable-debug \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install

# ---------------------------------------------------------------------------
# 10. Build rtorrent (same version tag as libtorrent)
# ---------------------------------------------------------------------------
cd /build

if [ -n "${VERSION_NUM}" ]; then
    curl -fsSLO \
        "https://github.com/rakshasa/rtorrent/releases/download/v${VERSION_NUM}/rtorrent-${VERSION_NUM}.tar.gz"
    tar xf "rtorrent-${VERSION_NUM}.tar.gz"
    cd "rtorrent-${VERSION_NUM}"
else
    git clone --filter=blob:none --single-branch https://github.com/rakshasa/rtorrent.git
    cd rtorrent
    git checkout "$RTORRENT_SHA"
fi

autoreconf -fi
./configure \
    ${WITH_OPTION} \
    --enable-static \
    --disable-shared \
    --disable-debug \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)" LDFLAGS="-all-static -Wl,--as-needed -flto -Wl,--whole-archive /usr/local/lib/librpmalloc.a -Wl,--no-whole-archive"

# ---------------------------------------------------------------------------
# 11. Copy and verify the output binary
# ---------------------------------------------------------------------------
OUTPUT="/output/rtorrent-linux-${ARCH}${SUFFIX}"

cp src/rtorrent "${OUTPUT}"
strip "${OUTPUT}"

echo "=== Build complete ==="
file "${OUTPUT}"
ls -lh "${OUTPUT}"
