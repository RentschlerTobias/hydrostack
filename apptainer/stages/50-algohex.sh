#!/usr/bin/env bash
# Stage 50 — AlgoHex, built from source.
#
# Translated from the upstream Dockerfile at
# domain_partition_3D/external/algohex-src/Dockerfile.
#
# WHY FROM SOURCE AND NOT FROM THE EXISTING IMAGE
# `algohex:portable` was assembled by hand from a Docker volume that exists on
# exactly one machine; external_patches/Dockerfile.portable says so in its own
# header and calls the from-source path "still unverified". An installer other
# people can run cannot depend on that volume. The patch file also records why
# the shortcut existed at all: a non-resumable single-layer ninja "takes hours"
# on a 2-vCPU box, and it recommends reverting that half "on a fast machine and
# build with -j$(nproc)". This stage is that revert.
#
# NETWORK: cmake fetches the dependencies at configure time, and two of them
# live on non-standard ports (gitlab.vci.rwth-aachen.de:9000,
# graphics.rwth-aachen.de:9000). A build host that blocks outbound 9000 fails
# here, not later.
#
# REPRODUCIBILITY: upstream pins gmm, Eigen, OpenVolumeMesh, TinyAD and CoMISo
# by hash or commit, but tracks BRANCHES for HexEx (algohex), HexHex (main),
# TrulySeamless3D (cgg), MC3D (cgg) and QGP3D (cgg) — and the Dockerfile builds
# Bonmin@master. Two builds a month apart are therefore not guaranteed to be
# the same software. This stage cannot fix upstream's pinning, so it does the
# next best thing: it records what each dependency actually resolved to, into
# /opt/stack-manifest.txt, so the image can answer the question later.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
: "${NCPU:=$(nproc)}"

ALGOHEX_REV="${ALGOHEX_REV:-3519289}"
IPOPT_VER="${IPOPT_VER:-3.14.19}"
MUMPS_VER="${MUMPS_VER:-3.0.11}"
BONMIN_VER="${BONMIN_VER:-master}"

apt-get update
apt-get install -y --no-install-recommends libopenmpi-dev

# ── coin-or: MUMPS, Ipopt, Bonmin ─────────────────────────────────────────
mkdir -p /usr/src/coin-or /opt/coin-or
cd /usr/src/coin-or
wget -q https://raw.githubusercontent.com/coin-or/coinbrew/master/coinbrew
chmod +x coinbrew

./coinbrew fetch "https://github.com/coin-or-tools/ThirdParty-Mumps@${MUMPS_VER}"
./coinbrew fetch "Ipopt@${IPOPT_VER}" --skip-update
./coinbrew fetch "Bonmin@${BONMIN_VER}" --skip-update

./coinbrew build "Ipopt@${IPOPT_VER}" --verbosity 2 --skip-update \
    --prefix=/opt/coin-or --parallel-jobs "$NCPU" --tests none
./coinbrew build "Bonmin@${BONMIN_VER}" --verbosity 2 --skip-update \
    --prefix=/opt/coin-or --parallel-jobs "$NCPU" --tests none

# AlgoHex's finders look for <coin/...> while coinbrew installs <coin-or/...>.
ln -sfn /opt/coin-or/include/coin-or /opt/coin-or/include/coin

# ── AlgoHex ───────────────────────────────────────────────────────────────
git clone https://github.com/cgg-bern/AlgoHex.git /opt/algohex-src
cd /opt/algohex-src
git checkout "$ALGOHEX_REV"
git submodule update --init --recursive
ALGOHEX_SHA="$(git rev-parse HEAD)"

export CoinUtils_DIR=/opt/coin-or
export IPOPT_HOME=/opt/coin-or
export CBC_DIR=/opt/coin-or
export CLP_DIR=/opt/coin-or

mkdir -p /opt/algohex-src/build
cd /opt/algohex-src/build
cmake -G Ninja \
    -D CMAKE_BUILD_TYPE=Release \
    -D BONMIN_ROOT_DIR=/opt/coin-or \
    ..

# The line the portable-image shortcut existed to avoid. With cores it is
# ordinary.
ninja -j "$NCPU"

# ── install and self-test ─────────────────────────────────────────────────
install -d /opt/algohex/Build
cp -a /opt/algohex-src/build/Build/bin /opt/algohex/Build/bin
cp -a /opt/algohex-src/build/Build/lib /opt/algohex/Build/lib 2>/dev/null || true
ln -sf /opt/algohex/Build/bin/* /usr/local/bin/

cat > /etc/ld.so.conf.d/algohex.conf <<'EOF'
/opt/algohex/Build/lib
/opt/coin-or/lib
EOF
ldconfig

# The self-test IS the point of the stage. An image whose binary cannot run is
# exactly the failure Dockerfile.portable was written to stop, and it must fail
# at build time rather than on a cluster node six hours into an allocation.
HexMeshing -h > /dev/null
missing="$(ldd "$(command -v HexMeshing)" | grep -c 'not found' || true)"
[[ "$missing" -eq 0 ]] || { ldd "$(command -v HexMeshing)" | grep 'not found'; exit 1; }
echo "self-test OK: HexMeshing runs, 0 missing libraries"

# ── record what actually got fetched ──────────────────────────────────────
{
    echo "algohex: $ALGOHEX_SHA ($ALGOHEX_REV)"
    echo "coin-or: Ipopt@$IPOPT_VER Bonmin@$BONMIN_VER Mumps@$MUMPS_VER"
    echo "algohex externals (upstream tracks branches for several of these):"
    for d in /opt/algohex-src/external/*/; do
        name="$(basename "$d")"
        if [[ -d "$d/.git" ]] || [[ -f "$d/.git" ]]; then
            sha="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo unknown)"
            echo "  $name: $sha"
        else
            echo "  $name: (archive, pinned by URL hash upstream)"
        fi
    done
} >> /opt/stack-manifest.txt

# Sources are ~GB and the binaries are self-contained now.
rm -rf /usr/src/coin-or

echo "stage 50 OK"
