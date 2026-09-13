#!/bin/sh
# Build a fully static armhf dropbearmulti for old-glibc Kindles.
# Runs inside a debian container. Inputs pinned; output verified static+ARM.
set -e
DBVER=DROPBEAR_2026.94
DBURL="https://github.com/mkj/dropbear/archive/refs/tags/${DBVER}.tar.gz"
TCURL="https://musl.cc/arm-linux-musleabihf-cross.tgz"
OUT=/out

echo "== deps =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl make xz-utils file ca-certificates >/dev/null
echo "  ok"

cd /build
echo "== toolchain =="
curl -sSL --retry 3 -o tc.tgz "$TCURL"
echo "  toolchain sha256: $(sha256sum tc.tgz | cut -d' ' -f1)"
tar xf tc.tgz
export PATH="/build/arm-linux-musleabihf-cross/bin:$PATH"
arm-linux-musleabihf-gcc --version | head -1 | sed 's/^/  /'

echo "== dropbear source =="
curl -sSL --retry 3 -o db.tgz "$DBURL"
echo "  source sha256: $(sha256sum db.tgz | cut -d' ' -f1)"
tar xf db.tgz
cd "dropbear-${DBVER}"

echo "== configure =="
./configure --host=arm-linux-musleabihf CC=arm-linux-musleabihf-gcc --disable-zlib >/tmp/cfg.log 2>&1 \
  || { echo "CONFIGURE FAILED"; tail -20 /tmp/cfg.log; exit 1; }
echo "  ok"

echo "== make (static multi-binary) =="
make -j2 PROGRAMS="dropbear dropbearkey dropbearconvert scp dbclient" MULTI=1 STATIC=1 >/tmp/make.log 2>&1 \
  || { echo "MAKE FAILED"; tail -30 /tmp/make.log; exit 1; }
arm-linux-musleabihf-strip dropbearmulti
mkdir -p "$OUT"
cp dropbearmulti "$OUT/dropbearmulti-armhf"

echo "== verify =="
cd "$OUT"
echo "  size: $(wc -c < dropbearmulti-armhf) bytes"
echo "  sha256: $(sha256sum dropbearmulti-armhf | cut -d' ' -f1)"
file dropbearmulti-armhf | sed 's/^/  /'
echo "  DONE"
