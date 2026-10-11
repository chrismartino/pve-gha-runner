# Contributing

Thanks for helping out. This project is a small set of Bash scripts that
run as root on a Proxmox VE host, so changes are reviewed carefully.

## Before you start

- For anything bigger than a bug fix or doc tweak, open an issue or a
  Discussion first so we can agree on the approach.
- Security problems: do **not** open an issue. See [SECURITY.md](SECURITY.md).
- By contributing you agree your work is released under the
  [MIT license](LICENSE).

## Testing

There is no way to fully test these scripts without a Proxmox VE 9 host, so
please say in your PR what you ran them on and what you checked (persistent
runner, ephemeral pool, the stop/cleanup script, repo or org scope).
CI cannot do this for you; it only lints.

Use a throwaway host or a test GitHub App and repository, never one that
matters. Don't paste App IDs, keys, tokens or hostnames into issues, PRs or
logs.

## Style and checks

CI runs these on every PR; run them locally first:

```sh
shellcheck -S style *.sh examples/*.sh .github/maintainer/*.sh
shfmt -d -i 4 -ci *.sh examples/*.sh .github/maintainer/*.sh   # see .editorconfig
bash -n create-pve-lxc-gha-runner.sh gha_runner_hookscript.sh stop-and-cleanup-gha-runners.sh
```

- Bash, 4-space indent, LF line endings (see `.editorconfig`).
- Quote variables. Prefer fixing a shellcheck finding to disabling it; if you
  must disable one, add a comment saying why.
- Keep comments in the existing style: explain *why* (the failure mode, the
  race, the PVE quirk), not what the line does.
- Anything that handles the App key or tokens must keep them off the host's
  process list and out of logs. The README's security notes explain the
  current approach.
- Update the README (and `examples/`) when you change behaviour or add a
  variable.

## Pull requests

- One logical change per PR, branched from `main`. PRs are squash-merged, so
  the PR title becomes the commit message: make it a clear imperative
  sentence.
- Fill in the PR template. CI must pass.

## AI-assisted contributions

AI assistance is fine, as the README itself discloses. You are accountable
for every line you submit: read it, understand it, and test it on real
hardware before opening the PR. Unreviewed generated code will be closed.

## Code of conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
