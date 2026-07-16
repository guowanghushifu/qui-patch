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

assert_count() {
  local file=$1
  local pattern=$2
  local expected=$3
  local actual

  actual=$(grep -Eoc "$pattern" "$file" || true)
  [[ "$actual" -eq "$expected" ]] || \
    fail "expected $expected match(es) in $file, got $actual: $pattern"
}

copy_fixture() {
  local target=$1
  local relative

  for relative in \
    distrib/docker/Dockerfile \
    internal/services/automations/service.go \
    internal/services/crossseed/service.go \
    web/pnpm-workspace.yaml \
    web/src/components/torrents/TorrentCardsMobile.tsx \
    web/src/components/torrents/TorrentTableColumns.tsx \
    web/src/components/torrents/table/CompactRow.tsx \
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

assert_not_contains \
  "$fixture/web/src/components/torrents/TorrentTableColumns.tsx" \
  'getLinuxRatio'
assert_contains \
  "$fixture/web/src/components/torrents/TorrentTableColumns.tsx" \
  'const ratio = row\.original\.ratio'
assert_contains \
  "$fixture/web/src/components/torrents/TorrentTableColumns.tsx" \
  'const ratioA = rowA\.original\.ratio'
assert_contains \
  "$fixture/web/src/components/torrents/TorrentTableColumns.tsx" \
  'const ratioB = rowB\.original\.ratio'
assert_count \
  "$fixture/web/src/components/torrents/TorrentTableColumns.tsx" \
  'const speed = row\.original\.dlspeed' \
  1
assert_count \
  "$fixture/web/src/components/torrents/TorrentTableColumns.tsx" \
  'const speed = row\.original\.upspeed' \
  1

assert_not_contains \
  "$fixture/web/src/components/torrents/table/CompactRow.tsx" \
  'getLinuxRatio'
assert_contains \
  "$fixture/web/src/components/torrents/table/CompactRow.tsx" \
  'const displayRatio = torrent\.ratio'
assert_count \
  "$fixture/web/src/components/torrents/table/CompactRow.tsx" \
  'formatSpeedWithUnit\(torrent\.dlspeed, speedUnit\)' \
  1
assert_count \
  "$fixture/web/src/components/torrents/table/CompactRow.tsx" \
  'formatSpeedWithUnit\(torrent\.upspeed, speedUnit\)' \
  1

assert_not_contains \
  "$fixture/web/src/components/torrents/TorrentCardsMobile.tsx" \
  'getLinuxRatio'
assert_contains \
  "$fixture/web/src/components/torrents/TorrentCardsMobile.tsx" \
  'const displayRatio = torrent\.ratio'
assert_count \
  "$fixture/web/src/components/torrents/TorrentCardsMobile.tsx" \
  'formatSpeedWithUnit\(torrent\.dlspeed, speedUnit\)' \
  3
assert_count \
  "$fixture/web/src/components/torrents/TorrentCardsMobile.tsx" \
  'formatSpeedWithUnit\(torrent\.upspeed, speedUnit\)' \
  3

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

broken_ratio_fixture="$tmp_dir/broken-ratio"
copy_fixture "$broken_ratio_fixture"
python3 - "$broken_ratio_fixture/web/src/components/torrents/table/CompactRow.tsx" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "const displayRatio = incognitoMode ? getLinuxRatio(torrent.hash) : torrent.ratio"
patched = "const displayRatio = torrent.ratio"
if old in text:
    text = text.replace(old, "const displayRatio = getDisplayedRatio(torrent)", 1)
elif patched in text:
    text = text.replace(patched, "const displayRatio = getDisplayedRatio(torrent)", 1)
else:
    raise SystemExit("compact Ratio fixture anchor is missing")
path.write_text(text)
PY

before_ratio_failure=$(fixture_checksum "$broken_ratio_fixture")
if bash "$patch_script" "$broken_ratio_fixture" \
  >"$tmp_dir/broken-ratio.out" 2>"$tmp_dir/broken-ratio.err"; then
  fail "patch unexpectedly succeeded with a missing Ratio semantic anchor"
fi
after_ratio_failure=$(fixture_checksum "$broken_ratio_fixture")
[[ "$before_ratio_failure" == "$after_ratio_failure" ]] || \
  fail "failed Ratio patch partially changed files"
grep -Fq 'compact torrent Ratio display' "$tmp_dir/broken-ratio.err" || \
  fail "failure did not identify the compact torrent Ratio matcher"
if grep -Fq 'Traceback' "$tmp_dir/broken-ratio.err"; then
  fail "Ratio failure leaked a Python traceback"
fi

extra_ratio_fixture="$tmp_dir/extra-ratio-reference"
copy_fixture "$extra_ratio_fixture"
python3 - "$extra_ratio_fixture/web/src/components/torrents/table/CompactRow.tsx" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
anchor = "const displayRatio = incognitoMode ? getLinuxRatio(torrent.hash) : torrent.ratio"
if anchor not in text:
    raise SystemExit("compact Ratio fixture anchor is missing")
text = text.replace(anchor, f"{anchor}\n  const secondaryRatio = getLinuxRatio(torrent.hash)", 1)
path.write_text(text)
PY

before_extra_ratio_failure=$(fixture_checksum "$extra_ratio_fixture")
if bash "$patch_script" "$extra_ratio_fixture" \
  >"$tmp_dir/extra-ratio-reference.out" 2>"$tmp_dir/extra-ratio-reference.err"; then
  fail "patch unexpectedly succeeded with an additional getLinuxRatio consumer"
fi
after_extra_ratio_failure=$(fixture_checksum "$extra_ratio_fixture")
[[ "$before_extra_ratio_failure" == "$after_extra_ratio_failure" ]] || \
  fail "additional Ratio consumer failure partially changed files"
grep -Fq 'unexpected getLinuxRatio reference' "$tmp_dir/extra-ratio-reference.err" || \
  fail "failure did not identify the unexpected getLinuxRatio reference"
if grep -Fq 'Traceback' "$tmp_dir/extra-ratio-reference.err"; then
  fail "additional Ratio consumer failure leaked a Python traceback"
fi

echo "PASS: apply-one-minute-limits"
