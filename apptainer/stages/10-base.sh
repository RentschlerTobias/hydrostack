#!/usr/bin/env bash
# Stage 10 — base system and build toolchain.
#
# Shared by every later stage. Deliberately contains NO node/npm: agent tooling
# belongs to the derived stack-agent.sif, so that the published stack.sif can be
# said to carry no agent infrastructure and mean it literally.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg software-properties-common \
    git ripgrep less nano \
    build-essential g++ gfortran \
    cmake ninja-build make automake autoconf libtool patch pkg-config \
    binutils libc-dev locales time tzdata \
    libblas-dev liblapack-dev libeigen3-dev \
    libgmp-dev libsuitesparse-dev \
    python3 python3-dev python3-venv python3-pip

# AlgoHex's own Dockerfile asks for libopenblas64-serial-dev, a Debian name.
# Ubuntu noble splits the same thing differently; take whichever exists rather
# than hardcoding a name that silently is not there.
apt-get install -y --no-install-recommends libopenblas-dev \
    || apt-get install -y --no-install-recommends libopenblas64-serial-dev

locale-gen en_US.UTF-8 || true

mkdir -p /opt/stack /work

{
    echo "=== stack manifest ==="
    echo "base: ubuntu:24.04"
    echo "system python: $(python3 --version 2>&1)"
} > /opt/stack-manifest.txt

echo "stage 10 OK"
