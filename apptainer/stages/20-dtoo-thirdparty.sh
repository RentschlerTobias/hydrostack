#!/usr/bin/env bash
# Stage 20 — dtOO third-party stack and OpenFOAM.
#
# Transcribed from dtOO/dtOO-ThirdParty/Dockerfile.ubuntu. That file is the
# reason this image can be Ubuntu at all: the stock dtOO image is openSUSE, and
# without an Ubuntu recipe for the dtOO half there would be no common base with
# dolfinx.
#
# Kept close to upstream on purpose. When dtOO-ThirdParty moves, diff against
# that Dockerfile rather than guessing.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
: "${NCPU:=$(nproc)}"

THIRDPARTY_REV="${THIRDPARTY_REV:-main}"
export DTOO_EXTERNLIBS=/dtOO-install

# ── python3.13 for the dtOO bindings ──────────────────────────────────────
# Upstream pins 3.13 via deadsnakes; Ubuntu 24.04 ships 3.12 as system python.
# Both are needed and they must not be confused: 3.13 is the dtOO environment,
# 3.12 is where dolfinx lands in stage 40.
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update
apt-get install -y --no-install-recommends \
    python3.13 python3.13-dev python3.13-venv \
    qtbase5-dev nlohmann-json3-dev \
    libboost-filesystem-dev libboost-program-options-dev libboost-regex-dev \
    libboost-thread-dev libboost-timer-dev \
    libmuparser-dev libgsl-dev \
    libfreetype-dev tk-dev tcl-dev \
    rapidjson-dev ccache ssh

# ── OpenFOAM 2606 from the official repo ──────────────────────────────────
git clone --depth 1 --branch "$THIRDPARTY_REV" \
    https://github.com/ihs-ustutt/dtOO-ThirdParty.git /dtOO-ThirdParty
# "main" is a moving target. Resolve it now, so the image can answer which
# dependency recipes it was actually built from — the same reason stage 50
# records what AlgoHex's FetchContent resolved to.
THIRDPARTY_SHA="$(git -C /dtOO-ThirdParty rev-parse HEAD)"

echo "deb [arch=amd64] https://dl.openfoam.com/repos/deb noble main" \
    > /etc/apt/sources.list.d/openfoam.list
gpg --dearmor < /dtOO-ThirdParty/openfoam_pubkey.gpg \
    > /etc/apt/trusted.gpg.d/openfoam.gpg
apt-get update
apt-get install -y --no-install-recommends \
    openfoam2606 openfoam2606-common openfoam2606-default \
    openfoam2606-dev openfoam2606-source openfoam2606-tools

export CC=/usr/bin/gcc CXX=/usr/bin/g++ FC=/usr/bin/gfortran

# ── the dtOO python environment ───────────────────────────────────────────
python3.13 -m venv /opt/venv-dtoo
/opt/venv-dtoo/bin/pip install --no-cache-dir --upgrade pip
/opt/venv-dtoo/bin/pip install --no-cache-dir \
    numpy==2.3.5 foamlib oslo.concurrency scikit-learn swig==4.3.0 meshio

mkdir -p "$DTOO_EXTERNLIBS"

# ── third-party libraries ─────────────────────────────────────────────────
# Upstream runs each of these as its own Docker layer so a failure is cheap to
# resume. There are no layers here, which is why install.sh --stage exists.
cd /dtOO-ThirdParty
# shellcheck disable=SC1091
. /opt/venv-dtoo/bin/activate
for dep in cgns moab openmesh openvolumemesh gmsh occt pythonocc-core; do
    echo "--- buildDep $dep ---"
    bash buildDep -i "$DTOO_EXTERNLIBS" -n "$NCPU" -o "$dep" -tee
done
deactivate

# ── foamFine ──────────────────────────────────────────────────────────────
git clone --depth 1 https://github.com/ihs-ustutt/foamFine.git /foamFine
FOAMFINE_SHA="$(git -C /foamFine rev-parse HEAD)"
cd /foamFine/of
# shellcheck disable=SC1091
bash -lc 'source /usr/lib/openfoam/openfoam2606/etc/bashrc && wmake all'
mkdir -p /root/OpenFOAM
ln -sfn /root/OpenFOAM/user-2606 /root/OpenFOAM/root-2606 || true

{
    echo "openfoam: 2606 (dl.openfoam.com noble)"
    echo "dtOO-ThirdParty: $THIRDPARTY_SHA ($THIRDPARTY_REV)"
    echo "foamFine: $FOAMFINE_SHA"
    echo "dtOO third-party libs: cgns moab openmesh openvolumemesh gmsh occt pythonocc-core"
} >> /opt/stack-manifest.txt

echo "stage 20 OK"
