#!/usr/bin/env bash
# Stage 60 — the science / orchestration environment.
#
# python3.12 with --system-site-packages so the apt dolfinx from stage 40 stays
# visible without being vendored. Everything that is not dtOO lives here:
# torch, hydroflow-opt, and the research repos.
#
# WHY A FIXED PATH, IN AN IMAGE THAT IS READ-ONLY
# Everything is installed or pathed against /opt/stack/<repo>. On the agent
# host the host checkout is bind-mounted onto exactly that path, so the same
# editable install and the .pth entries keep resolving. On the cluster and
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
# not made between themselves: meshtron/pyproject.toml pins
# torch==2.11.0 and domain_partition_3D/requirements.txt pins
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

# ── hydroflow-opt, the optimization driver ────────────────────────────────
# pygmo is the one dependency here that is habitually a conda package. Recent
# releases ship manylinux wheels; if this fails the build stops with a name to
# search for rather than a stack trace 40 lines deep.
$PIP install --no-cache-dir "pygmo>=2.19.8" \
    || { echo "ERROR: no pygmo wheel for this platform; see docs/build-notes.md" >&2; exit 1; }

# hydroflow-opt is third-party (thomasisensee/hydroflow-opt) and PINNED, which
# an unversioned `pip install` was not. It sits at 0.1.0: a young package from
# another group, where semver offers no protection because anything below 1.0
# may break at a minor bump. And what it defines is the artifact contract the
# eigenfrequencies case plugin is written against — request.json, result.json,
# outcome.json. A silently newer version would be discovered hours into a
# cluster run, not at build time.
#
# Bump deliberately, or point HYDROFLOW_SRC at a checkout to test against an
# unreleased version without touching this file.
HYDROFLOW_VERSION="${HYDROFLOW_VERSION:-0.1.0}"
if [[ -n "${HYDROFLOW_SRC:-}" ]]; then
    echo "hydroflow-opt: installing from $HYDROFLOW_SRC (overrides the pin)"
    $PIP install --no-cache-dir -e "$HYDROFLOW_SRC"
else
    $PIP install --no-cache-dir "hydroflow-opt==${HYDROFLOW_VERSION}"
fi

# ── the research repos ────────────────────────────────────────────────────
# Three independent checkouts, not one wrapper repository with submodules.
# Only eigenfrequencies is a pip-installable package; the other two are
# directories of modules, so they go on the path instead of being packaged.

# eigenfrequencies: src layout, proper pyproject, editable.
$PIP install --no-cache-dir -e "/opt/stack/eigenfrequencies[optimize,mcp,dev]"

# The dependencies the retired wrapper repository used to declare. They belonged
# to the code in dp3d and meshtron all along, not to the wrapper, so they are
# stated here rather than inherited from a package that no longer exists.
$PIP install --no-cache-dir numpy gmsh trimesh networkx "tetgen>=0.8.4"

# domain_partition_3D: `dp3d` is a package inside it, so the REPOSITORY
# directory goes on the path and `import dp3d` resolves. requirements.txt is a
# flat pin list, not a package; torch is filtered out because it is pinned
# above and letting pip re-resolve it here is how two torches end up fighting.
grep -vE '^\s*(torch|#|$)' /opt/stack/domain_partition_3D/requirements.txt \
    > /tmp/dp3d-reqs.txt || true
$PIP install --no-cache-dir -r /tmp/dp3d-reqs.txt

# meshtron: a flat module folder with no __init__.py, and its own pyproject
# says so ("reiner App-Ordner, kein installierbares Paket"). Its modules are
# imported by bare name, so the directory itself goes on the path.
$PIP install --no-cache-dir \
    tqdm torch-geometric pandas seaborn optuna textual matplotlib

SITE_DIR="$($PY -c 'import site; print(site.getsitepackages()[0])')"
cat > "$SITE_DIR/stack-repos.pth" <<'EOF'
/opt/stack/domain_partition_3D
/opt/stack/meshtron
EOF

# Resolved versions, read back from what pip actually installed rather than
# from the variables above — the pin can be overridden, and the manifest has to
# say what is in the image, not what was asked for. Computed outside the
# heredoc-ish block: nesting quotes inside $( ) inside " " is how the first
# attempt silently wrote "unknown" for everything.
pkg_version() {
    $PIP show "$1" 2>/dev/null | awk '/^Version:/ {print $2}'
}
HF_VER="$(pkg_version hydroflow-opt)"
PYGMO_VER="$(pkg_version pygmo)"
TORCH_VER_ACTUAL="$(pkg_version torch)"

{
    echo "venv-sci: $($PY --version 2>&1)"
    echo "torch: ${TORCH_VER_ACTUAL:-unknown} (asked for $TORCH_VERSION from $TORCH_INDEX)"
    echo "hydroflow-opt: ${HF_VER:-unknown}${HYDROFLOW_SRC:+ (from $HYDROFLOW_SRC)}"
    echo "pygmo: ${PYGMO_VER:-unknown}"
    echo "eigenfrequencies: editable at /opt/stack/eigenfrequencies"
    echo "on sys.path: /opt/stack/{domain_partition_3D,meshtron}"
} >> /opt/stack-manifest.txt

echo "stage 60 OK"
