# Contributing to AetherRoute

## Development baseline

- Apple Silicon Mac
- macOS 15 or newer
- Current Xcode with Swift 6
- Rust toolchain pinned by `Core/Engine/rust-toolchain.toml`
- Go version declared by `Services/DistributionService/go.mod`
- `jq`, `git`, and GitHub CLI for release maintainers

Clone with submodules and follow the build sequence in `README.md`. Never add
generated core archives, DerivedData, test evidence, signing material,
subscriptions, customer data, or release credentials to Git.

## Changes

1. Create a focused branch from `main`.
2. Use a Conventional Commit subject such as `fix:`, `feat:`, `test:`,
   `docs:`, `refactor:`, or `chore:`.
3. Keep application and embedded-core changes in their respective repositories;
   update the submodule pointer only after its commit has passed core tests.
4. Run `./scripts/test_repository_ci.sh` for repository checks and
   `./scripts/test.sh` for the complete unsigned product gate.
5. Use only the designated isolated Mac for real Network Extension testing.
   Ordinary tests must not modify the host proxy, DNS, routes, or TUN state.
6. Open a pull request with test evidence, risk notes, screenshots for every UI
   surface changed, and a rollback description when behavior or persistence
   changes.

The maintainer uses squash merging and deletes merged topic branches. Stable
release tags are created only from an accepted `main` commit through the
process in `Docs/ReleaseProcess.md`.
