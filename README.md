# pve-gha-runner

Scripts to create and manage self-hosted GitHub Actions runners as LXC
containers on a Proxmox VE host — either as a persistent runner or as a pool
of ephemeral, one-job-and-recreate runners.

Adapted and enhanced from
[oNaiPs/proxmox-scripts](https://github.com/oNaiPs/proxmox-scripts)
(`lxc_create_github_actions_runner.sh`), which is also MIT-licensed. See
[Credits](#credits--differences-from-the-original) for what changed.

## What's here

| File | Purpose |
|---|---|
| `create-pve-lxc-gha-runner.sh` | Creates an unprivileged Ubuntu 24.04 LXC container, installs Docker, and registers it as a GitHub Actions runner. Run by hand, or invoked automatically by the hookscript. |
| `gha_runner_hookscript.sh` | Proxmox post-stop hookscript. Only used in ephemeral mode: when a runner container powers off after finishing its one job, this destroys it and creates its replacement. |

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
   - For **organization-level** runners instead of repo-level, grant the
     **Organization permission** "Self-hosted runners: Read and write"
     instead, and see [Organization-level runners](#organization-level-runners)
     below for the one line you need to change in the script.
4. Deselect webhook subscriptions (not needed).
5. Create the app, then generate and download a **private key (.pem)** —
   store it somewhere only root can read on the Proxmox host.
6. Note the **App ID** (shown on the app's settings page).
7. **Install the App** on the target repository (or organization).

You now have three values: the App ID, the path to the `.pem` key, and the
`owner/repo` you're installing runners for.

## 2. Install the script on the Proxmox host

```sh
scp create-pve-lxc-gha-runner.sh root@<pve-host>:/root/
ssh root@<pve-host> chmod +x /root/create-pve-lxc-gha-runner.sh
```

(Or `git clone https://github.com/chrismartino/pve-gha-runner.git` directly
on the host.)

## 3. Run it

### Persistent runner (simplest)

Creates one container that registers as a normal, long-lived runner (via
`svc.sh install`) and keeps handling jobs until you remove it.

```sh
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

2. Put the creation script somewhere permanent (e.g. `/root/`) and edit the
   **CONFIG** block at the top of `gha_runner_hookscript.sh`:

   ```sh
   MAIN_SCRIPT_PATH="/root/create-pve-lxc-gha-runner.sh"
   GITHUB_APP_ID="123456"
   GITHUB_APP_PRIVATE_KEY_PATH="/root/my-app.private-key.pem"
   OWNERREPO="someorg/somerepo"
   ```

   The hookscript runs as root and reads the private key path directly, so
   make sure that key file is root-only readable (`chmod 600`).

3. Create the **first** container by hand, once, with `EPHEMERAL_RUNNER=true`
   so it picks up the `-hookscript` flag pointing at the file from step 1.
   Every container it creates after that inherits the flag automatically:

   ```sh
   EPHEMERAL_RUNNER=true \
   GITHUB_APP_ID=123456 \
   GITHUB_APP_PRIVATE_KEY_PATH=/root/my-app.private-key.pem \
   OWNERREPO=someorg/somerepo \
   ./create-pve-lxc-gha-runner.sh
   ```

From then on, the cycle is: container runs one job → powers off → hookscript
destroys it → hookscript recreates it → repeat. No further manual steps.

**Runner pool size:** `MAX_RUNNERS` (default `3`) caps how many
`gha-runner-*` containers can exist concurrently — checked via `pct list`
before any container is created, whether triggered by hand or by the
hookscript. Raise it if you want more parallel runners:

```sh
MAX_RUNNERS=5 EPHEMERAL_RUNNER=true ... ./create-pve-lxc-gha-runner.sh
```

**If registration keeps failing** (revoked App install, bad key, GitHub API
unreachable), the hookscript has a flap guard: it refuses to recreate more
than once every 60 seconds, destroys the broken container, and logs the
reason via `logger` (tag `gha-runner-hook`, also mirrored to
`/var/lib/gha-runner-hook/recreate.log`) instead of spinning. Fix the
underlying issue, then rerun the main script by hand with
`EPHEMERAL_RUNNER=true` to resume.

## Organization-level runners

By default the script requests a **repo-level** registration token. For an
**org-level** runner:

1. Grant the GitHub App the organization permission "Self-hosted runners:
   Read and write" instead of the repo `Administration` permission.
2. In `create-pve-lxc-gha-runner.sh`, change the registration-token request
   URL from:

   ```
   https://api.github.com/repos/$OWNERREPO/actions/runners/registration-token
   ```

   to:

   ```
   https://api.github.com/orgs/$ORG/actions/runners/registration-token
   ```

   (both the token-request URL and the `--url` passed to `config.sh` need
   `$OWNERREPO` swapped for your org name — see the comments near the bottom
   of the script).

## Configuration reference

Variables at the top of `create-pve-lxc-gha-runner.sh`:

| Variable | Default | Notes |
|---|---|---|
| `TEMPL_URL` | Ubuntu 24.04 LTS | Matches GitHub's own `ubuntu-latest` hosted runners. If this 404s (point-release rotation), run `pveam update && pveam available | grep ubuntu-24.04` on the host to find the current filename. |
| `PCTSIZE` | `20G` | Container disk size. |
| `PCT_CORES` / `PCT_MEMORY` / `PCT_SWAP` | `4` / `4096` / `4096` | Container resources. |
| `PCT_STORAGE` | `local-zfs` | Where the container's rootfs is provisioned. |
| `TEMPL_STORAGE` | `local` | Where the Ubuntu template is downloaded (must support `vztmpl`; `local-zfs` usually doesn't). |
| `MAX_RUNNERS` | `3` | Max concurrent `gha-runner-*` containers. Env var. |
| `EPHEMERAL_RUNNER` | `false` | Set `true` to use ephemeral mode. Env var. |
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
- Containers are unprivileged, with root's password locked (`passwd -l`)
  rather than deleted, so no PAM configuration can treat the account as
  passwordless. `pct exec`/`pct enter` from the host still work regardless.

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
