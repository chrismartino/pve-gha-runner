#!/usr/bin/env bash
#
# Example EXTRA_INSTALL_SCRIPT: installs Docker CE from Docker's official
# apt repo. Pass this to create-pve-lxc-gha-runner.sh via:
#
#   EXTRA_INSTALL_SCRIPT=/path/to/install-docker.sh ./create-pve-lxc-gha-runner.sh
#
# Runs as root inside the container (that's how the runner service itself
# runs too - see RUNNER_ALLOW_RUNASROOT in the main script), so no sudo and
# no docker group membership is needed.
#
set -e

# Prereqs for adding Docker's apt repo
apt-get update
apt-get install -y ca-certificates curl gnupg git

# Docker's official apt repo (Ubuntu)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
