# Handoff: the first build

For a session starting cold on the build laptop. Everything below is either
verified or explicitly marked as untested.

## Where this stands

The repository is complete and pushed. **No image has ever been built.** The
`.def` files and the seven build stages have never executed — the machine they
were written on had no Apptainer, two cores and 3.8 GB free.

So the first build is the experiment. Expect it to fail somewhere in stages
20–60 and plan to iterate rather than to succeed on the first pass.

## Record what you are building from, before you start

A build is hermetic: `apptainer build` copies `apptainer/stages/` and the staged
repository snapshot **into the image** via `%files` before `%post` runs. Nothing
pushed to this repository afterwards can reach a build already in flight.

The hazard is not correctness, it is diagnosis. If stage 60 fails and the
repository has moved on since, the file you read is not the file that ran. So:

```bash
git -C . rev-parse HEAD > "$STACK_IMAGES/logs/built-from.txt"
```

and do **not** pull until the build has finished and been diagnosed.

**If someone else is maintaining this repository, tell them to hold pushes
while your build runs.** Changing the recipe under a running build costs
nothing technically and a great deal in confusion.

## What is verified, and what is not

Written down because the distinction is load-bearing and easy to lose.

**Verified by execution:**

| Claim | How |
|---|---|
| Every shell script parses | `bash -n` on all 14 |
| `--clone` works, is idempotent, reports branch and dirty count | end-to-end against three local bare repositories |
| `install.sh --help` / `--check` work without Apptainer installed | run |
| Both profiles parse and satisfy `concurrent × ranks × threads ≤ available_cpus` | 8 ≤ 12 and 64 ≤ 64 |
| `import dp3d` resolves with the repository directory on the path | run |
| `.pth` entries land *after* site-packages, so they shadow nothing installed | measured in a throwaway venv |
| `meshtron`'s `config`/`metrics` are stdlib-only; `tokenizer_v2`/`half_edge` need `openmesh` | import-checked |
| `physics.py` apptainer runtime | 89 tests |
| `optimizer` runtime detection | 4 tests |
| `run_algohex --backend native` emits the right argv and skips path translation | function exercised directly |
| `hydroflow-opt` has exactly one release, 0.1.0 | PyPI queried |
| No build stage prompts for input | grepped: all `apt-get -y`, `DEBIAN_FRONTEND` set, all clones over https |
| `eigenfrequencies` merge to `main` was a fast-forward | 0 ahead / 61 behind, 89 tests after |

**Changed with reasoning but never executed:**

| Change | What is unproven |
|---|---|
| All seven build stages | none has ever run. This is the bulk of the risk. |
| `stack.def`, `stack-agent.def` | never built; `%files` paths, `%environment`, `%labels` all unexercised |
| `stack-doctor`, `stack-shell`, `stack-agent`, `stack-run` | never run against a real image |
| `slurm/submit.sh` | never submitted |
| dropping `optimizer` | the *reason* is verified (no imports anywhere); the resulting build is not |
| the flat three-repo layout | the paths `/opt/stack/{domain_partition_3D,meshtron}` have never existed |
| `hydroflow-opt` pinned to `0.1.0` | the pin is unexercised in a build. Moot in practice: 0.1.0 is the only release, so a pinned and an unpinned install resolve identically. |
| build logging and `PIPESTATUS` | syntax-checked only; the failure path has not been triggered |
| recording resolved SHAs in stage 20 | unexecuted |
| the two dtOO stages as a whole | transcribed from upstream's Dockerfiles, not run |

Two bugs were found *by* testing rather than by reading, which is the argument
for distrusting the second table: the manifest lines that report installed
versions had nested quoting Python rejected, so they would silently have written
`unknown` for everything; and `git rev-parse --abbrev-ref HEAD` prints `HEAD`
*and* fails on a detached head, so a `|| echo ?` fallback appended instead of
replacing and broke a line in two. Both were invisible on reading.

## Goal

One Apptainer image (`stack.sif`) carrying dtOO + OpenFOAM, FEniCSx, AlgoHex
and torch alongside three research repositories, so that three modules —
CFD/eigenfrequency optimization, hexahedral block generation, transformer
training and inference — run individually or chained, on a workstation and on
HPC. A derived `stack-agent.sif` adds node so coding agents can develop inside
it without reaching the rest of the machine.

## Do this first

```bash
mkdir ~/stack && cd ~/stack
git clone git@github.com:RentschlerTobias/hydrostack.git
cd hydrostack
./install.sh --clone
```

### Then the trap that costs an hour

`--clone` checks out default branches. The Apptainer runtime support in
`eigenfrequencies` lives on a **non-default branch**:

```bash
git -C ../eigenfrequencies checkout fix/bwuni-enroot-hardening
```

Commit `ff9709c` (`feat(physics): apptainer runtime kind`) is on
`origin/fix/bwuni-enroot-hardening` only; the default branch is `main`. The
build succeeds without it — the shipped profiles use `runtime = "native"`, not
`apptainer` — but the runtime kind, the `STACK_*` interpreter constants and
their tests will be missing from the image. Merging that branch into `main` is
the cleaner fix and removes this footgun permanently.

### Then

```bash
./install.sh --check         # repos, apptainer, fakeroot, tmpdir, ~40 GB free
./install.sh --build         # hours
```

Apptainer: `pacman -S apptainer` on Arch. `--fakeroot` silently does not work
without an `/etc/subuid` entry — `--check` probes for this, and the fix is
`sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`.

## Do not rebuild from scratch to fix one stage

A full build is hours; there are no Docker layers to resume from. Build a
writable sandbox once, then re-run single stages into it:

```bash
apptainer build --fakeroot --sandbox /var/tmp/apptainer/sandbox apptainer/stack.def
./install.sh --stage 50-algohex
```

## How the dtOO build works

Two stages, because upstream is two repositories.

### Stage 20 — `dtOO-ThirdParty` and OpenFOAM

Transcribed from `dtOO/dtOO-ThirdParty/Dockerfile.ubuntu`. That file is the
reason this image can be Ubuntu at all: the stock dtOO image is openSUSE Leap
16, `dolfinx/dolfinx:stable` is Ubuntu 24.04, and they cannot both be the base.
Upstream's Ubuntu recipe is what makes a common base exist.

In order:

1. **deadsnakes PPA → python3.13.** Upstream pins 3.13. Ubuntu 24.04's system
   python is 3.12, and that is where dolfinx lands in stage 40. Two
   interpreters on purpose; confusing them is how the stages break.
2. **Dev libraries**: Qt5, five boost components, muparser, gsl, freetype,
   tk/tcl, rapidjson, nlohmann-json.
3. **Clone `dtOO-ThirdParty`** — needed for `buildDep` and for OpenFOAM's GPG
   key, which ships in that repository.
4. **OpenFOAM 2606** from `dl.openfoam.com`'s noble repo, six packages
   including `-dev` and `-source`, because dtOO compiles against its headers.
5. **`/opt/venv-dtoo`** with upstream's exact pins: `numpy==2.3.5`,
   `swig==4.3.0` (SWIG generates the Python bindings; the version matters),
   plus foamlib, oslo.concurrency, scikit-learn, meshio.
6. **`buildDep` loop** over cgns, moab, openmesh, openvolumemesh, gmsh, occt,
   pythonocc-core, each installed into `/dtOO-install`, with the venv active
   because the last three need Python during their own build.
7. **foamFine**: clone and `wmake all` inside a login shell that has sourced
   OpenFOAM's bashrc.

### Stage 30 — dtOO itself

Follows `dtOO/Dockerfile`:

```bash
cmake -DCMAKE_INSTALL_PREFIX=/dtOO-install \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DPython3_EXECUTABLE=/opt/venv-dtoo/bin/python ..
make -j$(nproc) install
```

`CMAKE_INSTALL_PREFIX` is the **same prefix** the third-party libraries went
into, which is how dtOO finds them and how everything ends up under one root.
`RelWithDebInfo` is upstream's choice, kept so the binaries match what the
cluster runs today.

Finally, `/dtOO-install/tools` and `/dtOO-install/scripts/python` go onto the
path via a `.pth` in `venv-dtoo`'s site-packages. Upstream exports `PYTHONPATH`
globally; a `.pth` is used here instead because the modal stage runs a
*different* interpreter and must not inherit dtOO's paths.

### How dtOO is invoked afterwards

Both environments, in this order, and the `cd` after them, never before:

```bash
source /usr/lib/openfoam/openfoam2606/etc/bashrc
source /dtOO-install/bin/env.sh
cd <workdir>
exec <command>
```

This is not stylistic. Measured, and recorded in
`eigenfrequencies/src/eigenfrequencies/hydroflow/physics.py`:

- with neither → fails on `libPstream.so`
- with only OpenFOAM → fails on `libTKFeat.so.7.9`
- with only `env.sh` → also fails on `libTKFeat.so.7.9`
- `cd` **before** sourcing → OpenFOAM's bashrc re-executes itself in a loop,
  forever, producing no artifact, no log line and no error until the timeout

And the CFD solve gets **no setup at all** (`CFD_SOLVE_SETUP = ()`): the image
configures OpenFOAM itself, and sourcing its bashrc on top strips its own
library entries and puts nothing back, after which `checkMesh` dies on
`libfiniteVolume.so` with a bare exit 127 and an empty log.

## Where it will probably break

| Stage | Likely failure | What to do |
|---|---|---|
| 20 | `python3.13` not in deadsnakes for noble | check the PPA; fall back to Ubuntu's 3.12 for venv-dtoo and accept the deviation from upstream's pin |
| 20 | `buildDep occt` / `pythonocc-core` — longest and most fragile | run it alone via `--stage`; read the `-tee` log |
| 40 | `ppa:fenics-packages/fenics` has no usable noble packages | fall back to lifting dolfinx out of `dolfinx/dolfinx:stable`; recipe in `build-notes.md` |
| 50 | outbound port 9000 blocked | CoMISo and OpenVolumeMesh are fetched from `gitlab.vci.rwth-aachen.de:9000` and `graphics.rwth-aachen.de:9000` at cmake configure time |
| 50 | coinbrew (MUMPS/Ipopt/Bonmin) | the known-fragile chain; it gets easier with cores, which the laptop has |
| 60 | no `pygmo` wheel | habitually a conda package; recent releases ship manylinux wheels |
| 60 | torch resolver conflict | `meshtron` pins 2.11.0, `domain_partition_3D` pins 2.13.0; stage 60 takes meshtron's and filters dp3d's torch line out |

Full detail in `docs/build-notes.md`.

## When it goes green

```bash
./install.sh --build-agent
./bin/stack-doctor                  # expects PASS
./bin/stack-doctor --unconfined     # expects containment to FAIL
```

The second is not decoration. A containment check that passes however the
container was started tests nothing; `--unconfined` exits 0 only when
containment is correctly reported as broken.

Then the claim this image actually makes, which nothing has tested:

```bash
./bin/stack-shell bash -c '
    source /usr/lib/openfoam/openfoam2606/etc/bashrc
    source /dtOO-install/bin/env.sh
    /opt/venv-dtoo/bin/python -c "import dtOOPythonSWIG; print(\"dtOO ok\")"'
./bin/stack-shell checkMesh -help
./bin/stack-shell /opt/venv-sci/bin/python -c 'import dolfinx; print("dolfinx ok")'
```

All three in one process tree. `eigenfrequencies/docs/install.md` states that
the dtOO+OpenFOAM and FEniCSx stacks "do not coexist in one environment" — said
of a conda environment, and this image is the experiment that tests it. The two
MPI stacks (OpenFOAM ships its own openmpi, dolfinx pulls another) must never
share an `LD_LIBRARY_PATH`; nothing puts either on the global environment, the
per-stage setup constants do it per stage.

Then the modules, against the **lean** image:

```bash
./bin/stack-run cfd-opt profiles/local.toml --dry-run
./bin/stack-run hexblock <mesh.msh> --smoke
./bin/stack-run meshtron train --help
```

## Facts worth not re-deriving

- **Why one image and not four.** Apptainer fixes its mounts at container
  *start*. Anyone who can run `apptainer` picks their own mounts, so
  `apptainer exec --bind /:/host` is a complete escape. A confined agent
  therefore must not have the binary — which means every stage it orchestrates
  has to be reachable as a plain subprocess, in the same image.
- **Apptainer does not isolate by default.** It mounts `$HOME`, `$PWD`,
  `/tmp`, `/var/tmp` and passes the host environment through. `--containall`
  is the flag that turns that off, and it is in `bin/_common.sh` so it cannot
  be forgotten per-invocation.
- **Network is not confined** and cannot be, because the agents need their
  APIs. Filesystem containment is what this delivers.
- **`.pth` paths land after site-packages** (measured), so
  `domain_partition_3D` and `meshtron` cannot shadow installed packages despite
  exposing names like `config`, `dataset` and `metrics`.
- **`optimizer` is deliberately absent.** Nothing imports it, it duplicates
  `eigenfrequencies/optimize/` while losing every comparison, and it declares
  `d3rlpy` as a core dependency, which would fight the pinned torch.
- **The image records what built it** in `/opt/stack-manifest.txt`. AlgoHex
  tracks upstream *branches* for HexEx, HexHex, TrulySeamless3D, MC3D and
  QGP3D, and builds `Bonmin@master`, so two builds a month apart are not the
  same software. Read that file before citing a result.

## Still open

- Nothing has been built. Every stage is unverified.
- `fix/bwuni-enroot-hardening` should be merged into `eigenfrequencies`' `main`.
- bwUniCluster's GPU type is unknown (roadmap T6); the image targets CUDA
  because the build laptop has an RTX 4060.
- Live meshtron inference during an optimization is *enabled* by the single
  image but not implemented — that is roadmap T10–T12, not this installer.
