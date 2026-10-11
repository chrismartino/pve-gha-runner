# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Upgrade notes

Each release lists what, if anything, you must do on an existing installation
under an **Upgrade** line, and marks incompatible changes **Breaking**. The
general procedure is in the README's
[Upgrading](README.md#upgrading) section.

## [Unreleased]

### Fixed

- The release workflow attaches its assets to a release that already exists
  (for example one created from GitHub's "Draft a new release" page) instead
  of failing.

## [1.2.0] - 2026-10-11

**Upgrade:** no action needed for existing repo-level pools. Update both
scripts as described in the README. Org-level pools (`GITHUB_SCOPE=org`) are
opt-in.

### Added

- `GITHUB_SCOPE=org` / `GITHUB_ORG` for org-level runner pools (previously a
  manual edit of the script).
- GitHub Pages site, CI (shellcheck, shfmt, actionlint, zizmor, links),
  release workflow, and community files.
- A `VERSION` in the creation script and the hookscript. The creation script
  logs it and supports `--version`; the hookscript logs it on every post-stop
  and warns if the two scripts are on different versions.
- `.gitignore` for private keys (`*.pem`, `*.key`), `.env` files, and local configs.

### Changed

- The default location of the creation script is `/root/scripts/` rather than
  `/root/`; set `MAIN_SCRIPT_PATH` in the hookscript if yours is elsewhere.
- `OWNERREPO` and `GITHUB_ORG` are validated before use.
- The hookscript validates the repo slug from the container tag before
  sourcing its config.
- shellcheck findings fixed; scripts are executable in git.

## Earlier history

Versions 1.0.0 (the original scripts and hookscript fixes) and 1.1.0
(multi-repo ephemeral pools) predate this changelog; see their
[GitHub releases](https://github.com/chrismartino/pve-gha-runner/releases).
