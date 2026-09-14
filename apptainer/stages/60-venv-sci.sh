#!/usr/bin/env bash
# Stage 60 — the science / orchestration environment.
#
# python3.12 with --system-site-packages so the apt dolfinx from stage 40 stays
# visible without being vendored. Everything that is not dtOO lives here:
# torch, hydroflow-opt, and the three repos as editable installs.
#
# WHY EDITABLE, IN AN IMAGE THAT IS READ-ONLY
# The install is recorded against /opt/stack/<repo>, a fixed path. On the agent
# host the host checkout is bind-mounted onto exactly that path, so the same
# editable install keeps resolving and the code is editable. On the cluster and
# for third parties nothing is mounted and the baked copy runs. One recipe,
# both modes.
set -euo pipefail

: "${NCPU:=$(nproc)}"

python3 -m venv --system-site-packages /opt/venv-sci
PIP="/opt/venv-sci/bin/pip"
PY="/opt/venv-sci/bin/python"

$PIP install --no-cache-dir --upgrade pip setuptools wheel

# ── torch ─────────────────────────────────────────────────────────────────
# ONE torch for the whole environment, which forces a decision the repos have
# not made between themselves: quadmesh/meshtron/pyproject.toml pins
# torch==2.11.0 and quadmesh/domain_partition_3D/requirements.txt pins
# torch==2.13.0. meshtron wins because it is the pin with a uv.lock and an
# explicit cu128 index behind it; dp3d's torch line is filtered out below
# rather than being allowed to silently re-resolve this.
#
# cu128 runs on the build laptop's RTX 4060 (Ada, sm_89) and on the cluster
# GPUs; with no GPU present the same wheel falls back to CPU, which is what the
# institute workstation needs.
TORCH_VERSION="${TORCH_VERSION:-2.11.0}"
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu128}"
$PIP install --no-cache-dir --index-url "$TORCH_INDEX" \
    "torch==${TORCH_VERSION}" torchvision torchaudio

# ── hydroflow-opt and its optimizer core ──────────────────────────────────
# pygmo is the one dependency here that is habitually a conda package. Recent
# releases ship manylinux wheels; if this fails the build stops with a name to
# search for rather than a stack trace 40 lines deep.
$PIP install --no-cache-dir "pygmo>=2.19.8" \
    || { echo "ERROR: no pygmo wheel for this platform; see docs/build-notes.md" >&2; exit 1; }
$PIP install --no-cache-dir hydroflow-opt

# ── the three repos, editable at fixed paths ──────────────────────────────
$PIP install --no-cache-dir -e "/opt/stack/eigenfrequencies[optimize,mcp,dev]"
$PIP install --no-cache-dir -e "/opt/stack/optimizer[mcp,dev]"
$PIP install --no-cache-dir -e "/opt/stack/quadmesh"

# dp3d's remaining dependencies, minus torch (see above). Its requirements.txt
# is a flat pin list, not a package.
grep -vE '^\s*(torch|#|$)' /opt/stack/quadmesh/domain_partition_3D/requirements.txt \
    > /tmp/dp3d-reqs.txt || true
$PIP install --no-cache-dir -r /tmp/dp3d-reqs.txt

# meshtron declares itself "reiner App-Ordner (kein installierbares Paket)", so
# its dependencies are installed but the directory goes on the path instead of
# being packaged.
$PIP install --no-cache-dir \
    tqdm torch-geometric networkx pandas seaborn optuna gmsh textual matplotlib

SITE_DIR="$($PY -c 'import site; print(site.getsitepackages()[0])')"
echo "/opt/stack/quadmesh/meshtron" > "$SITE_DIR/meshtron.pth"

{
    echo "venv-sci: $($PY --version 2>&1)"
    echo "torch: $TORCH_VERSION from $TORCH_INDEX"
    echo "repos: editable at /opt/stack/{quadmesh,eigenfrequencies,optimizer}"
} >> /opt/stack-manifest.txt

echo "stage 60 OK"
