# One-Minute Limits and Release Builder Design

## Goal

Provide two Linux shell scripts without directly maintaining a forked source diff:

1. Patch a qui source tree so FREE_SPACE delete automations and cross-seed RSS automation can run at a minimum interval of one minute.
2. Detect a new stable GitHub release, update the primary repository, build the release in an isolated Git worktree, apply the patch, and build the binary and Docker image.

The scripts must not depend on source line numbers and must fail safely when upstream code no longer matches the expected features.

## Patch Script

The patch script will be stored at `scripts/apply-one-minute-limits.sh`. It accepts an optional source-directory argument and defaults to the current repository.

The Bash entry point will validate the target tree and invoke an embedded Python 3 program for multiline, feature-based transformations. Each transformation will use named constants, function-specific expressions, comments, React state variables, or translation keys as semantic anchors. It will verify the expected match count before writing any files.

The transformations are:

- Set the backend `freeSpaceDeleteCooldown` constant to one minute.
- Remove the React effect that automatically changes a one-minute FREE_SPACE delete interval to five minutes.
- Enable the one-minute interval option for FREE_SPACE delete rules.
- Remove the obsolete five-minute cooldown tooltip and warning from the workflow dialog.
- Set the cross-seed RSS backend minimum to one minute in settings normalization, manual-run throttling, and scheduled-run calculation.
- Set the cross-seed RSS frontend minimum constant to one minute.
- Update directly adjacent comments whose documented minimum would otherwise be incorrect.
- Update the frontend Docker build stage from `node:22.18-alpine` to `node:24-alpine`, matching the frontend's declared Node requirement.
- Include `web/pnpm-workspace.yaml` in the Docker dependency-metadata `COPY`, so pnpm sees the same overrides recorded in the frozen lockfile.

The script will be idempotent. A target already at the desired value or with the obsolete UI blocks already removed is accepted. The Dockerfile transformations accept either the exact affected release form or the exact corrected form. The target must contain `web/pnpm-workspace.yaml` before the Dockerfile is changed. A missing, duplicated, or structurally ambiguous target causes a non-zero exit before files are committed to disk. The Python program will calculate all updated contents first and only then replace changed files, preventing partial edits caused by a later failed matcher.

## Release Builder Script

The release builder will be stored at `scripts/build-latest-release.sh`. It discovers the repository from its own location, with an optional repository argument for testing and alternate deployments.

The workflow is:

1. Confirm required commands and a valid Git repository.
2. Update the checked-out branch with `git pull --rebase`, preserving local script commits on top of the latest upstream branch, then fetch and prune tags from `origin`. Git remains responsible for stopping when local changes conflict.
3. Resolve the latest stable GitHub release through the `https://github.com/autobrr/qui/releases/latest` redirect and extract its tag.
4. Compare the tag with a last-successful-release marker stored under the repository's Git common directory, so the marker does not dirty the worktree.
5. If unchanged, exit successfully without building.
6. If new, create or reuse a detached worktree for that tag under a configurable worktree root. The default root is a sibling directory of the primary repository.
7. Invoke `apply-one-minute-limits.sh` against the release worktree.
8. Run `make build`, followed by `make build/docker`, inside that worktree.
9. Write the successful-release marker atomically only after both builds complete.
10. Remove older registered release worktrees under the managed root, keeping the latest successful worktree.

If patching or building fails, the marker is not advanced and the failed worktree is retained for diagnosis and retry. Cleanup only targets Git worktrees registered under the configured managed root; it does not remove arbitrary directories.

## Release and State Semantics

- "Latest release" means GitHub's latest stable, non-prerelease release.
- On the first run, the current latest stable release is treated as new.
- A failed build is retried on the next run because only successful builds update state.
- Existing failed worktrees are reused, relying on the patch script's idempotence.
- The Makefile's existing Docker tag and build arguments remain unchanged; the script executes the requested `make build/docker` target as-is.

## Dependencies

The scripts require Linux, Bash, Git, curl, Python 3, Make, Docker, and qui's normal Go and pnpm build dependencies. No `jq` dependency is required.

## Verification

Verification will use a disposable worktree so the primary source tree is not patched directly:

- Shell syntax checks with `bash -n`.
- First-run and second-run/idempotence checks for the patch script.
- Assertions that all targeted backend and frontend limits are one minute and obsolete five-minute UI enforcement is absent.
- Assertions that the patched Dockerfile uses Node 24 and copies `web/pnpm-workspace.yaml` before the frozen pnpm install.
- A failure-path assertion that an unexpected Dockerfile structure leaves every fixture file unchanged.
- Targeted Go tests for `internal/services/automations` and `internal/services/crossseed`, always with `-race -count=1`.
- Repository-required `make precommit` and `make build` against the patched worktree.
- A controlled release-builder test using command stubs or a disposable Git repository, avoiding an unintended real Docker build during script testing.

The final report will state which required checks ran, which were skipped, and any unresolved failures.
