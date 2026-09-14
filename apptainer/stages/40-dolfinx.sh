#!/usr/bin/env bash
# Stage 40 — FEniCSx (dolfinx) for the modal solve.
#
# Into the SYSTEM python3.12, not into a venv: the apt packages install to
# /usr/lib/python3/dist-packages, and stage 60 creates venv-sci with
# --system-site-packages so it sees them from there. Putting dolfinx in a venv
# instead would mean rebuilding PETSc/SLEPc, which is the thing nobody wants to
# own.
#
# THE MPI POINT. OpenFOAM (stage 20) ships its own openmpi and dolfinx pulls
# another. They coexist in this filesystem but must never share one
# LD_LIBRARY_PATH. Nothing here puts either on the global environment; the
# per-stage setup constants in eigenfrequencies' physics.py do that, per stage.
# eigenfrequencies/docs/install.md says these two stacks "do not coexist in one
# environment" — that was said of a conda env, and this image is the experiment
# that tests it. Stage 90 and the MPI check in the README are where it gets
# proven or disproven.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

DOLFINX_SOURCE=unset

# Preferred: the FEniCS PPA. One apt line, versioned, no vendoring.
if add-apt-repository -y ppa:fenics-packages/fenics && apt-get update; then
    if apt-get install -y --no-install-recommends \
            python3-dolfinx python3-mpi4py python3-petsc4py-real python3-slepc4py-real; then
        DOLFINX_SOURCE="ppa:fenics-packages/fenics"
    fi
fi

# Fallback, recorded rather than silent: if noble packages are unusable the
# other option is lifting dolfinx out of dolfinx/dolfinx:stable, which is also
# Ubuntu 24.04. That needs the image at build time and is a bigger hammer, so
# it fails loudly here instead of being attempted blind.
if [[ "$DOLFINX_SOURCE" == "unset" ]]; then
    echo "ERROR: could not install dolfinx from ppa:fenics-packages/fenics." >&2
    echo "       Fallback is to copy /usr/lib/python3/dist-packages/dolfinx and" >&2
    echo "       its PETSc/SLEPc libraries out of dolfinx/dolfinx:stable" >&2
    echo "       (also Ubuntu 24.04). See docs/build-notes.md." >&2
    exit 1
fi

# gmsh as a python module: without it eigenfrequencies.io.load cannot read a
# .msh at all, which is the exact gap docs/cluster.md papers over with ~/pylibs
# on the cluster. Here it is simply in the image.
python3 -m pip install --break-system-packages --no-cache-dir gmsh

python3 -c 'import dolfinx; print("dolfinx", dolfinx.__version__)'

echo "dolfinx: $DOLFINX_SOURCE" >> /opt/stack-manifest.txt
echo "stage 40 OK"
