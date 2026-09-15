#!/usr/bin/env bash
# Build the pipeline images.
#
# This script only ever runs on the BUILD host (see README: "Three hosts, two
# images"). Apptainer needs root or --fakeroot to build, which is precisely why
# everything has to be complete before the image ships: on the institute
# workstation the agent runs inside a finished, read-only image and cannot
# build anything.
#
#   ./install.sh --clone          clone the three research repositories
#   ./install.sh --check          preflight only, changes nothing
#   ./install.sh --build          build stack.sif       (hours, from scratch)
#   ./install.sh --build-agent    build stack-agent.sif (minutes, derived)
#   ./install.sh --stage 50-algohex   re-run one stage into a sandbox (dev loop)
#
# Configuration comes from ./stack.conf; see stack.conf.example. With the
# default layout there is nothing to configure: the repositories are cloned
# next to this one.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# The research repositories, in the order they are cloned and staged. One list,
# so adding a repository is one line rather than four scattered edits.
#
# This script cannot clone the repository it lives in, so hydrostack is not
# here: `git clone hydrostack` is the step before running it at all.
STACK_REPO_NAMES=(domain_partition_3D eigenfrequencies meshtron)
STACK_GIT_BASE="${STACK_GIT_BASE:-git@github.com:RentschlerTobias}"

# ── configuration ─────────────────────────────────────────────────────────

if [[ -f "$REPO_ROOT/stack.conf" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/stack.conf"
else
    echo "note: no stack.conf, using defaults from stack.conf.example" >&2
    # shellcheck source=/dev/null
    source "$REPO_ROOT/stack.conf.example"
fi

STACK_IMAGES="${STACK_IMAGES:-$HOME/stack-images}"
STACK_TMPDIR="${STACK_TMPDIR:-/var/tmp/apptainer}"
STACK_NCPU="${STACK_NCPU:-$(nproc)}"

# Default: the directory this repository sits in. `--clone` puts the others
# beside it, so the common case needs no stack.conf at all:
#
#     stack/
#     ├── hydrostack/          <- you are here
#     ├── domain_partition_3D/
#     ├── eigenfrequencies/
#     └── meshtron/
STACK_REPOS="${STACK_REPOS:-$(dirname "$REPO_ROOT")}"

SIF="$STACK_IMAGES/stack.sif"
AGENT_SIF="$STACK_IMAGES/stack-agent.sif"
SHA_FILE="$SIF.sha256"

# Disk needed for a base build: the unpacked rootfs is the peak, not the
# finished image. Measured components: dtOO+OpenFOAM ~7 GB, dolfinx ~3 GB,
# torch+cu128 ~4 GB, AlgoHex+coin-or ~3 GB, plus the squashfs being written.
MIN_FREE_GB_BASE=40
MIN_FREE_GB_AGENT=5

die() { echo "error: $*" >&2; exit 1; }
say() { echo "[install] $*"; }

# ── preflight ─────────────────────────────────────────────────────────────

free_gb() {
    # df of a path that may not exist yet: walk up to the nearest parent.
    local p="$1"
    while [[ ! -d "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
    df -BG --output=avail "$p" | tail -1 | tr -dc '0-9'
}

preflight() {
    local need_gb="$1"

    command -v apptainer >/dev/null \
        || die "apptainer not found. Arch: pacman -S apptainer; Ubuntu: see README."

    say "apptainer: $(apptainer --version)"

    # Building needs privilege. As root it is implicit; otherwise --fakeroot
    # must actually work, and it silently does not when /etc/subuid has no
    # entry for the user. Probing beats failing an hour into a build.
    if [[ "$(id -u)" -ne 0 ]]; then
        BUILD_PRIV=(--fakeroot)
        if ! grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
            die "--fakeroot needs an /etc/subuid entry for $(id -un).
  Fix: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)"
        fi
    else
        BUILD_PRIV=()
    fi

    mkdir -p "$STACK_IMAGES" "$STACK_TMPDIR"

    # /tmp is tmpfs on many systems, i.e. RAM. A dtOO rootfs unpacked there
    # takes the machine down rather than the build.
    if [[ "$(df --output=fstype "$STACK_TMPDIR" | tail -1)" == "tmpfs" ]]; then
        die "STACK_TMPDIR=$STACK_TMPDIR is tmpfs (RAM-backed). Point it at real disk."
    fi

    local have
    have="$(free_gb "$STACK_IMAGES")"
    [[ "$have" -ge "$need_gb" ]] \
        || die "need ~${need_gb} GB free under $STACK_IMAGES, have ${have} GB"
    say "free space: ${have} GB under $STACK_IMAGES"

    export APPTAINER_TMPDIR="$STACK_TMPDIR"
    export APPTAINER_CACHEDIR="$STACK_TMPDIR/cache"
}

# ── clone ─────────────────────────────────────────────────────────────────

clone_repos() {
    command -v git >/dev/null || die "git not found"
    mkdir -p "$STACK_REPOS"

    say "cloning into $STACK_REPOS"
    local cloned=0 present=0

    for repo in "${STACK_REPO_NAMES[@]}"; do
        local dest="$STACK_REPOS/$repo"

        if [[ -d "$dest/.git" ]]; then
            # Idempotent on purpose: re-running --clone must never touch work in
            # progress. Report where it stands and move on; updating is the
            # user's call, in their own repository.
            local branch dirty
            # symbolic-ref, not rev-parse --abbrev-ref: on a detached or
            # unborn HEAD the latter still prints "HEAD" *and* fails, so a
            # `|| echo ?` fallback appends rather than replaces and the line
            # comes out across two lines.
            branch="$(git -C "$dest" symbolic-ref --short -q HEAD 2>/dev/null)" \
                || branch="detached"
            dirty="$(git -C "$dest" status --porcelain 2>/dev/null | wc -l)"
            say "  $repo: already present (branch $branch, $dirty uncommitted)"
            present=$((present + 1))
            continue
        fi

        if [[ -e "$dest" ]]; then
            die "$dest exists but is not a git repository. Move it aside first."
        fi

        say "  $repo: cloning"
        git clone --quiet "$STACK_GIT_BASE/$repo.git" "$dest" \
            || die "clone of $repo failed.
  The private repositories need an SSH key on the GitHub account.
  Override the base URL with STACK_GIT_BASE if you use a different remote."
        cloned=$((cloned + 1))
    done

    say "done: $cloned cloned, $present already present"
    [[ "$present" -eq 0 ]] || say "note: existing checkouts were left untouched"
    say "next: ./install.sh --check"
}

# ── build ─────────────────────────────────────────────────────────────────

# The image ships a working checkout of the three repos, not an empty
# placeholder: on the cluster and for third parties nothing is bind-mounted, so
# the baked copy is what runs. On the agent host the host checkout is mounted
# over it at the same path, which is what keeps the editable installs resolving.
stage_repos() {
    local ctx="$REPO_ROOT/.build-context/repos"
    rm -rf "$ctx"
    mkdir -p "$ctx"

    for repo in "${STACK_REPO_NAMES[@]}"; do
        [[ -d "$STACK_REPOS/$repo" ]] || die \
"$STACK_REPOS/$repo not found.
  Clone the research repositories first:  ./install.sh --clone
  Or point STACK_REPOS at an existing checkout in stack.conf."
        say "staging $repo"
        # Excludes matter: the repos carry multi-GB run outputs, virtualenvs and
        # histories that have no business in an image.
        rsync -a --delete \
            --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
            --exclude='*.pyc' --exclude='.pytest_cache' --exclude='node_modules' \
            --exclude='output/' --exclude='runs/' --exclude='runs_*/' \
            --exclude='slurm_logs/' --exclude='logs/' --exclude='enroot-images/' \
            --exclude='*.sif' --exclude='*.sqsh' --exclude='*.tar.gz' \
            --exclude='.omo' --exclude='.opencode' \
            "$STACK_REPOS/$repo/" "$ctx/$repo/"
    done

    say "staged context: $(du -sh "$ctx" | cut -f1)"
}

build_base() {
    preflight "$MIN_FREE_GB_BASE"
    command -v rsync >/dev/null || die "rsync not found (needed to stage the repos)"
    stage_repos

    say "building $SIF with $STACK_NCPU jobs"
    say "this is a from-scratch build: dtOO, OpenFOAM, AlgoHex and torch."
    say "budget hours, not minutes."

    # Build to a temporary name and move on success, so an interrupted build
    # never leaves a half-written .sif that looks usable.
    apptainer build "${BUILD_PRIV[@]}" \
        "$SIF.partial" \
        apptainer/stack.def

    mv "$SIF.partial" "$SIF"
    sha256sum "$SIF" | awk '{print $1}' > "$SHA_FILE"

    say "built $SIF"
    say "sha256: $(cat "$SHA_FILE")"
    say "next: ./install.sh --build-agent   (for the agent host)"
    say "      ./bin/stack-doctor           (verify containment)"
}

build_agent() {
    preflight "$MIN_FREE_GB_AGENT"

    [[ -f "$SIF" ]] || die "$SIF not found; run --build first"
    [[ -f "$SHA_FILE" ]] || die "$SHA_FILE not found; rebuild the base"

    # The whole point of the two-variant split is that the derived image is
    # provably the same base. If the base on disk is not the one we recorded,
    # deriving from it would produce two artifacts nobody can tie together.
    local actual recorded
    actual="$(sha256sum "$SIF" | awk '{print $1}')"
    recorded="$(cat "$SHA_FILE")"
    [[ "$actual" == "$recorded" ]] || die \
"base image checksum does not match the recorded one.
  recorded: $recorded
  actual:   $actual
The base was replaced or corrupted since it was built. Rebuild it."

    say "deriving $AGENT_SIF from stack.sif ($actual)"

    apptainer build "${BUILD_PRIV[@]}" \
        --build-arg BASE_SHA="$actual" \
        --build-arg BASE_SIF="$SIF" \
        "$AGENT_SIF.partial" \
        apptainer/stack-agent.def

    mv "$AGENT_SIF.partial" "$AGENT_SIF"
    say "built $AGENT_SIF"
}

# ── development helper ────────────────────────────────────────────────────

run_stage() {
    local stage="$1"
    local file="apptainer/stages/${stage}.sh"
    [[ -f "$file" ]] || die "no such stage: $file
  available: $(cd apptainer/stages && ls *.sh | sed 's/\.sh$//' | tr '\n' ' ')"

    preflight 5
    local sandbox="$STACK_TMPDIR/sandbox"
    [[ -d "$sandbox" ]] || die \
"no sandbox at $sandbox.
  Create one first (slow, but then stages are re-runnable individually):
    apptainer build ${BUILD_PRIV[*]} --sandbox $sandbox apptainer/stack.def"

    say "re-running stage $stage in $sandbox"
    apptainer exec "${BUILD_PRIV[@]}" --writable "$sandbox" \
        bash "/opt/build-stages/${stage}.sh"
}

# ── main ──────────────────────────────────────────────────────────────────

usage() {
    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# Report which research repositories are in place. Part of --check because a
# missing checkout is the cheapest build failure to find before the build.
check_repos() {
    local missing=0
    for repo in "${STACK_REPO_NAMES[@]}"; do
        if [[ -d "$STACK_REPOS/$repo" ]]; then
            say "repo: $repo"
        else
            say "repo: $repo MISSING"
            missing=$((missing + 1))
        fi
    done
    [[ "$missing" -eq 0 ]] || die \
"$missing of ${#STACK_REPO_NAMES[@]} repositories missing under $STACK_REPOS.
  Clone them:  ./install.sh --clone"
}

[[ $# -ge 1 ]] || usage 1

case "$1" in
    --clone)        clone_repos ;;
    --check)        say "repos: $STACK_REPOS"
                    check_repos
                    preflight "$MIN_FREE_GB_BASE"
                    say "preflight OK" ;;
    --build)        build_base ;;
    --build-agent)  build_agent ;;
    --stage)        [[ $# -eq 2 ]] || usage 1; run_stage "$2" ;;
    -h|--help)      usage 0 ;;
    *)              die "unknown option: $1 (try --help)" ;;
esac
