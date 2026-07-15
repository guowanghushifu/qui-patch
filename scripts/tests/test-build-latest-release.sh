#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
builder_script="$repo_root/scripts/build-latest-release.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

line_count() {
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo 0
    return
  fi
  wc -l <"$file" | tr -d ' '
}

assert_file_value() {
  local file=$1
  local expected=$2
  [[ -f "$file" ]] || fail "missing file: $file"
  local actual
  actual=$(<"$file")
  [[ "$actual" == "$expected" ]] || fail "expected $file to contain $expected, got $actual"
}

[[ -f "$builder_script" ]] || fail "release builder does not exist: $builder_script"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

remote="$tmp_dir/origin.git"
seed="$tmp_dir/seed"
primary="$tmp_dir/primary"
worktree_root="$tmp_dir/worktrees"
stub_dir="$tmp_dir/bin"
make_log="$tmp_dir/make.log"
patch_log="$tmp_dir/patch.log"

git init -q --bare "$remote"
git init -q "$seed"
git -C "$seed" config user.name "Release Test"
git -C "$seed" config user.email "release-test@example.invalid"
printf 'v1\n' >"$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" commit -qm "initial"
git -C "$seed" branch -M develop
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -q -u origin develop
git -C "$seed" tag v1.0.0
git -C "$seed" push -q origin v1.0.0
git --git-dir="$remote" symbolic-ref HEAD refs/heads/develop
git clone -q "$remote" "$primary"
git -C "$primary" config user.name "Local Builder"
git -C "$primary" config user.email "local-builder@example.invalid"
printf 'local release scripts\n' >"$primary/local-release-tooling.txt"
git -C "$primary" add local-release-tooling.txt
git -C "$primary" commit -qm "add local release tooling"

mkdir -p "$stub_dir"

cat >"$stub_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'https://github.com/autobrr/qui/releases/tag/%s' "${FAKE_RELEASE_TAG:?}"
EOF

cat >"$stub_dir/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MAKE_LOG:?}"
if [[ ${FAIL_DOCKER_BUILD:-0} == 1 && $* == *"build/docker"* ]]; then
  exit 42
fi
EOF

patch_stub="$tmp_dir/patch-stub.sh"
cat >"$patch_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"${PATCH_LOG:?}"
EOF

chmod +x "$stub_dir/curl" "$stub_dir/make" "$patch_stub"

run_builder() {
  local tag=$1
  local fail_docker=${2:-0}
  PATH="$stub_dir:$PATH" \
    FAKE_RELEASE_TAG="$tag" \
    FAIL_DOCKER_BUILD="$fail_docker" \
    MAKE_LOG="$make_log" \
    PATCH_LOG="$patch_log" \
    QUI_PATCH_SCRIPT="$patch_stub" \
    QUI_RELEASE_WORKTREE_ROOT="$worktree_root" \
    bash "$builder_script" "$primary"
}

state_file="$primary/.git/qui-release-builder/last-successful-release"

run_builder v1.0.0
assert_file_value "$state_file" v1.0.0
[[ $(line_count "$patch_log") -eq 1 ]] || fail "first release should be patched once"
[[ $(line_count "$make_log") -eq 1 ]] || fail "first release should run one make target"
sed -n '1p' "$make_log" | grep -Eq -- '-C .+ VERSION=v1\.0\.0 build/docker$' || \
  fail "make build/docker did not receive the v1.0.0 release version"
[[ -d "$worktree_root/v1.0.0" ]] || fail "v1.0.0 worktree was not retained"

run_builder v1.0.0
[[ $(line_count "$patch_log") -eq 1 ]] || fail "unchanged release should not patch again"
[[ $(line_count "$make_log") -eq 1 ]] || fail "unchanged release should not build again"

printf 'v2\n' >"$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" commit -qm "release v1.1.0"
git -C "$seed" tag v1.1.0
git -C "$seed" push -q origin develop v1.1.0

if run_builder v1.1.0 1; then
  fail "failed Docker build unexpectedly succeeded"
fi
assert_file_value "$state_file" v1.0.0
[[ -d "$worktree_root/v1.0.0" ]] || fail "old successful worktree was removed after failure"
[[ -d "$worktree_root/v1.1.0" ]] || fail "failed release worktree was not retained"
[[ $(line_count "$patch_log") -eq 2 ]] || fail "failed release should be patched once"
[[ $(line_count "$make_log") -eq 2 ]] || fail "failed release should attempt the Docker build once"
sed -n '2p' "$make_log" | grep -Eq -- '-C .+ VERSION=v1\.1\.0 build/docker$' || \
  fail "failed Docker build did not receive the v1.1.0 release version"

run_builder v1.1.0
assert_file_value "$state_file" v1.1.0
[[ -f "$primary/local-release-tooling.txt" ]] || fail "local release tooling commit was lost"
git -C "$primary" merge-base --is-ancestor origin/develop HEAD || \
  fail "primary branch was not updated on top of origin/develop"
git -C "$primary" log --format=%s -1 | grep -Fqx 'add local release tooling' || \
  fail "local release tooling commit was not rebased on top of upstream"
[[ $(line_count "$patch_log") -eq 3 ]] || fail "retry should patch the retained worktree"
[[ $(line_count "$make_log") -eq 3 ]] || fail "retry should run the Docker build once"
sed -n '3p' "$make_log" | grep -Eq -- '-C .+ VERSION=v1\.1\.0 build/docker$' || \
  fail "retried Docker build did not receive the v1.1.0 release version"
[[ ! -e "$worktree_root/v1.0.0" ]] || fail "old successful worktree was not cleaned up"
[[ -d "$worktree_root/v1.1.0" ]] || fail "latest successful worktree was not retained"

echo "PASS: build-latest-release"
