#!/usr/bin/env bash
# Shared setup for the stack wrappers. Sourced, not executed.
#
# Everything that makes the sandbox a sandbox lives here, in one place, because
# the containment is only as good as the flags — and a flag that has to be
# retyped per invocation is a flag that will eventually be forgotten. A
# forgotten --containall does not fail: it silently gives the agent your whole
# home directory.

set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$BIN_DIR")"

if [[ -f "$REPO_ROOT/stack.conf" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/stack.conf"
else
    # shellcheck source=/dev/null
    source "$REPO_ROOT/stack.conf.example"
fi

STACK_IMAGES="${STACK_IMAGES:-$HOME/stack-images}"
STACK_REPOS="${STACK_REPOS:-$HOME/repos/duty}"
STACK_WORK="${STACK_WORK:-$HOME/stack-work}"
STACK_AGENT_HOME="${STACK_AGENT_HOME:-$HOME/.stack-agent}"

STACK_SIF="${STACK_SIF:-$STACK_IMAGES/stack.sif}"
STACK_AGENT_SIF="${STACK_AGENT_SIF:-$STACK_IMAGES/stack-agent.sif}"

die() { echo "error: $*" >&2; exit 1; }

require_apptainer() {
    command -v apptainer >/dev/null || die "apptainer not found"
}

require_image() {
    local img="$1"
    [[ -f "$img" ]] || die "image not found: $img
  Build it on the build host:  ./install.sh --build
  Then copy it here."
}

# Environment variables forwarded into the container. --containall implies
# --cleanenv, which wipes everything — deliberate, but the agents genuinely
# need their credentials. An explicit allowlist is the right shape for that:
# adding a name here is a decision someone made, not an accident of the shell.
ENV_ALLOWLIST=(
    ANTHROPIC_API_KEY
    ANTHROPIC_BASE_URL
    OPENCODE_API_KEY
    OPENAI_API_KEY
    TERM
    COLORTERM
    LANG
)

# Populates the global array ENV_ARGS. Returning an array through stdout is
# how empty-array bugs get written in bash; a global is honest here.
ENV_ARGS=()
build_env_args() {
    ENV_ARGS=()
    for name in "${ENV_ALLOWLIST[@]}"; do
        if [[ -n "${!name:-}" ]]; then
            ENV_ARGS+=(--env "$name=${!name}")
        fi
    done
}

# The confinement flags. Read this list before changing it:
#
#   --containall     drops the host $HOME, the host /tmp, the host environment,
#                    and adds PID and IPC namespaces. This is the flag. Without
#                    it Apptainer mounts your entire home directory by default,
#                    because it was designed for HPC convenience, not isolation.
#   --writable-tmpfs gives the container a scratch layer that evaporates on
#                    exit, so the image itself stays immutable.
#   --no-mount home  belt and braces alongside --containall.
#   --bind           the ONLY paths from the host that exist inside.
#
# Note what is NOT here: --net. The agents need outbound network for their
# APIs, so the network namespace stays shared with the host. This sandbox
# confines the filesystem, not the network. See README.
CONFINE_ARGS=()
build_confine_args() {
    CONFINE_ARGS=(
        --containall
        --writable-tmpfs
        --no-mount home
        --pwd /work
    )

    [[ -d "$STACK_WORK" ]] || mkdir -p "$STACK_WORK"
    CONFINE_ARGS+=(--bind "$STACK_WORK:/work")

    # The repo bind is what makes the code editable: the editable installs
    # inside the image were recorded against /opt/stack/<repo>, so mounting the
    # host checkout at the identical path keeps them resolving.
    if [[ -d "$STACK_REPOS" ]]; then
        CONFINE_ARGS+=(--bind "$STACK_REPOS:/opt/stack")
    else
        echo "note: $STACK_REPOS not found; using the checkout baked into the image" >&2
    fi

    # GPU passthrough only when there is a GPU. On the institute workstation
    # there is not, and --nv would fail rather than degrade.
    if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
        CONFINE_ARGS+=(--nv)
    fi
}
