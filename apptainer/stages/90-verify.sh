#!/usr/bin/env bash
# Stage 90 — build-time self-tests.
#
# These run inside %post, so a failure here means no .sif is written at all.
# The alternative — discovering that dtOOPythonSWIG cannot import six hours
# into a cluster allocation — is the failure mode this stage exists to make
# impossible.
#
# Each import is checked in the environment that will actually run it. Notably
# the dtOO check sources BOTH OpenFOAM's bashrc and dtOO's env.sh, in that
# order: with neither it fails on libPstream.so, with only OpenFOAM on
# libTKFeat.so.7.9, and with only env.sh on libTKFeat.so.7.9 as well. That
# ordering is recorded in eigenfrequencies' physics.py as DTOO_SETUP and is
# re-asserted here so a base-image change cannot break it quietly.
set -euo pipefail

fail=0
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  OK    $name"
    else
        echo "  FAIL  $name"
        # Re-run visibly so the build log carries the actual error.
        "$@" || true
        fail=1
    fi
}

echo "--- AlgoHex ---"
check "HexMeshing runs"        HexMeshing -h
check "HexMeshing libs resolve" bash -c '! ldd "$(command -v HexMeshing)" | grep -q "not found"'

echo "--- FEniCSx (system python3.12) ---"
check "import dolfinx"  python3 -c 'import dolfinx'
check "import gmsh"     python3 -c 'import gmsh'
check "import slepc4py" python3 -c 'import slepc4py'

echo "--- dtOO (venv-dtoo, OpenFOAM env) ---"
check "import dtOOPythonSWIG" bash -lc '
    source /usr/lib/openfoam/openfoam2606/etc/bashrc
    source /dtOO-install/bin/env.sh
    /opt/venv-dtoo/bin/python -c "import dtOOPythonSWIG"'

echo "--- OpenFOAM (no setup, as the solve runs it) ---"
# CFD_SOLVE_SETUP is deliberately empty in physics.py: the image configures
# OpenFOAM itself, and sourcing its bashrc on top strips the library entries.
# This asserts the bare invocation works, which is what that empty tuple claims.
check "checkMesh runs bare" bash -c 'checkMesh -help'

echo "--- venv-sci ---"
check "import torch"           /opt/venv-sci/bin/python -c 'import torch'
check "import pygmo"           /opt/venv-sci/bin/python -c 'import pygmo'
check "import hydroflow_opt"   /opt/venv-sci/bin/python -c 'import hydroflow_opt'
check "import eigenfrequencies" /opt/venv-sci/bin/python -c 'import eigenfrequencies'
check "import dp3d"            /opt/venv-sci/bin/python -c 'import dp3d'
# config+metrics are stdlib-only, hourglass_transformer needs torch: together
# they prove the .pth resolves AND that the torch half of the env is sound.
# NOT tokenizer_v2/half_edge — those import openmesh, which meshtron's own
# pyproject keeps as an optional extra because it needs a C++ build and is off
# the training path. Testing them would fail the build for the wrong reason.
check "import meshtron mods"   /opt/venv-sci/bin/python -c 'import config, metrics, hourglass_transformer'
check "import dolfinx in venv" /opt/venv-sci/bin/python -c 'import dolfinx'

echo "--- variant invariant ---"
# stack.sif must carry no agent tooling. If node ever appears here, the claim
# that the published image contains no agent infrastructure has quietly become
# false, and the derived-image split has lost its purpose.
check "no node in the base image" bash -c '! command -v node'
check "no npm in the base image"  bash -c '! command -v npm'

if [[ "$fail" -ne 0 ]]; then
    echo ""
    echo "stage 90 FAILED — no image will be written."
    exit 1
fi

echo "stage 90 OK — all self-tests passed"
