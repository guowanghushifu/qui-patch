#!/usr/bin/env bash

set -euo pipefail

target_dir=${1:-.}

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required" >&2
  exit 1
}

if ! target_dir=$(cd "$target_dir" && pwd -P); then
  echo "error: source directory does not exist: $target_dir" >&2
  exit 1
fi

python3 - "$target_dir" <<'PY'
from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import sys


class PatchError(RuntimeError):
    pass


def report_patch_error(exception_type, exception, traceback):
    if issubclass(exception_type, PatchError):
        print(f"error: {exception}", file=sys.stderr)
        return
    sys.__excepthook__(exception_type, exception, traceback)


sys.excepthook = report_patch_error


root = Path(sys.argv[1])
relative_paths = (
    "distrib/docker/Dockerfile",
    "internal/services/automations/service.go",
    "internal/services/crossseed/service.go",
    "web/src/pages/CrossSeedPage.tsx",
    "web/src/components/instances/preferences/WorkflowDialog.tsx",
)

required_paths = (*relative_paths, "web/pnpm-workspace.yaml")
missing = [relative for relative in required_paths if not (root / relative).is_file()]
if missing:
    raise SystemExit("error: target does not look like a qui source tree; missing: " + ", ".join(missing))


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return handle.read()


original = {relative: read_text(root / relative) for relative in relative_paths}
updated = dict(original)


def replace_required(
    relative: str,
    description: str,
    pattern: str,
    replacement: str,
    expected: int = 1,
    flags: int = 0,
) -> None:
    text = updated[relative]
    result, count = re.subn(pattern, replacement, text, flags=flags)
    if count != expected:
        raise PatchError(f"{description}: expected {expected} match(es), found {count} in {relative}")
    updated[relative] = result


def accept_old_or_new(
    relative: str,
    description: str,
    old_pattern: str,
    new_pattern: str,
    replacement: str,
    expected: int = 1,
    flags: int = 0,
) -> None:
    text = updated[relative]
    old_count = len(re.findall(old_pattern, text, flags))
    new_count = len(re.findall(new_pattern, text, flags))
    if old_count == expected and new_count == 0:
        updated[relative] = re.sub(old_pattern, replacement, text, count=expected, flags=flags)
        return
    if old_count == 0 and new_count == expected:
        return
    raise PatchError(
        f"{description}: expected {expected} old or patched match(es), "
        f"found old={old_count}, patched={new_count} in {relative}"
    )


def remove_optional_feature(
    relative: str,
    description: str,
    pattern: str,
    absent_markers: tuple[str, ...],
    flags: int = 0,
) -> None:
    text = updated[relative]
    count = len(re.findall(pattern, text, flags))
    if count == 1:
        updated[relative] = re.sub(pattern, "", text, count=1, flags=flags)
        return
    if count > 1:
        raise PatchError(f"{description}: expected at most one match, found {count} in {relative}")
    present_markers = [marker for marker in absent_markers if marker in text]
    if present_markers:
        raise PatchError(
            f"{description}: feature structure changed but markers remain in {relative}: "
            + ", ".join(present_markers)
        )


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

automations_path = "internal/services/automations/service.go"
replace_required(
    automations_path,
    "freeSpaceDeleteCooldown",
    r"const freeSpaceDeleteCooldown = \d+ \* time\.Minute",
    "const freeSpaceDeleteCooldown = 1 * time.Minute",
)

workflow_path = "web/src/components/instances/preferences/WorkflowDialog.tsx"
remove_optional_feature(
    workflow_path,
    "FREE_SPACE one-minute auto-switch effect",
    r"\n  // Auto-switch interval from 1 minute when FREE_SPACE delete condition is added\n"
    r".*?"
    r"\n  \}, \[formState\.actionCondition, formState\.deleteEnabled, "
    r"formState\.intervalSeconds, t\]\)\n",
    (
        "Auto-switch interval from 1 minute",
        "switchedIntervalForFreeSpace",
    ),
    re.DOTALL,
)
replace_required(
    workflow_path,
    "one-minute workflow interval option",
    r'    \{ value: "60", label: t\("preferences\.workflowDialog\.interval\.oneMinute"\)'
    r"(?:, disabled: (?:deleteUsesFreeSpace|false))? \},",
    '    { value: "60", label: t("preferences.workflowDialog.interval.oneMinute"), disabled: false },',
)
accept_old_or_new(
    workflow_path,
    "workflow interval option dependencies",
    r"(const intervalOptions = useMemo\(\(\) => \(\[.*?\n  \]\), )"
    r"\[deleteUsesFreeSpace, t\](\))",
    r"(const intervalOptions = useMemo\(\(\) => \(\[.*?\n  \]\), )\[t\](\))",
    r"\g<1>[t]\g<2>",
    flags=re.DOTALL,
)
remove_optional_feature(
    workflow_path,
    "obsolete FREE_SPACE cooldown tooltip",
    r"\n                  \{deleteUsesFreeSpace && \(\n"
    r"                    <TooltipProvider delayDuration=\{150\}>.*?"
    r"preferences\.workflowDialog\.interval\.cooldownDescription.*?"
    r"\n                  \)\}",
    (
        "preferences.workflowDialog.interval.cooldownAria",
        "preferences.workflowDialog.interval.cooldownDescription",
    ),
    re.DOTALL,
)
remove_optional_feature(
    workflow_path,
    "obsolete FREE_SPACE cooldown warning",
    r"\n                  \{deleteUsesFreeSpace && formState\.intervalSeconds === 60 && \(\n"
    r".*?preferences\.workflowDialog\.interval\.cooldownWarning.*?"
    r"\n                  \)\}",
    ("preferences.workflowDialog.interval.cooldownWarning",),
    re.DOTALL,
)

crossseed_path = "internal/services/crossseed/service.go"
replace_required(
    crossseed_path,
    "RSS settings minimum normalization",
    r"(\} else if settings\.RunIntervalMinutes < )\d+( \{\n"
    r"\s+settings\.RunIntervalMinutes = )\d+(\n\s+\})",
    r"\g<1>1\g<2>1\g<3>",
)
accept_old_or_new(
    crossseed_path,
    "RSS runtime interval clamps",
    r"max\(time\.Duration\(intervalMinutes\)\*time\.Minute, \d+\*time\.Minute\)",
    r"max\(time\.Duration\(intervalMinutes\)\*time\.Minute, time\.Minute\)",
    "max(time.Duration(intervalMinutes)*time.Minute, time.Minute)",
    expected=2,
)

page_path = "web/src/pages/CrossSeedPage.tsx"
replace_required(
    page_path,
    "RSS frontend minimum",
    r"const MIN_RSS_INTERVAL_MINUTES = \d+",
    "const MIN_RSS_INTERVAL_MINUTES = 1",
)


def write_atomic(path: Path, content: str) -> None:
    source_mode = stat.S_IMODE(path.stat().st_mode)
    temporary = path.with_name(f".{path.name}.qui-one-minute-{os.getpid()}")
    try:
        with temporary.open("w", encoding="utf-8", newline="") as handle:
            handle.write(content)
        os.chmod(temporary, source_mode)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


try:
    for relative in relative_paths:
        if updated[relative] != original[relative]:
            write_atomic(root / relative, updated[relative])
            print(f"patched: {relative}")
        else:
            print(f"already patched: {relative}")
except OSError as error:
    raise SystemExit(f"error: failed to write patched source: {error}") from error
PY
