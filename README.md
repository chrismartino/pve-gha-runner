# pve-gha-runner

[![CI](https://github.com/chrismartino/pve-gha-runner/actions/workflows/ci.yml/badge.svg)](https://github.com/chrismartino/pve-gha-runner/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Docs site: <https://chrismartino.github.io/pve-gha-runner/>

Scripts to create and manage self-hosted GitHub Actions runners as LXC
containers on a Proxmox VE host — either as a persistent runner or as a pool
of ephemeral, one-job-and-recreate runners.

Adapted and enhanced from
[oNaiPs/proxmox-scripts](https://github.com/oNaiPs/proxmox-scripts)
(`lxc_create_github_actions_runner.sh`), which is also MIT-licensed. See
[Credits](#credits--differences-from-the-original) for what changed.

> [!WARNING]
> **Use these runners with private repositories.** On a public repository, a
> pull request from a fork can run arbitrary code on a self-hosted runner.
> Ephemeral containers limit the damage but do not make that safe. These
> scripts also run **as root on your Proxmox host** — read them before you
> run them.

## Status and support

- Tested on Proxmox VE 9 with Ubuntu 24.04 containers. Other versions are
  untested.
- Maintained on a best-effort basis, with no SLA. Questions belong in
  [Discussions](https://github.com/chrismartino/pve-gha-runner/discussions);
  bugs in [Issues](https://github.com/chrismartino/pve-gha-runner/issues).
- Report security problems privately — see [SECURITY.md](SECURITY.md).
- Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).

## What's here

| File | Purpose |
|---|---|
| `create-pve-lxc-gha-runner.sh` | Creates an unprivileged Ubuntu 24.04 LXC container and registers it as a GitHub Actions runner (Docker and other extra dependencies are optional — see [Installing extra dependencies](#installing-extra-dependencies)). Run by hand, or invoked automatically by the hookscript. |
| `gha_runner_hookscript.sh` | Proxmox post-stop hookscript. Only used in ephemeral mode: when a runner container powers off after finishing its one job, this destroys it and creates its replacement. One file serves every repo — it identifies which repo a container belongs to via its `repo-<slug>` tag and sources that repo's config from `/etc/gha-runner/<slug>.conf`. |
| `gha-runner-hook.logrotate` | logrotate config for the hookscript's logs — one `recreate-<slug>.log`/`hook-<slug>.log` pair per repo. Only needed in ephemeral mode — see step 5 under [Ephemeral runner pool](#ephemeral-runner-pool-self-healing). |
| `stop-and-cleanup-gha-runners.sh` | Stops and destroys (`--purge`) every `gha-runner-*` container without letting the hookscript recreate them. See [Stopping and cleaning up all runners](#stopping-and-cleaning-up-all-runners). |

## Prerequisites

- Proxmox VE **9** (LXC 6 + cgroup v2). This is required for Docker to work
  reliably inside an **unprivileged** container, which is how this script
  provisions runners. Earlier PVE versions may work if you're willing to run
  privileged containers instead, but that isn't what this script does.
- `openssl` and `curl` available on the Proxmox host (both ship by default).
- A storage with the `vztmpl` content type enabled, for the Ubuntu template
  (the default `local` storage has this).
- If you plan to use ephemeral mode: a storage with the `snippets` content
  type enabled for the hookscript (also `local` by default — `local-zfs`
  typically does not have this).
- A GitHub App used for authentication (see below) instead of a personal
  access token.

## 1. Create a GitHub App

This script authenticates as a **GitHub App**, not a long-lived
`GITHUB_TOKEN`/PAT. It signs a short-lived JWT with the App's private key,
exchanges it for an installation access token, and uses that to request the
runner's registration token. Nothing long-lived is stored on disk or passed
into the container.

1. Go to **Settings → Developer settings → GitHub Apps → New GitHub App**
   (for an organization, create it under the org's settings instead).
2. Give it any name and a placeholder homepage URL (not used by this script).
3. Under **Repository permissions**, grant **Administration: Read and
   write** — this is what grants access to the runner
   registration-token endpoint.
   - **This is a broad permission** (it also covers repo settings and
     branch protection). Create a **dedicated App** for this purpose, install
     it only on the repositories that need runners, and keep its private key
     root-only on the Proxmox host.
   - For **organization-level** runners, grant the narrower **Organization
     permission** "Self-hosted runners: Read and write" instead and run with
     `GITHUB_SCOPE=org` — see
     [Organization-level runners](#organization-level-runners). Prefer this
     when it fits your setup.
4. Deselect webhook subscriptions (not needed).
5. Create the app, then generate and download a **private key (.pem)** —
   store it somewhere only root can read on the Proxmox host.
6. Note the **App ID** (shown on the app's settings page).
7. **Install the App** on the target repository (or organization).

You now have three values: the App ID, the path to the `.pem` key, and the
`owner/repo` you're installing runners for.

## 2. Install the script on the Proxmox host

```sh
ssh root@<pve-host> install -d -m 700 /root/scripts
scp create-pve-lxc-gha-runner.sh root@<pve-host>:/root/scripts/
ssh root@<pve-host> chmod +x /root/scripts/create-pve-lxc-gha-runner.sh
```

(Or `git clone https://github.com/chrismartino/pve-gha-runner.git` directly
on the host and copy the scripts into `/root/scripts/` as shown under
[Upgrading](#upgrading).) The examples below assume you are in that
directory (`cd /root/scripts`). This is also where the hookscript looks for
it by default (`MAIN_SCRIPT_PATH`).

Tagged [releases](https://github.com/chrismartino/pve-gha-runner/releases)
include the scripts, a source tarball and a `SHA256SUMS` file, with build
provenance attestations. To verify a downloaded file:

```sh
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify <file> --repo chrismartino/pve-gha-runner
```

## 3. Run it

### Persistent runner (simplest)

Creates one container that registers as a normal, long-lived runner (via
`svc.sh install`) and keeps handling jobs until you remove it.

```sh
cd /root/scripts
./create-pve-lxc-gha-runner.sh
```

You'll be prompted for the GitHub App ID, the private key path, and
`owner/repo`. You can skip the prompts by exporting them first:

```sh
export GITHUB_APP_ID=123456
export GITHUB_APP_PRIVATE_KEY_PATH=/root/my-app.private-key.pem
export OWNERREPO=someorg/somerepo
./create-pve-lxc-gha-runner.sh
```

### Ephemeral runner pool (self-healing)

In this mode each container registers with `--ephemeral` (GitHub deregisters
it after exactly one job), runs the job via a one-shot systemd unit, and
powers itself off when done. The hookscript then destroys that container and
creates a fresh one to take its place — so there's always a runner available
without ever reusing container state between jobs.

**One-time setup:**

1. Copy the hookscript to a storage with the `snippets` content type and
   make it executable:

   ```sh
   cp gha_runner_hookscript.sh /var/lib/vz/snippets/
   chmod 700 /var/lib/vz/snippets/gha_runner_hookscript.sh
   ```

2. Put the creation script somewhere permanent. The default is
   `/root/scripts/create-pve-lxc-gha-runner.sh`; if it's elsewhere, update
   `MAIN_SCRIPT_PATH` in the **CONFIG** block at the top of
   `gha_runner_hookscript.sh`.

3. For **each repo**, create a per-repo config file at
   `/etc/gha-runner/<slug>.conf`, where `<slug>` is `owner/repo` with `/`
   replaced by `-` and lowercased (e.g. `someorg/somerepo` →
   `/etc/gha-runner/someorg-somerepo.conf`):

   ```sh
   mkdir -p /etc/gha-runner
   cat > /etc/gha-runner/someorg-somerepo.conf <<'EOF'
   GITHUB_APP_ID="123456"
   GITHUB_APP_PRIVATE_KEY_PATH="/root/my-app.private-key.pem"
   OWNERREPO="someorg/somerepo"
   EOF
   chmod 600 /etc/gha-runner/someorg-somerepo.conf
   ```

   One hookscript file serves every repo: at post-stop time it reads back the
   `repo-<slug>` tag Proxmox stores on the container (set automatically by
   the main script at creation) and sources that repo's config file. Each
   private key must be root-only readable (`chmod 600`). See
   [`examples/repo.conf.example`](examples/repo.conf.example) for the full
   set of optional fields (`MAX_RUNNERS`, `EXTRA_INSTALL_SCRIPT`,
   `GITHUB_APP_INSTALLATION_ID`).

4. Create the **first** container for each repo by hand, once, with
   `EPHEMERAL_RUNNER=true` so it picks up both the `-hookscript` flag
   pointing at the file from step 1 and the `repo-<slug>` tag. Every
   container it creates after that inherits both automatically:

   ```sh
   EPHEMERAL_RUNNER=true \
   GITHUB_APP_ID=123456 \
   GITHUB_APP_PRIVATE_KEY_PATH=/root/my-app.private-key.pem \
   OWNERREPO=someorg/somerepo \
   ./create-pve-lxc-gha-runner.sh
   ```

5. Install the log rotation config, or the per-repo `recreate-<slug>.log`/
   `hook-<slug>.log` pairs under `/var/lib/gha-runner-hook/` will grow
   unbounded:

   ```sh
   cp gha-runner-hook.logrotate /etc/logrotate.d/gha-runner-hook
   ```

From then on, the cycle is: container runs one job → powers off → hookscript
destroys it → hookscript recreates it → repeat. No further manual steps.
Repeat steps 3–4 for each additional repo you want a pool for — steps 1, 2,
and 5 only need doing once, ever.

The hookscript re-invokes itself via `systemd-run` as a detached transient
unit (falling back to a plain backgrounded job if `systemd-run` isn't
available) rather than just backgrounding itself in place — this is what
lets the destroy/recreate actually complete instead of intermittently
failing with a "permission denied" error while mounting the replacement
container's dataset, which the sandboxed context the hookscript inherits at
post-stop time could otherwise cause.

**Runner pool size:** `MAX_RUNNERS` (default `3`) is **per repo** — it caps
how many `gha-runner-*` containers tagged for a given repo (`repo-<slug>`)
can exist concurrently, checked before any container is created, whether
triggered by hand or by the hookscript. Different repos can have different
pool sizes. Raise it for a given repo either by exporting it for a manual
run, or by setting `MAX_RUNNERS` in that repo's `/etc/gha-runner/<slug>.conf`
so the hookscript picks it up on every recreation:

```sh
MAX_RUNNERS=5 EPHEMERAL_RUNNER=true ... ./create-pve-lxc-gha-runner.sh
```

**If registration keeps failing** (revoked App install, bad key, GitHub API
unreachable), the hookscript has a flap guard, tracked **per container**: it
refuses to recreate a given `VMID` more than once every 60 seconds, destroys
the broken container, and logs the reason via `logger` (tag `gha-runner-hook`
— `journalctl -t gha-runner-hook` shows every repo's entries together, each
line prefixed `[<repo-slug>]`; also mirrored to that repo's
`/var/lib/gha-runner-hook/recreate-<slug>.log`) instead of spinning. Fix the
underlying issue, then rerun the main script by hand with
`EPHEMERAL_RUNNER=true` to resume.

### Stopping and cleaning up all runners

Because the hookscript fires on **any** stop of a container it's attached to
— not just the end-of-job poweroff — a plain `pct stop` + `pct destroy` loop
would just get every container recreated out from under you. Use
`stop-and-cleanup-gha-runners.sh` instead:

```sh
./stop-and-cleanup-gha-runners.sh
```

Run as root on the Proxmox host. It finds every `gha-runner-*` container,
removes its `-hookscript` property before stopping it (so nothing gets
recreated), then destroys it (`pct destroy --purge`) and clears its
flap-guard state. It also stops any recreate job already in flight from a
stop that happened moments earlier, and sweeps a few passes to catch a
recreate that still slips through the race window. It prompts for
confirmation and lists what it's about to touch first; pass `-y` to skip the
prompt for non-interactive use. It only touches `gha-runner-*` containers —
your `/etc/gha-runner/*.conf` files and the scripts themselves are untouched,
so the next manual run or first-container setup works as before.

## Installing extra dependencies

The container only gets `git`, `curl`, and `zip` by default — **Docker is
not installed automatically**. For Docker, language runtimes, or any other
CLIs your jobs need, point `EXTRA_INSTALL_SCRIPT` at a script on the Proxmox
host — it's pushed into the container and run once, before the runner
registers:

```sh
EXTRA_INSTALL_SCRIPT=/root/scripts/my-extra-deps.sh \
GITHUB_APP_ID=123456 \
GITHUB_APP_PRIVATE_KEY_PATH=/root/my-app.private-key.pem \
OWNERREPO=someorg/somerepo \
./create-pve-lxc-gha-runner.sh
```

An example that installs Docker CE is in
[`examples/install-docker.sh`](examples/install-docker.sh).

In ephemeral mode this reruns on **every** container recreation (once per
job), so keep it fast. To use it with the hookscript's self-recreating pool,
set `EXTRA_INSTALL_SCRIPT` in that repo's `/etc/gha-runner/<slug>.conf` (see
step 3 under [Ephemeral runner pool](#ephemeral-runner-pool-self-healing)).

## Organization-level runners

By default the script registers **repo-level** runners. For an **org-level**
pool, set `GITHUB_SCOPE=org` and give the organization name instead of
`OWNERREPO`:

1. Grant the GitHub App the **organization** permission "Self-hosted
   runners: Read and write". This is narrower than the repo-level
   `Administration` permission, so prefer it when you can.
2. Install the App on the organization.
3. Run the script (or the first ephemeral container) with the org scope:

   ```sh
   GITHUB_SCOPE=org \
   GITHUB_ORG=someorg \
   GITHUB_APP_ID=123456 \
   GITHUB_APP_PRIVATE_KEY_PATH=/root/my-app.private-key.pem \
   EPHEMERAL_RUNNER=true \
   ./create-pve-lxc-gha-runner.sh
   ```

For the ephemeral pool's per-repo config, an org pool's file is named
`/etc/gha-runner/org.<org>.conf` (org name lowercased) and sets
`GITHUB_SCOPE="org"` and `GITHUB_ORG` instead of `OWNERREPO` — see
[`examples/repo.conf.example`](examples/repo.conf.example). Containers are
tagged `repo-org.<org>`, and `MAX_RUNNERS` applies per org.

## Upgrading

Check the [changelog](CHANGELOG.md): each release has an **Upgrade** line saying
whether you need to do anything beyond the steps below. Then, from your
clone, check out the version you want and reinstall both scripts:

```sh
git fetch --tags && git checkout <version>   # or: git pull
install -m 700 create-pve-lxc-gha-runner.sh /root/scripts/
install -m 700 gha_runner_hookscript.sh /var/lib/vz/snippets/
```

That's it. Running containers pick up the new hookscript the next time they
stop and are recreated; you don't need to touch them. To roll back, check out
the previous version and run the two `install` commands again.

To see which version is installed:

```sh
/root/scripts/create-pve-lxc-gha-runner.sh --version
grep -m1 '^VERSION=' /var/lib/vz/snippets/gha_runner_hookscript.sh
```

After the next job, `journalctl -t gha-runner-hook` also shows the hookscript's
version, and logs a warning if it differs from the creation script's.

Both commands are needed because Proxmox runs the **copy in the snippets
directory**, not the file in your clone. Adjust the paths if you changed
`MAIN_SCRIPT_PATH` or use a different snippets storage, and if you edited the
CONFIG block at the top of the hookscript, re-apply that edit afterwards.

## Configuration reference

Variables at the top of `create-pve-lxc-gha-runner.sh`:

| Variable | Default | Notes |
|---|---|---|
| `TEMPL_URL` | Ubuntu 24.04 LTS | Matches GitHub's own `ubuntu-latest` hosted runners. If this 404s (point-release rotation), run `pveam update && pveam available \| grep ubuntu-24.04` on the host to find the current filename. |
| `PCTSIZE` | `20G` | Container disk size. |
| `PCT_CORES` / `PCT_MEMORY` / `PCT_SWAP` | `4` / `4096` / `4096` | Container resources. |
| `PCT_STORAGE` | `local-zfs` | Where the container's rootfs is provisioned. |
| `TEMPL_STORAGE` | `local` | Where the Ubuntu template is downloaded (must support `vztmpl`; `local-zfs` usually doesn't). |
| `MAX_RUNNERS` | `3` | Max concurrent `gha-runner-*` containers **for the given repo** (`repo-<slug>` tag), not a global cap across all repos. Env var. |
| `GITHUB_SCOPE` | `repo` | `repo` (uses `OWNERREPO`) or `org` (uses `GITHUB_ORG`). Env var. See [Organization-level runners](#organization-level-runners). |
| `EPHEMERAL_RUNNER` | `false` | Set `true` to use ephemeral mode. Env var. |
| `EXTRA_INSTALL_SCRIPT` | (unset) | Path to a local script to run inside the container for extra dependencies. Env var. See [Installing extra dependencies](#installing-extra-dependencies). |
| `HOOKSCRIPT_VOLID` | `local:snippets/gha_runner_hookscript.sh` | Proxmox volid of the hookscript; only used when `EPHEMERAL_RUNNER=true`. |

Runner version is **not** pinned — the script resolves and downloads the
latest `actions/runner` release at run time and verifies it against GitHub's
published SHA-256 checksum when available.

## Security notes

- The GitHub App's private key never leaves the Proxmox host and is never
  copied into a container.
- The runner registration token is pushed into the container as a file and
  run there, rather than being passed inline in a `pct exec ... bash -c
  "...$TOKEN..."` command, to avoid the token showing up in `ps` output on
  the **host**. It's still briefly visible in the container's own process
  list while `config.sh` runs — that's a limitation of the runner binary
  itself (it only accepts the token as a CLI flag), not something a wrapper
  can avoid.
- These scripts run as root on the Proxmox host, and the hookscript sources
  `/etc/gha-runner/<slug>.conf` as root. Keep `/etc/gha-runner/` and the
  scripts writable by root only. Inputs (`OWNERREPO`, `GITHUB_ORG`) are
  validated, and the repo slug read from a container tag is validated
  before it is used to locate a config file.
- Don't register these runners against **public** repositories (see the
  warning at the top). Use a dedicated GitHub App, installed only where it is
  needed.
- Containers are unprivileged, with root's password locked (`passwd -l`)
  rather than deleted, so no PAM configuration can treat the account as
  passwordless. `pct exec`/`pct enter` from the host still work regardless.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). To
report a vulnerability, use the repository's **Security** tab rather than a
public issue.

## Credits & differences from the original

This project started from
[oNaiPs/proxmox-scripts](https://github.com/oNaiPs/proxmox-scripts)'s
`lxc_create_github_actions_runner.sh` (MIT license) and has been adapted and
extended:

1. **Network** — DHCP instead of a static IP/gateway.
2. **Auth** — GitHub App + short-lived installation token instead of a
   long-lived `GITHUB_TOKEN`/PAT; nothing long-lived is stored or passed
   into the container.
3. **Container isolation** — created unprivileged (`-unprivileged 1`, plus
   `fuse=1` alongside nesting/keyctl) instead of privileged, relying on PVE
   9's LXC 6 + cgroup v2 for unprivileged Docker support.
4. **Ephemeral mode** — optional one-job-per-container pool with a
   self-recreating hookscript, instead of always installing a persistent
   service.
5. Runner version resolved dynamically (latest release + checksum
   verification) rather than pinned to a version that goes stale.

See the original repo's README for its own setup instructions if you want to
compare behavior or fall back to the static-IP/privileged/PAT-based
approach.

## AI usage

Portions of this project — including bug fixes such as the ephemeral
container recreate race and the logrotate config — were developed with AI
assistance. Every change was human reviewed before being committed by
someone with 20+ years of industry experience, who is accountable for the
correctness and security of what's in this repo regardless of how it was
drafted.
