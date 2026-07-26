# Changelog

All notable changes to this project are documented here.

## [0.4.0] - 2026-07-27

### Features

- folder picker for multi-repo sessions
- local-first workflow, worktree isolation and headless exec
- modernize the container and add a test suite

### Bug Fixes

- require only the tools the requested operation actually uses
- git refused to work on bind-mounted repos owned by another uid
- image smoke tests aborted on a Linux CI runner
- nothing may freeze, mislead, or vanish without saying so


## [0.3.0] - 2026-02-13

Releases up to this point were tagged manually and predate automated changelog
generation. Summarised from git history:

- Optional headless browser, CLI tool updates, parallel agents, skills discovery
- OpenAI Codex support
- Local repository support (`cs .`)
- SSH agent forwarding for OrbStack
- Container environment fixes and mount guards

## [0.2.0] - 2026-01-24

- `--link`, `--uninstall` and `--update` installer flags
- Sandbox context injected for the agent, screenshot sharing
- ASCII logo, repository counts

## [0.1.0] - 2026-01-24

- Initial release
