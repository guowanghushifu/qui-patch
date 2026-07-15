#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

notify_patch_failure() {
  local release_tag=$1
  local patch_path=$2
  local worktree_path=$3

  if [[ -z ${QUI_TELEGRAM_BOT_TOKEN:-} || -z ${QUI_TELEGRAM_CHAT_ID:-} ]]; then
    echo "warning: patch failed but Telegram notification is not configured" >&2
    return 1
  fi

  local host_name
  host_name=$(hostname 2>/dev/null || printf 'unknown')

  local message
  printf -v message \
    'qui release patch failed\nRelease: %s\nHost: %s\nPatch script: %s\nWorktree: %s' \
    "$release_tag" "$host_name" "$patch_path" "$worktree_path"

  if ! curl -fsS \
    --connect-timeout 10 \
    --max-time 30 \
    --request POST \
    --data-urlencode "chat_id=${QUI_TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$message" \
    "https://api.telegram.org/bot${QUI_TELEGRAM_BOT_TOKEN}/sendMessage" \
    >/dev/null; then
    echo "warning: failed to send Telegram patch failure notification" >&2
    return 1
  fi
}

for command_name in git curl make; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_candidate=${1:-"$script_dir/.."}
repo=$(git -C "$repo_candidate" rev-parse --show-toplevel 2>/dev/null) || \
  fail "not a Git repository: $repo_candidate"
repo=$(cd "$repo" && pwd -P)

branch=$(git -C "$repo" branch --show-current)
[[ -n "$branch" ]] || fail "the primary repository must have a checked-out branch"

echo "Updating $repo on branch $branch..."
git -C "$repo" pull --rebase origin "$branch"
git -C "$repo" fetch --prune --tags origin

latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  https://github.com/autobrr/qui/releases/latest)
latest_tag=${latest_url%/}
latest_tag=${latest_tag##*/}
[[ -n "$latest_tag" ]] || fail "GitHub latest-release URL did not contain a tag"
git check-ref-format "refs/tags/$latest_tag" >/dev/null 2>&1 || \
  fail "GitHub returned an invalid tag name: $latest_tag"

latest_commit=$(git -C "$repo" rev-parse --verify --quiet "refs/tags/$latest_tag^{commit}") || \
  fail "release tag is not available after fetch: $latest_tag"

git_common_dir=$(git -C "$repo" rev-parse --git-common-dir)
if [[ "$git_common_dir" != /* ]]; then
  git_common_dir="$repo/$git_common_dir"
fi
git_common_dir=$(cd "$git_common_dir" && pwd -P)

state_dir="$git_common_dir/qui-release-builder"
state_file="$state_dir/last-successful-release"
mkdir -p "$state_dir"

last_successful_release=""
if [[ -f "$state_file" ]]; then
  last_successful_release=$(<"$state_file")
fi

if [[ "$last_successful_release" == "$latest_tag" ]]; then
  echo "No new release: $latest_tag was already built successfully."
  exit 0
fi

worktree_root=${QUI_RELEASE_WORKTREE_ROOT:-"$(dirname "$repo")/$(basename "$repo")-release-worktrees"}
mkdir -p "$worktree_root"
worktree_root=$(cd "$worktree_root" && pwd -P)

worktree_name=${latest_tag//\//_}
[[ -n "$worktree_name" && "$worktree_name" != "." && "$worktree_name" != ".." ]] || \
  fail "release tag cannot be converted to a safe worktree name: $latest_tag"
release_worktree="$worktree_root/$worktree_name"

is_registered_worktree() {
  local expected_path=$1
  local key value
  while IFS=' ' read -r key value; do
    if [[ "$key" == "worktree" && "$value" == "$expected_path" ]]; then
      return 0
    fi
  done < <(git -C "$repo" worktree list --porcelain)
  return 1
}

if [[ -e "$release_worktree" ]]; then
  is_registered_worktree "$release_worktree" || \
    fail "worktree path exists but is not managed by this repository: $release_worktree"
  worktree_commit=$(git -C "$release_worktree" rev-parse HEAD)
  [[ "$worktree_commit" == "$latest_commit" ]] || \
    fail "existing release worktree is at $worktree_commit, expected $latest_commit"
  echo "Reusing release worktree: $release_worktree"
else
  echo "Creating release worktree for $latest_tag..."
  git -C "$repo" worktree add --detach "$release_worktree" "$latest_tag"
fi

patch_script=${QUI_PATCH_SCRIPT:-"$repo/scripts/apply-one-minute-limits.sh"}
[[ -x "$patch_script" ]] || fail "patch script is not executable: $patch_script"

echo "Applying one-minute limits to $latest_tag..."
if "$patch_script" "$release_worktree"; then
  :
else
  patch_status=$?
  if ! notify_patch_failure "$latest_tag" "$patch_script" "$release_worktree"; then
    :
  fi
  exit "$patch_status"
fi

echo "Building qui release $latest_tag..."
make -C "$release_worktree" VERSION="$latest_tag" build/docker

state_tmp=$(mktemp "$state_dir/.last-successful-release.XXXXXX")
trap 'rm -f "${state_tmp:-}"' EXIT
printf '%s\n' "$latest_tag" >"$state_tmp"
mv "$state_tmp" "$state_file"
state_tmp=""

while IFS=' ' read -r key managed_worktree; do
  [[ "$key" == "worktree" ]] || continue
  [[ "$managed_worktree" == "$worktree_root/"* ]] || continue
  [[ "$managed_worktree" != "$release_worktree" ]] || continue
  echo "Removing old release worktree: $managed_worktree"
  git -C "$repo" worktree remove --force "$managed_worktree"
done < <(git -C "$repo" worktree list --porcelain)
git -C "$repo" worktree prune

echo "Successfully built qui $latest_tag in $release_worktree"
