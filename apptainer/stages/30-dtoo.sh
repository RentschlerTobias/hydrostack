#!/usr/bin/env bash
# Stage 30 — dtOO itself.
#
# Follows dtOO/Dockerfile: cmake against $DTOO_EXTERNLIBS from stage 20, then
# `make install`. Upstream builds with -DCMAKE_BUILD_TYPE=RelWithDebInfo; kept
# as-is so the binaries match what the cluster runs today.
set -euo pipefail

: "${NCPU:=$(nproc)}"
export DTOO_EXTERNLIBS=/dtOO-install
DTOO_REV="${DTOO_REV:-main}"

git clone https://github.com/ihs-ustutt/dtOO.git /dtOO
cd /dtOO
git checkout "$DTOO_REV"
git submodule update --init --recursive

DTOO_SHA="$(git rev-parse HEAD)"

mkdir -p /dtOO/build
cd /dtOO/build

# shellcheck disable=SC1091
. /opt/venv-dtoo/bin/activate

cmake \
    -DCMAKE_INSTALL_PREFIX="$DTOO_EXTERNLIBS" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DPython3_EXECUTABLE="$(command -v python3)" \
    ..
make -j "$NCPU" install

deactivate

# Upstream's Dockerfile puts these on PYTHONPATH. They are not importable
# otherwise, and the geometry export is the first thing that notices. A .pth in
# site-packages beats exporting PYTHONPATH globally: the modal stage runs a
# different interpreter and must not inherit dtOO's paths.
SITE_DIR="$(/opt/venv-dtoo/bin/python -c 'import site; print(site.getsitepackages()[0])')"
cat > "$SITE_DIR/dtoo-paths.pth" <<'EOF'
/dtOO-install/tools
/dtOO-install/scripts/python
EOF

echo "dtOO: $DTOO_SHA ($DTOO_REV)" >> /opt/stack-manifest.txt
echo "stage 30 OK"
