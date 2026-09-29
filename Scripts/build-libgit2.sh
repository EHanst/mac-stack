#!/bin/zsh
# Builds a static libgit2 into Vendor/libgit2 (include/ + lib/libgit2.a) from a pinned release.
# The app only uses local repository operations, so SSH, HTTPS and threads-over-network are off:
# the result depends on nothing outside macOS itself and can be signed and notarized.
# Needs: cmake, curl. Run once after cloning (and again when you change the version below).
set -euo pipefail
VERSION=1.9.7
SHA256=1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7
ROOT=${0:A:h:h}
OUT=$ROOT/Vendor/libgit2
if [[ -f $OUT/lib/libgit2.a && -f $OUT/VERSION && $(<$OUT/VERSION) == $VERSION ]]; then echo "libgit2 $VERSION already built"; exit 0; fi
WORK=$(mktemp -d); trap 'rm -rf $WORK' EXIT
curl -fsSL "https://github.com/libgit2/libgit2/archive/refs/tags/v$VERSION.tar.gz" -o $WORK/src.tgz
[[ $(shasum -a 256 $WORK/src.tgz | cut -d' ' -f1) == $SHA256 ]] || { echo "checksum mismatch"; exit 1; }
tar -xzf $WORK/src.tgz -C $WORK
cmake -S $WORK/libgit2-$VERSION -B $WORK/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF -DUSE_SSH=OFF -DUSE_HTTPS=OFF -DUSE_AUTH_NTLM=OFF \
  -DUSE_AUTH_NEGOTIATE=OFF -DUSE_BUNDLED_ZLIB=ON -DREGEX_BACKEND=builtin -DUSE_HTTP_PARSER=builtin \
  -DUSE_NSEC=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_INSTALL_PREFIX=$OUT.tmp -DCMAKE_POSITION_INDEPENDENT_CODE=ON >/dev/null
cmake --build $WORK/build -j8 >/dev/null
rm -rf $OUT $OUT.tmp; cmake --install $WORK/build >/dev/null
mkdir -p $OUT; mv $OUT.tmp/include $OUT/include; mkdir $OUT/lib; cp $OUT.tmp/lib/libgit2.a $OUT/lib/; rm -rf $OUT.tmp
cp $WORK/libgit2-$VERSION/COPYING $OUT/COPYING
echo $VERSION > $OUT/VERSION
echo "built libgit2 $VERSION -> $OUT"
