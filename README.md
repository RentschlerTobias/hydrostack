# hydrostack

One Apptainer image for the turbomachinery optimization pipeline: dtOO +
OpenFOAM for parametric geometry and CFD, FEniCSx for modal analysis, AlgoHex
for hexahedral block generation, and a Transformer (meshtron) that is being
trained to replace the sequential gmsh meshing step.

Two research repositories and three third-party stacks go in; one `.sif` file
comes out.

```
                 dtOO (geometry + CFD)        AlgoHex (hex blocks)
                          |                          |
   hydroflow-opt ---------+-----------+--------------+
   (optimization driver)              |
                                  FEniCSx (modal)
                                      |
                              meshtron (learned meshing)
```

| Module | What it does | Verb |
|---|---|---|
| frequency / CFD optimization | `eigenfrequencies` + `hydroflow-opt` + dtOO | `stack-run cfd-opt` |
| hexa block generation | `quadmesh/domain_partition_3D` + AlgoHex | `stack-run hexblock` |
| transformer training & inference | `quadmesh/meshtron` | `stack-run meshtron` |
| all three | chained | `stack-run pipeline` |

Each module runs on its own. They are in one image so that they can also run
*together*, in one process tree — which is what makes learned meshing during a
live optimization possible at all, rather than a container hop per candidate.

### What is deliberately not here: `optimizer`

The `optimizer` repository is **not** installed into the image. Nothing in the
three modules imports it, and its optimization layer duplicates
`eigenfrequencies/optimize/` while being the weaker of the two everywhere they
overlap — 51 lines of differential evolution against 223, one backend against
four, a process-pool evaluator against the cluster-proven Pyro5 one. Its
evaluator plugins are stubs its own README marks as intentionally unregistered.

It also declares `d3rlpy` as a *core* dependency, which would drag a second
torch constraint into `venv-sci` next to the pinned `torch==2.11.0+cu128`.
Paying that for code nothing calls is the wrong trade.

What the repository does hold that exists nowhere else is the offline-RL
material: `rl/smoke.py`, and a `data/` converter that turns hydroflow-opt run
artifacts into a d3rlpy dataset — the current format, where
`eigenfrequencies/optimize/rl/offline_export.py` still reads the superseded
`de_history*.jsonl`. When roadmap phase D (T13/T14, the RL backend) starts,
that is the piece to bring in, and re-adding it here is a line in
`stages/60-venv-sci.sh`.

## Three hosts, two images

| Host | Role | Image |
|---|---|---|
| Build machine (Linux, many cores, GPU) | **builds** both images | — |
| Workstation | development + smoke runs, agent confined | `stack-agent.sif` |
| HPC (bwUniCluster 3.0) | production runs | `stack.sif` |
| Publication / third parties | reproduction | `stack.sif` |

`stack.sif` carries the complete pipeline and **no agent tooling at all**, not
even node. `stack-agent.sif` derives from it and adds node/npm, nothing else.
That split is what lets "install this without the agent infrastructure" be
literally true instead of approximately true.

Building requires root or `--fakeroot`, which is why it happens only on the
build machine: on the workstation the agent runs inside a finished, read-only
image and cannot build, install or escape anything.

## Install

The research repositories are **not** submodules of this one — they are
independent repositories that you clone side by side, and `stack.conf` points
at them. Nothing here pins their versions; `/opt/stack-manifest.txt` inside a
built image records what actually went in.

```bash
mkdir stack && cd stack
git clone --recurse-submodules git@github.com:RentschlerTobias/quadmesh.git
git clone git@github.com:RentschlerTobias/eigenfrequencies.git
git clone git@github.com:RentschlerTobias/hydrostack.git
```

`quadmesh` needs `--recurse-submodules`: `domain_partition`,
`domain_partition_3D` and `meshtron` live inside it and are not separate
top-level checkouts.

Then, on the build machine:

```bash
cd hydrostack
cp stack.conf.example stack.conf   # set STACK_REPOS to the directory above
./install.sh --check               # preflight: apptainer, fakeroot, disk, tmpdir
./install.sh --build               # hours — dtOO, OpenFOAM, AlgoHex, torch
./install.sh --build-agent         # minutes — derives the agent variant
```

Apptainer: `pacman -S apptainer` (Arch), or the `.deb` from the
[Apptainer releases](https://github.com/apptainer/apptainer/releases) on
Ubuntu. Budget ~40 GB free disk for a base build — the peak is the unpacked
rootfs during the build, not the finished image.

Then copy what each host needs:

```bash
scp "$STACK_IMAGES/stack-agent.sif"  workstation:stack-images/
scp "$STACK_IMAGES/stack.sif"        hpc:"$WS/stack-images/"
```

## Use

```bash
./bin/stack-doctor                 # verify the sandbox and the pipeline
./bin/stack-doctor --unconfined    # negative control: containment MUST fail

./bin/stack-shell                  # confined shell, no agent tooling
./bin/stack-agent opencode         # confined agent session
./bin/stack-agent claude

./bin/stack-run cfd-opt profiles/local.toml --dry-run
./bin/stack-run hexblock mesh.msh --smoke
./bin/stack-run meshtron train --help

sbatch slurm/submit.sh profiles/hpc.toml
```

## The sandbox, and what it does not do

Apptainer is not Docker, and the difference matters here.

A SIF is a single immutable squashfs file. There is no daemon and you do not
need root to run one. Inside the container you are **the same user with the
same UID** as outside — that is the HPC security property: a container cannot
be used to gain privilege.

The corollary is the part people get wrong: **Apptainer does not isolate by
default.** It was designed for HPC convenience, so by default it mounts your
entire `$HOME`, your `$PWD`, `/tmp`, `/var/tmp`, and passes the host
environment through. The network namespace is shared with the host. An agent
started with a plain `apptainer exec` is sitting in your home directory.

What `bin/stack-agent` does about that:

| Flag | Effect |
|---|---|
| `--containall` | no host `$HOME`, no host `/tmp`, clean environment, own PID and IPC namespaces |
| `--writable-tmpfs` | scratch that evaporates on exit; the image stays immutable |
| `--bind` (explicit) | the only host paths that exist inside: `/work`, `/opt/stack`, `/agent` |
| env allowlist | only named variables (API keys, `TERM`) cross the boundary |

And the load-bearing one, which is not a flag: **the image contains no
`apptainer` binary.** Confinement comes from the mounts being chosen at
container *start*, by you. Anyone who can invoke `apptainer` chooses their own
mounts — `apptainer exec --bind /:/host …` gives back everything your user can
read. That is why every pipeline stage lives in this one image and is reached
as an ordinary subprocess: an agent that had to start a second container to run
CFD would need exactly the tool the sandbox exists to withhold.

**Three things this does not give you:**

1. **Network isolation.** The agents need outbound network for their APIs, so
   the network namespace stays shared with the host. The agent cannot read the
   institute's files; it can still reach the institute's network. Closing that
   needs an allowlist proxy or a VM, and is out of scope here.
2. **Protection against malicious code.** Apptainer's own documentation is
   clear that it is not a security boundary against a hostile process; it rests
   on user namespaces. Against a *careless* agent — the actual threat model —
   it is appropriate and sufficient. Against a hostile one, use a VM.
3. **Protection from your own credentials.** Anything in the env allowlist is
   inside with the agent. Keep that list short.

Verify rather than trust:

```bash
./bin/stack-doctor              # expects PASS
./bin/stack-doctor --unconfined # expects the containment checks to FAIL
```

The second command is not decoration. A containment test that passes however
the container was started tests nothing, and would keep passing after someone
drops `--containall` from a wrapper. `--unconfined` exits 0 only when
containment is correctly reported as broken.

## What is inside

Base `ubuntu:24.04`. Both halves of the stack exist for it: `dolfinx` ships
Ubuntu 24.04 images, and `dtOO-ThirdParty` carries a `Dockerfile.ubuntu` that
builds the whole dtOO stack there with OpenFOAM 2606 from the official deb
repository. The stock dtOO image is openSUSE, so without that recipe there
would be no common base.

Two Python environments, because the stages share a filesystem but never a
process:

| Env | Python | Holds | Used by |
|---|---|---|---|
| `/opt/venv-dtoo` | 3.13 | dtOO SWIG bindings, foamlib, pythonocc | geometry export, CFD |
| `/opt/venv-sci` | 3.12 (`--system-site-packages`) | dolfinx, torch+cu128, pygmo,  hydroflow-opt, the research repos | modal, hex blocks, meshtron, orchestration |

The research repos are installed **editable** against `/opt/stack/<repo>`. On the
workstation your host checkout is bind-mounted onto exactly that path, so the
editable install keeps resolving and the code stays editable. On HPC and for
third parties nothing is mounted and the copy baked into the image runs. One
recipe, both modes.

Build stages live in `apptainer/stages/` and run in filename order. Each is
`set -e`, so a failing stage fails the build and **no image is written** —
including `90-verify.sh`, which imports every stack in the environment that
will actually run it.

### Known risks

- **MPI coexistence.** OpenFOAM ships its own openmpi; dolfinx pulls another.
  They coexist in the filesystem but must never share one `LD_LIBRARY_PATH`.
  Nothing puts either on the global environment — the per-stage setup constants
  in `eigenfrequencies/.../hydroflow/physics.py` do that, per stage.
  `eigenfrequencies/docs/install.md` states that these two stacks "do not
  coexist in one environment"; that was said of a conda environment, and this
  image is the experiment that tests it. Not yet proven on real hardware.
- **Unpinned upstream dependencies.** AlgoHex pins gmm, Eigen, OpenVolumeMesh,
  TinyAD and CoMISo by hash or commit, but tracks *branches* for HexEx
  (`algohex`), HexHex (`main`), TrulySeamless3D, MC3D and QGP3D (`cgg`) — and
  its Dockerfile builds `Bonmin@master`. Two builds a month apart are therefore
  not guaranteed to be the same software. Stage 50 cannot fix upstream's
  pinning, so it records what each dependency actually resolved to in
  `/opt/stack-manifest.txt`. Read that file before citing a result.
- **Build-time network.** AlgoHex fetches dependencies at cmake configure time
  from `gitlab.vci.rwth-aachen.de:9000` and `graphics.rwth-aachen.de:9000`. A
  build host that blocks outbound port 9000 fails in stage 50.

## Licensing

The repositories in this project carry their own licences. Two third-party
components impose obligations worth stating up front:

- **AlgoHex** is **AGPL-3.0**. It is built from source into this image
  (`apptainer/stages/50-algohex.sh`, pinned to commit `3519289`). Distributing
  the image, or offering it as a network service, carries AGPL obligations for
  that component.
- **dtOO** and **OpenFOAM** have their own terms; see their repositories.

`/opt/stack-manifest.txt` inside the image lists every component and the commit
it was built from.
