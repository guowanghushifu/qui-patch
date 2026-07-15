# One-Minute Limits and Release Builder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two Linux shell scripts that safely patch qui's FREE_SPACE delete and RSS minimum intervals to one minute, then detect, patch, and build each new stable release in an isolated worktree.

**Architecture:** The patch entry point is Bash with an embedded Python 3 transformer so multiline source features can be matched without line numbers. The release builder updates the primary Git checkout, discovers GitHub's latest stable release, uses a detached managed worktree, advances state only after both builds succeed, and removes older managed worktrees.

**Tech Stack:** Bash, Python 3 standard library, Git worktrees, curl, Make, existing Go and pnpm toolchains, Docker.

---

## File Structure

- Create `scripts/apply-one-minute-limits.sh`: validate and atomically transform a supplied qui source tree.
- Create `scripts/build-latest-release.sh`: update Git state, detect releases, manage worktrees, call the patch script, and run builds.
- Create `scripts/tests/test-apply-one-minute-limits.sh`: exercise transformation, assertions, failure behavior, and idempotence in a temporary fixture.
- Create `scripts/tests/test-build-latest-release.sh`: exercise first build, no-op repeat, failed-build retry, state recording, and old-worktree cleanup with a temporary Git remote and command stubs.

### Task 1: Patch Script Contract Test

**Files:**
- Create: `scripts/tests/test-apply-one-minute-limits.sh`
- Test fixtures copied at runtime from:
  - `internal/services/automations/service.go`
  - `internal/services/crossseed/service.go`
  - `internal/models/crossseed.go`
  - `web/src/pages/CrossSeedPage.tsx`
  - `web/src/components/instances/preferences/WorkflowDialog.tsx`

- [ ] **Step 1: Write the failing test**

Create an executable Bash test that copies only the five target files to `mktemp -d`, invokes `scripts/apply-one-minute-limits.sh`, and asserts:

```bash
rg -q 'const freeSpaceDeleteCooldown = 1 \* time\.Minute' "$fixture/internal/services/automations/service.go"
rg -q 'settings\.RunIntervalMinutes < 1' "$fixture/internal/services/crossseed/service.go"
test "$(rg -c 'max\(time\.Duration\(intervalMinutes\)\*time\.Minute, time\.Minute\)' "$fixture/internal/services/crossseed/service.go")" -eq 2
rg -q 'const MIN_RSS_INTERVAL_MINUTES = 1' "$fixture/web/src/pages/CrossSeedPage.tsx"
! rg -q 'Auto-switch interval from 1 minute' "$fixture/web/src/components/instances/preferences/WorkflowDialog.tsx"
rg -q 'oneMinute"\), \}' "$fixture/web/src/components/instances/preferences/WorkflowDialog.tsx"
! rg -q 'cooldownAria|cooldownDescription|cooldownWarning' "$fixture/web/src/components/instances/preferences/WorkflowDialog.tsx"
```

Capture SHA-256 checksums after the first run, invoke the patch script a second time, and require identical checksums. Make a second fixture with the named cooldown constant removed and require the patch script to fail without changing any other fixture file.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bash scripts/tests/test-apply-one-minute-limits.sh
```

Expected: FAIL because `scripts/apply-one-minute-limits.sh` does not exist.

### Task 2: Implement the Feature-Matched Patch Script

**Files:**
- Create: `scripts/apply-one-minute-limits.sh`
- Test: `scripts/tests/test-apply-one-minute-limits.sh`

- [ ] **Step 1: Add the Bash entry point**

Use strict mode, resolve the optional target directory, check `python3`, and verify all five target files exist:

```bash
#!/usr/bin/env bash
set -euo pipefail

target_dir=${1:-.}
target_dir=$(cd "$target_dir" && pwd -P)
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
```

- [ ] **Step 2: Add an atomic Python transformer**

The embedded Python program must read all files before writing, keep an in-memory `original` and `updated` map, and expose helpers with these contracts:

```python
def replace_required(path, description, pattern, replacement, expected, flags=0):
    """Replace exactly expected semantic matches or raise PatchError."""

def remove_optional_feature(path, description, pattern, absent_markers, flags=0):
    """Remove exactly one old feature; accept an already-removed feature."""

def accept_old_or_new(path, description, old_pattern, new_pattern, replacement, flags=0):
    """Replace one old form or require exactly one already-patched form."""
```

Apply these transformations with named anchors and strict counts:

```python
# internal/services/automations/service.go
r"const freeSpaceDeleteCooldown = \d+ \* time\.Minute" ->
"const freeSpaceDeleteCooldown = 1 * time.Minute"  # exactly 1

# web/src/components/instances/preferences/WorkflowDialog.tsx
# Remove the useEffect beginning with:
#   // Auto-switch interval from 1 minute when FREE_SPACE delete condition is added
# and ending at its dependency array.
# Change only the oneMinute interval option from disabled to enabled.
# Change intervalOptions dependencies from [deleteUsesFreeSpace, t] to [t].
# Remove the JSX blocks containing cooldownDescription and cooldownWarning.

# internal/services/crossseed/service.go
r"settings\.RunIntervalMinutes < \d+" -> "settings.RunIntervalMinutes < 1"
r"settings\.RunIntervalMinutes = \d+" -> "settings.RunIntervalMinutes = 1"
r"max\(time\.Duration\(intervalMinutes\)\*time\.Minute, \d+\*time\.Minute\)" ->
"max(time.Duration(intervalMinutes)*time.Minute, time.Minute)"  # exactly 2

# web/src/pages/CrossSeedPage.tsx
r"const MIN_RSS_INTERVAL_MINUTES = \d+" ->
"const MIN_RSS_INTERVAL_MINUTES = 1"  # exactly 1
```

Limit the `RunIntervalMinutes = number` replacement to the normalization branch immediately following the named less-than check, so the default value `120` is untouched. Update the adjacent minimum comments in the same matched blocks and the `RunIntervalMinutes` model comment.

After all matchers succeed, write only changed files through a temporary sibling file and `os.replace`, preserving each file's mode. Print one `patched:` or `already patched:` summary per file.

- [ ] **Step 3: Run the test until it passes**

Run:

```bash
chmod +x scripts/apply-one-minute-limits.sh scripts/tests/test-apply-one-minute-limits.sh
bash scripts/tests/test-apply-one-minute-limits.sh
```

Expected: PASS for first application, idempotence, and fail-fast fixture checks.

- [ ] **Step 4: Commit the patch script and test**

```bash
git add scripts/apply-one-minute-limits.sh scripts/tests/test-apply-one-minute-limits.sh
git commit -m "feat(scripts): patch one-minute automation limits"
```

### Task 3: Release Builder Contract Test

**Files:**
- Create: `scripts/tests/test-build-latest-release.sh`
- Test target: `scripts/build-latest-release.sh`

- [ ] **Step 1: Write the failing integration test**

Create a temporary bare `origin`, a seed repository with branch `develop`, and tags `v1.0.0` then `v1.1.0`. Clone it as the primary repository. Put command stubs first in `PATH`:

```bash
# curl stub
printf 'https://github.com/autobrr/qui/releases/tag/%s' "${FAKE_RELEASE_TAG:?}"

# make stub
printf '%s:%s\n' "$PWD" "$*" >> "${MAKE_LOG:?}"
if [[ ${FAIL_DOCKER_BUILD:-0} == 1 && $* == "build/docker" ]]; then exit 42; fi

# patch stub
printf '%s\n' "$1" >> "${PATCH_LOG:?}"
```

Run the future builder with:

```bash
QUI_PATCH_SCRIPT="$patch_stub" \
QUI_RELEASE_WORKTREE_ROOT="$tmp/worktrees" \
FAKE_RELEASE_TAG=v1.0.0 \
bash scripts/build-latest-release.sh "$primary"
```

Assert the first run records `v1.0.0`, calls the patch once, calls `make build` then `make build/docker`, and leaves one worktree. Run again and assert the logs are unchanged. Publish `v1.1.0`, force the Docker stub to fail, and assert state remains `v1.0.0`; rerun successfully and assert state advances to `v1.1.0`, the old worktree is removed, and the new worktree remains.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bash scripts/tests/test-build-latest-release.sh
```

Expected: FAIL because `scripts/build-latest-release.sh` does not exist.

### Task 4: Implement the Release Builder

**Files:**
- Create: `scripts/build-latest-release.sh`
- Test: `scripts/tests/test-build-latest-release.sh`

- [ ] **Step 1: Add repository update and release discovery**

Implement strict Bash behavior and required command checks. Resolve the primary repo from the optional first argument, require a checked-out branch, then run:

```bash
git -C "$repo" pull --rebase origin "$branch"
git -C "$repo" fetch --prune --tags origin
latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  https://github.com/autobrr/qui/releases/latest)
latest_tag=${latest_url%/}
latest_tag=${latest_tag##*/}
```

Reject an empty tag, ensure `refs/tags/$latest_tag` exists after fetching, and resolve the Git common directory as an absolute path.

- [ ] **Step 2: Add state and managed worktree behavior**

Use:

```bash
state_dir="$git_common_dir/qui-release-builder"
state_file="$state_dir/last-successful-release"
worktree_root=${QUI_RELEASE_WORKTREE_ROOT:-"$(dirname "$repo")/$(basename "$repo")-release-worktrees"}
patch_script=${QUI_PATCH_SCRIPT:-"$repo/scripts/apply-one-minute-limits.sh"}
```

Exit successfully when the state file already equals the latest tag. Otherwise create or reuse `$worktree_root/${latest_tag//\//_}`. Reuse is allowed only when it is a registered worktree whose HEAD equals `refs/tags/$latest_tag^{commit}`; an unrelated existing directory is an error.

- [ ] **Step 3: Patch, build, record success, and clean up**

Run in this exact order:

```bash
"$patch_script" "$release_worktree"
make -C "$release_worktree" build
make -C "$release_worktree" build/docker
```

Write the marker using `mktemp` plus `mv` only after both commands succeed. Parse `git worktree list --porcelain` and remove with `git worktree remove --force` only registered worktrees whose canonical paths are beneath the managed root and differ from the successful worktree. Finish with `git worktree prune`.

- [ ] **Step 4: Run the integration test until it passes**

```bash
chmod +x scripts/build-latest-release.sh scripts/tests/test-build-latest-release.sh
bash scripts/tests/test-build-latest-release.sh
```

Expected: PASS for first build, no-op repeat, failed-build retry, successful state advance, and old-worktree cleanup.

- [ ] **Step 5: Commit the release builder and test**

```bash
git add scripts/build-latest-release.sh scripts/tests/test-build-latest-release.sh
git commit -m "feat(scripts): build patched qui releases"
```

### Task 5: Verify Against a Disposable Real Source Worktree

**Files:**
- Verify: both scripts and both script tests
- Generated only in disposable worktree: patched qui backend/frontend files and build output

- [ ] **Step 1: Run syntax and script tests**

```bash
bash -n scripts/apply-one-minute-limits.sh
bash -n scripts/build-latest-release.sh
bash -n scripts/tests/test-apply-one-minute-limits.sh
bash -n scripts/tests/test-build-latest-release.sh
bash scripts/tests/test-apply-one-minute-limits.sh
bash scripts/tests/test-build-latest-release.sh
```

Expected: all commands exit zero.

- [ ] **Step 2: Create a disposable worktree and apply twice**

Use `superpowers:using-git-worktrees`, create a detached disposable worktree at the current implementation commit, then run:

```bash
scripts/apply-one-minute-limits.sh "$verification_worktree"
scripts/apply-one-minute-limits.sh "$verification_worktree"
```

Expected: first run reports patched files; second run reports already-patched files and leaves `git diff` unchanged.

- [ ] **Step 3: Run targeted Go tests**

Inside the patched verification worktree:

```bash
go test -race -count=1 ./internal/services/automations ./internal/services/crossseed
```

Expected: PASS.

- [ ] **Step 4: Run required repository checks**

Inside the patched verification worktree:

```bash
make precommit
make build
```

Expected: PASS. Do not run a real `make build/docker` during verification; the release-builder integration test verifies that target is invoked, while an actual Docker build is an operational side effect of running the finished release script.

- [ ] **Step 5: Review final diff and status**

```bash
git status --short
git diff --check
git log -3 --oneline
```

Expected: the primary implementation branch contains only the design/plan documents, two scripts, and their tests; the direct qui source modifications exist only in the disposable verification worktree.

### Task 6: Final Verification and Handoff

**Files:**
- Review: `scripts/apply-one-minute-limits.sh`
- Review: `scripts/build-latest-release.sh`
- Review: `scripts/tests/test-apply-one-minute-limits.sh`
- Review: `scripts/tests/test-build-latest-release.sh`

- [ ] **Step 1: Invoke `superpowers:verification-before-completion`**

Re-run fresh syntax checks, script tests, targeted tests, `make precommit`, and `make build`; do not rely on earlier output.

- [ ] **Step 2: Report exact outcomes**

State the created files, release/worktree behavior, checks run, the intentional omission of a real Docker build during development verification, and any failures or deferred checks. Include concise usage examples:

```bash
./scripts/apply-one-minute-limits.sh /path/to/qui
./scripts/build-latest-release.sh /path/to/qui
```

### Task 7: Patch Docker Frontend Build Inputs

**Files:**
- Modify: `scripts/tests/test-apply-one-minute-limits.sh`
- Modify: `scripts/apply-one-minute-limits.sh`

- [ ] **Step 1: Extend the fixture and write failing Dockerfile assertions**

Add both Docker build inputs to `copy_fixture`:

```bash
distrib/docker/Dockerfile \
web/pnpm-workspace.yaml
```

After the first patch invocation, require the exact corrected lines:

```bash
grep -Fxq 'FROM node:24-alpine AS frontend-builder' \
  "$fixture/distrib/docker/Dockerfile" || fail "Docker frontend builder does not use Node 24"
grep -Fxq 'COPY web/package.json web/pnpm-lock.yaml web/pnpm-workspace.yaml ./' \
  "$fixture/distrib/docker/Dockerfile" || fail "Docker dependency COPY omits pnpm workspace config"
```

Create an additional fixture whose frontend `FROM` line is changed to `node:23-alpine`. Require the patch to fail, preserve the complete fixture checksum, identify the frontend-builder matcher in stderr, and omit a Python traceback.

- [ ] **Step 2: Run the targeted test and verify RED**

Run:

```bash
bash scripts/tests/test-apply-one-minute-limits.sh
```

Expected: FAIL with `Docker frontend builder does not use Node 24`, proving the fixture still contains the affected release Dockerfile.

- [ ] **Step 3: Include Dockerfile in the atomic transformer**

Add `distrib/docker/Dockerfile` to `relative_paths`, but validate `web/pnpm-workspace.yaml` separately without adding it to the writable file map:

```python
relative_paths = (
    "distrib/docker/Dockerfile",
    "internal/services/automations/service.go",
    "internal/services/crossseed/service.go",
    "internal/models/crossseed.go",
    "web/src/pages/CrossSeedPage.tsx",
    "web/src/components/instances/preferences/WorkflowDialog.tsx",
)
required_paths = (*relative_paths, "web/pnpm-workspace.yaml")
missing = [relative for relative in required_paths if not (root / relative).is_file()]
```

Use `accept_old_or_new` with exact multiline anchors for both Dockerfile changes:

```python
dockerfile_path = "distrib/docker/Dockerfile"
accept_old_or_new(
    dockerfile_path,
    "Docker frontend builder Node version",
    r"^FROM node:22\.18-alpine AS frontend-builder$",
    r"^FROM node:24-alpine AS frontend-builder$",
    "FROM node:24-alpine AS frontend-builder",
    flags=re.MULTILINE,
)
accept_old_or_new(
    dockerfile_path,
    "Docker pnpm workspace metadata copy",
    r"^COPY web/package\.json web/pnpm-lock\.yaml \./$",
    r"^COPY web/package\.json web/pnpm-lock\.yaml web/pnpm-workspace\.yaml \./$",
    "COPY web/package.json web/pnpm-lock.yaml web/pnpm-workspace.yaml ./",
    flags=re.MULTILINE,
)
```

- [ ] **Step 4: Run the targeted test and verify GREEN**

Run:

```bash
bash -n scripts/apply-one-minute-limits.sh
bash -n scripts/tests/test-apply-one-minute-limits.sh
bash scripts/tests/test-apply-one-minute-limits.sh
```

Expected: all commands exit zero and the test prints `PASS: apply-one-minute-limits`.

- [ ] **Step 5: Commit the script and test**

```bash
git add scripts/apply-one-minute-limits.sh scripts/tests/test-apply-one-minute-limits.sh
git commit -m "fix(scripts): patch docker frontend build inputs"
```

- [ ] **Step 6: Run repository-required verification**

Run:

```bash
make precommit
bash scripts/tests/test-apply-one-minute-limits.sh
make build
```

Expected: all commands exit zero. A real Docker build is deferred because it downloads images and dependencies and is not required to verify the deterministic source transformation; report that deferral explicitly.
