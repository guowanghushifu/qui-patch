#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
patch_script="$repo_root/scripts/apply-one-minute-limits.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local pattern=$2
  grep -Eq "$pattern" "$file" || fail "expected pattern in $file: $pattern"
}

assert_not_contains() {
  local file=$1
  local pattern=$2
  if grep -Eq "$pattern" "$file"; then
    fail "unexpected pattern in $file: $pattern"
  fi
}

copy_fixture() {
  local target=$1
  local relative

  for relative in \
    distrib/docker/Dockerfile \
    internal/services/automations/service.go \
    internal/services/crossseed/service.go \
    web/pnpm-workspace.yaml \
    web/src/pages/CrossSeedPage.tsx \
    web/src/components/instances/preferences/WorkflowDialog.tsx; do
    mkdir -p "$target/$(dirname "$relative")"
    cp "$repo_root/$relative" "$target/$relative"
  done
}

fixture_checksum() {
  local target=$1
  find "$target" -type f -print0 | sort -z | xargs -0 sha256sum
}

[[ -f "$patch_script" ]] || fail "patch script does not exist: $patch_script"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fixture="$tmp_dir/fixture"
copy_fixture "$fixture"

bash "$patch_script" "$fixture"

grep -Fxq 'FROM node:24-alpine AS frontend-builder' \
  "$fixture/distrib/docker/Dockerfile" || fail "Docker frontend builder does not use Node 24"
grep -Fxq 'COPY web/package.json web/pnpm-lock.yaml web/pnpm-workspace.yaml ./' \
  "$fixture/distrib/docker/Dockerfile" || fail "Docker dependency COPY omits pnpm workspace config"
grep -Fq '// RSS Automation: minimum 30 minutes between RSS feed polls, default 120 minutes' \
  "$fixture/internal/services/crossseed/service.go" || fail "RSS settings comment was modified"
grep -Fq '// RSS Automation: enforce minimum 30 minutes between runs' \
  "$fixture/internal/services/crossseed/service.go" || fail "RSS scheduler comment was modified"
grep -Fq '// RSS Automation: interval between RSS feed polls (min: 30 minutes)' \
  "$fixture/web/src/pages/CrossSeedPage.tsx" || fail "RSS frontend comment was modified"
assert_contains \
  "$fixture/internal/services/automations/service.go" \
  'const freeSpaceDeleteCooldown = 1 \* time\.Minute'
assert_contains \
  "$fixture/internal/services/crossseed/service.go" \
  'settings\.RunIntervalMinutes < 1'
assert_contains \
  "$fixture/internal/services/crossseed/service.go" \
  'settings\.RunIntervalMinutes = 1'

clamp_count=$(grep -Eoc 'max\(time\.Duration\(intervalMinutes\)\*time\.Minute, time\.Minute\)' \
  "$fixture/internal/services/crossseed/service.go")
[[ "$clamp_count" -eq 2 ]] || fail "expected two one-minute RSS clamps, got $clamp_count"

assert_contains \
  "$fixture/web/src/pages/CrossSeedPage.tsx" \
  'const MIN_RSS_INTERVAL_MINUTES = 1([^0-9]|$)'
assert_not_contains \
  "$fixture/web/src/components/instances/preferences/WorkflowDialog.tsx" \
  'Auto-switch interval from 1 minute'
grep -Fq \
  '{ value: "60", label: t("preferences.workflowDialog.interval.oneMinute"), disabled: false },' \
  "$fixture/web/src/components/instances/preferences/WorkflowDialog.tsx" || \
  fail "one-minute workflow interval is not enabled"
assert_not_contains \
  "$fixture/web/src/components/instances/preferences/WorkflowDialog.tsx" \
  'cooldownAria|cooldownDescription|cooldownWarning'

first_checksum=$(fixture_checksum "$fixture")
bash "$patch_script" "$fixture"
second_checksum=$(fixture_checksum "$fixture")
[[ "$first_checksum" == "$second_checksum" ]] || fail "second patch run changed files"

missing_workspace_fixture="$tmp_dir/missing-workspace"
copy_fixture "$missing_workspace_fixture"
rm "$missing_workspace_fixture/web/pnpm-workspace.yaml"
before_missing_workspace=$(fixture_checksum "$missing_workspace_fixture")
if bash "$patch_script" "$missing_workspace_fixture" \
  >"$tmp_dir/missing-workspace.out" 2>"$tmp_dir/missing-workspace.err"; then
  fail "patch unexpectedly succeeded without web/pnpm-workspace.yaml"
fi
after_missing_workspace=$(fixture_checksum "$missing_workspace_fixture")
[[ "$before_missing_workspace" == "$after_missing_workspace" ]] || \
  fail "missing workspace failure partially changed files"
grep -Fq 'web/pnpm-workspace.yaml' "$tmp_dir/missing-workspace.err" || \
  fail "failure did not identify the missing pnpm workspace config"
if grep -Fq 'Traceback' "$tmp_dir/missing-workspace.err"; then
  fail "missing workspace failure leaked a Python traceback"
fi

broken_fixture="$tmp_dir/broken"
copy_fixture "$broken_fixture"
python3 - "$broken_fixture/internal/services/automations/service.go" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("const freeSpaceDeleteCooldown = 5 * time.Minute\n", "")
path.write_text(text)
PY

before_failure=$(fixture_checksum "$broken_fixture")
if bash "$patch_script" "$broken_fixture" >"$tmp_dir/broken.out" 2>"$tmp_dir/broken.err"; then
  fail "patch unexpectedly succeeded with a missing semantic anchor"
fi
after_failure=$(fixture_checksum "$broken_fixture")
[[ "$before_failure" == "$after_failure" ]] || fail "failed patch partially changed files"
grep -Fq 'freeSpaceDeleteCooldown' "$tmp_dir/broken.err" || \
  fail "failure did not identify the missing freeSpaceDeleteCooldown anchor"
if grep -Fq 'Traceback' "$tmp_dir/broken.err"; then
  fail "failure leaked a Python traceback"
fi

broken_docker_fixture="$tmp_dir/broken-docker"
copy_fixture "$broken_docker_fixture"
python3 - "$broken_docker_fixture/distrib/docker/Dockerfile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "FROM node:22.18-alpine AS frontend-builder",
    "FROM node:23-alpine AS frontend-builder",
)
path.write_text(text)
PY

before_docker_failure=$(fixture_checksum "$broken_docker_fixture")
if bash "$patch_script" "$broken_docker_fixture" \
  >"$tmp_dir/broken-docker.out" 2>"$tmp_dir/broken-docker.err"; then
  fail "patch unexpectedly succeeded with an unknown Docker frontend builder"
fi
after_docker_failure=$(fixture_checksum "$broken_docker_fixture")
[[ "$before_docker_failure" == "$after_docker_failure" ]] || \
  fail "failed Docker patch partially changed files"
grep -Fq 'Docker frontend builder Node version' "$tmp_dir/broken-docker.err" || \
  fail "failure did not identify the Docker frontend builder matcher"
if grep -Fq 'Traceback' "$tmp_dir/broken-docker.err"; then
  fail "Docker failure leaked a Python traceback"
fi

echo "PASS: apply-one-minute-limits"
