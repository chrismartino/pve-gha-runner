# Security policy

## Threat model

These scripts run **as root on a Proxmox VE host**. They create containers,
read a GitHub App private key from the host's filesystem, and (for the
ephemeral pool) source per-repo config files from `/etc/gha-runner/` as root.
A vulnerability here can mean code execution on someone's hypervisor, so
please report issues privately.

Things worth reporting:

- Command or argument injection through any value the scripts read (env
  vars, prompts, config files, container tags, GitHub API responses).
- Anything that causes the GitHub App private key, an installation token or
  a runner registration token to be written somewhere readable by other
  users, logged, or copied into a container.
- Ways a job running inside a runner container could reach the host or other
  containers because of how the scripts configure them.
- Integrity problems in how the runner or the Ubuntu template is downloaded
  and verified.

Out of scope: the inherent risk of running self-hosted runners for
**public** repositories (a fork PR can run arbitrary code on the runner).
The README advises against it.

## Supported versions

Only the latest release is supported. Security fixes ship as a new release, so
please upgrade rather than asking for a patch to an older version.

## Reporting a vulnerability

Use GitHub's private reporting: open the repository's **Security** tab and
choose **Report a vulnerability**
(<https://github.com/chrismartino/pve-gha-runner/security/advisories/new>).
Please do not open a public issue for a suspected vulnerability.

Include the affected script and version or commit, your Proxmox VE version,
and steps to reproduce. **Redact** App IDs, private keys, tokens and
hostnames before attaching logs.

This is a spare-time project: expect an acknowledgement within about a week
and a fix or mitigation plan as soon as practical. Reporters are credited in
the release notes unless they prefer otherwise.
