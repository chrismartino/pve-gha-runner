# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `GITHUB_SCOPE=org` / `GITHUB_ORG` for org-level runner pools (previously a
  manual edit of the script).
- GitHub Pages site, CI (shellcheck, shfmt, actionlint, zizmor, links),
  release workflow, and community files.

### Changed

- `OWNERREPO` and `GITHUB_ORG` are validated before use.
- The hookscript validates the repo slug from the container tag before
  sourcing its config.
- shellcheck findings fixed; scripts are executable in git.

## Earlier history

Pre-release work (single-repo and multi-repo ephemeral pools, hookscript
race fixes, logrotate config) predates this changelog; see the git log.
