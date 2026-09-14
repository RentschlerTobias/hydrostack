# Build notes

Failure modes that are cheap to fix once you know the name, and expensive to
diagnose from a stack trace.

## Preflight

`./install.sh --check` covers these, but the reasoning is worth keeping.

**`--fakeroot` fails silently without `/etc/subuid`.** Apptainer needs a subuid
range for the building user. Without it the build dies well into stage 20.

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
```

**`APPTAINER_TMPDIR` must not be tmpfs.** The dtOO rootfs unpacks to several GB.
On a machine where `/tmp` is RAM-backed that takes the machine down, not the
build. `stack.conf` defaults to `/var/tmp/apptainer` for this reason.

**Disk.** The peak is the unpacked rootfs plus the squashfs being written, not
the finished `.sif`. Budget ~40 GB.

## Stage 40 — dolfinx

The preferred path is `ppa:fenics-packages/fenics`. If noble packages turn out
unusable, the fallback is to lift dolfinx out of `dolfinx/dolfinx:stable`,
which is also Ubuntu 24.04:

```bash
apptainer exec docker://dolfinx/dolfinx:stable \
    tar -C / -cf - usr/lib/python3/dist-packages/dolfinx > dolfinx.tar
```

Stage 40 fails loudly rather than attempting this blind — a half-working
dolfinx is worse than none, because it fails at solve time instead of build
time. If you take the fallback, record it in `/opt/stack-manifest.txt`.

## Stage 50 — AlgoHex

**Outbound port 9000.** Two dependencies are fetched from
`gitlab.vci.rwth-aachen.de:9000` (CoMISo) and `graphics.rwth-aachen.de:9000`
(OpenVolumeMesh, HexEx) at cmake configure time. A host that blocks that port
fails here.

**The coinbrew chain is the fragile part.** MUMPS, Ipopt and Bonmin build from
source. It gets easier with cores, not harder — the reason the old
`algohex:portable` shortcut existed at all was a 2-vCPU machine where a
non-resumable `ninja` ran for hours.

**Reproducibility.** Upstream tracks branches for HexEx, HexHex,
TrulySeamless3D, MC3D and QGP3D, and builds `Bonmin@master`. Stage 50 records
the resolved commits into `/opt/stack-manifest.txt`. To pin a build, read those
commits out of a known-good image and pass them back as
`-D FETCHCONTENT_SOURCE_DIR_<name>` or by pre-populating
`/opt/algohex-src/external/`.

## Stage 60 — venv-sci

**pygmo.** The one dependency here that is habitually a conda package. Recent
releases ship manylinux wheels; if the wheel is missing for your platform the
stage stops with the package name rather than a resolver trace forty lines
deep.

**The torch pin conflict.** `quadmesh/meshtron/pyproject.toml` pins
`torch==2.11.0`; `quadmesh/domain_partition_3D/requirements.txt` pins
`torch==2.13.0`. One environment means one torch. Stage 60 takes the meshtron
pin — it is the one with a `uv.lock` and an explicit cu128 index behind it —
and filters the torch line out of the dp3d requirements rather than letting pip
silently re-resolve it. **This divergence belongs upstream**: the two files
should agree, and until they do this stage is making a decision that is not
really its to make.

## Iterating on a stage

A full build is hours. For development, build a sandbox once and re-run
individual stages into it:

```bash
apptainer build --fakeroot --sandbox /var/tmp/apptainer/sandbox apptainer/stack.def
./install.sh --stage 50-algohex
```

## Verifying afterwards

```bash
./bin/stack-doctor                 # expects PASS
./bin/stack-doctor --unconfined    # expects containment to FAIL — the negative control
apptainer exec "$STACK_IMAGES/stack.sif" cat /opt/stack-manifest.txt
```

The MPI coexistence check is the one that cannot be skipped, because it is the
claim this image makes that nothing else has tested. In one container session:

```bash
./bin/stack-shell bash -c '
    source /usr/lib/openfoam/openfoam2606/etc/bashrc
    source /dtOO-install/bin/env.sh
    /opt/venv-dtoo/bin/python -c "import dtOOPythonSWIG; print(\"dtOO ok\")"
'
./bin/stack-shell checkMesh -help
./bin/stack-shell /opt/venv-sci/bin/python -c 'import dolfinx; print("dolfinx ok")'
```

All three in one process tree is the actual test;
`eigenfrequencies/docs/install.md` says these stacks do not coexist, and that
claim was made about a conda environment rather than this image.
