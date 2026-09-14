#!/usr/bin/env bash
#SBATCH --job-name=stack_opt
#SBATCH --output=stack_opt_%j.out
#SBATCH --time=48:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
#SBATCH --partition=cpu_il
#
# One optimization on a single node, inside stack.sif.
#
#   sbatch slurm/submit.sh profiles/hpc.toml
#   DRY_RUN=1 bash slurm/submit.sh profiles/hpc.toml     # on a login node
#
# The lean stack.sif is what belongs here: a batch job has no use for the agent
# toolchain, and it is the smaller file to move onto the parallel filesystem.
#
# --exclusive grants the whole node. Fixed --mem/--cpus-per-task figures get
# rejected on some partitions, so taking the node and validating the config
# against what SLURM actually granted is the robust order. That validation is
# the point of this script: hydroflow-opt checks
# concurrent x ranks x threads <= available_cpus, but it cannot know what the
# allocation is, so a config claiming 64 cores inside a 20-core allocation
# passes its own check and then oversubscribes the node.

set -euo pipefail

CONFIG="${1:-}"
[[ -n "$CONFIG" ]] || { echo "usage: sbatch $0 PROFILE.toml" >&2; exit 2; }
[[ -f "$CONFIG" ]] || { echo "[submit] ERROR: config not found: $CONFIG" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$REPO_ROOT/stack.conf" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/stack.conf"
fi
STACK_IMAGES="${STACK_IMAGES:-$HOME/stack-images}"
SIF="${STACK_SIF:-$STACK_IMAGES/stack.sif}"

echo "========================================"
echo "[submit] host=$(hostname 2>/dev/null || echo unknown) job=${SLURM_JOB_ID:-none}"
echo "[submit] config=$CONFIG"
echo "[submit] image=$SIF"
echo "========================================"

command -v apptainer >/dev/null || { echo "[submit] ERROR: no apptainer" >&2; exit 1; }
[[ -f "$SIF" ]] || { echo "[submit] ERROR: image not found: $SIF" >&2; exit 1; }

# Provenance in the job log. Several AlgoHex dependencies are tracked by branch
# upstream, so "which software produced this run" is answered by the image, not
# by a version number.
echo "[submit] --- image manifest ---"
apptainer exec "$SIF" cat /opt/stack-manifest.txt || true
echo "[submit] ------------------------"

# ── resource check ────────────────────────────────────────────────────────
read -r CFG_CPUS CFG_CONC CFG_RANKS CFG_THREADS <<<"$(
    apptainer exec "$SIF" /opt/venv-sci/bin/python - "$CONFIG" <<'PY'
import sys, tomllib
res = tomllib.load(open(sys.argv[1], "rb")).get("resources", {})
print(res.get("available_cpus", 1), res.get("concurrent_evaluations", 1),
      res.get("mpi_ranks", 1), res.get("threads_per_rank", 1))
PY
)"

GRANTED="${SLURM_CPUS_ON_NODE:-$(nproc)}"
NEED=$(( CFG_CONC * CFG_RANKS * CFG_THREADS ))

echo "[submit] config wants ${NEED} cores (${CFG_CONC} x ${CFG_RANKS} x ${CFG_THREADS})"
echo "[submit] config declares available_cpus=${CFG_CPUS}; allocation grants ${GRANTED}"

if (( NEED > GRANTED )); then
    echo "[submit] ERROR: the config would oversubscribe this allocation." >&2
    echo "[submit] Lower concurrent_evaluations or request a bigger node." >&2
    exit 1
fi
if (( CFG_CPUS > GRANTED )); then
    echo "[submit] WARNING: available_cpus=${CFG_CPUS} exceeds the ${GRANTED} granted." >&2
fi

# ── scratch ───────────────────────────────────────────────────────────────
# One candidate leaves a ~21 MB mesh and a decomposed OpenFOAM case behind.
# Node-local NVMe, not the parallel filesystem.
WORK="${STACK_WORK:-$PWD}"
SCRATCH="${TMPDIR:-/tmp}"
BINDS=(--bind "$WORK:/work" --bind "$SCRATCH:$SCRATCH")
[[ -n "${WS:-}" && -d "${WS:-}" ]] && BINDS+=(--bind "$WS:$WS")

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[submit] DRY_RUN=1 — validating the config and stopping."
    exec apptainer exec "${BINDS[@]}" "$SIF" \
        stack-run cfd-opt "$CONFIG" --dry-run
fi

echo "[submit] starting"
exec srun --ntasks=1 apptainer exec "${BINDS[@]}" "$SIF" \
    stack-run cfd-opt "$CONFIG"
