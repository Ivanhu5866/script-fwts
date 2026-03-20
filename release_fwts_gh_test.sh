#!/bin/bash
# Copyright (C) 2026 Canonical
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-https://github.com/Ivanhu5866/fwts}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/fwts/fwts}"
WORKFLOW_NAME="release.yml"
PPA_TARGET="${PPA_TARGET:-ppa:firmware-testing-team/scratch}"

prompt_continue() {
read -r -p "Please [ENTER] to continue or Ctrl+C to abort"
}

wait_done() {
local line=""

echo 'type "done" to continue...'
while true; do
read -r line
if [ "$line" = "done" ]; then
break
fi
done
}

die() {
echo "Error: $*" >&2
exit 1
}

require_cmd() {
command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

repo_slug() {
local repo_url="$1"

printf '%s\n' "${repo_url#https://github.com/}" | sed 's#/$##'
}

default_branch() {
local repo_slug="$1"

gh repo view "$repo_slug" --json defaultBranchRef --jq .defaultBranchRef.name
}

global_git_config() {
local key="$1"

git config --global --get "$key"
}

default_email_user() {
local git_email="$1"

printf '%s\n' "${git_email%@*}"
}

prompt_git_name() {
local default_value="$1"
local value=""

if [ -n "${GIT_NAME:-}" ]; then
printf '%s\n' "${GIT_NAME}"
return 0
fi

if [ -n "${default_value}" ]; then
read -r -p "Git author name [${default_value}]: " value
printf '%s\n' "${value:-${default_value}}"
else
read -r -p "Git author name: " value
printf '%s\n' "${value}"
fi
}

prompt_email_user() {
local default_value="$1"
local value=""

if [ -n "${EMAIL_USER:-}" ]; then
printf '%s\n' "${EMAIL_USER}"
return 0
fi

if [ -n "${default_value}" ]; then
read -r -p "Email user for canonical.com/ubuntu.com [${default_value}]: " value
printf '%s\n' "${value:-${default_value}}"
else
read -r -p "Email user for canonical.com/ubuntu.com: " value
printf '%s\n' "${value}"
fi
}

latest_series() {
printf '%s\n' "${RELEASES}" | awk '{print $NF}'
}

workflow_releases() {
local repo="$1"
local ref="$2"

gh api \
-H "Accept: application/vnd.github.raw+json" \
"repos/${repo}/contents/.github/workflows/${WORKFLOW_NAME}?ref=${ref}" \
| sed -n 's/^      RELEASES: "\(.*\)"/\1/p' | head -1
}

normalize_version() {
printf '%s\n' "${1#V}"
}

find_workflow_run_id() {
local repo="$1"
local branch="$2"
local head_sha="$3"
local dispatch_after="$4"
local attempt run_id

for attempt in $(seq 1 24); do
run_id=$(gh run list \
--repo "$repo" \
--workflow "$WORKFLOW_NAME" \
--branch "$branch" \
--event workflow_dispatch \
--json databaseId,headSha,createdAt \
--jq "map(select(.headSha == \"$head_sha\" and .createdAt >= \"$dispatch_after\")) | sort_by(.createdAt) | last | .databaseId // empty")
if [ -n "$run_id" ]; then
printf '%s\n' "$run_id"
return 0
fi
sleep 5
done

return 1
}

sign_changes() {
local changes_file="$1"

if [ -n "${DEBSIGN_KEYID:-}" ]; then
debsign "-k${DEBSIGN_KEYID}" "$changes_file"
else
debsign "$changes_file"
fi
}

prepare_branch_exact() {
local clone_dir="$1"
local source_branch="$2"
local upstream_branch="$3"

pushd "$clone_dir" >/dev/null
git checkout -B "$source_branch" "upstream/$upstream_branch"
popd >/dev/null
}

push_branch_exact() {
local clone_dir="$1"
local source_branch="$2"
local upstream_branch="$3"

pushd "$clone_dir" >/dev/null
if [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$source_branch")" ]; then
echo "Fork branch already matches upstream."
popd >/dev/null
return 0
fi

if git merge-base --is-ancestor "origin/$source_branch" HEAD; then
echo "Pushing fast-forward branch sync to ${SOURCE_REPO}"
git push origin "HEAD:${source_branch}"
else
echo "Resetting ${SOURCE_REPO}:${source_branch} to match ${UPSTREAM_REPO}:${upstream_branch}"
prompt_continue
git push --force-with-lease origin "HEAD:${source_branch}"
fi
popd >/dev/null
}

mirror_tags_exact() {
local clone_dir="$1"

pushd "$clone_dir" >/dev/null
echo "Force-updating local tags from ${UPSTREAM_REPO}"
git fetch upstream '+refs/tags/*:refs/tags/*'

echo "Removing local tags that do not exist on ${UPSTREAM_REPO}"
comm -23 \
<(git tag | sort) \
<(git ls-remote --tags --refs upstream | awk '{sub("refs/tags/", "", $2); print $2}' | sort) \
| xargs -r -n1 git tag -d >/dev/null

echo "Mirroring tags to ${SOURCE_REPO}"
git push --force --prune origin 'refs/tags/*:refs/tags/*'
popd >/dev/null
}

download_artifact_tree() {
local download_dir="$1"
local artifact_name="$2"
local tag="$3"
local work_dir="$4"

[ ! -e "$work_dir" ] || die "${work_dir} already exists"

if [ -d "${download_dir}/package-build/${tag}" ]; then
mv "${download_dir}/package-build/${tag}" "$work_dir"
elif [ -d "${download_dir}/${tag}" ]; then
mv "${download_dir}/${tag}" "$work_dir"
elif [ -f "${download_dir}/package-build/${artifact_name}.tar.gz" ]; then
tar -C "${PWD}" -xzf "${download_dir}/package-build/${artifact_name}.tar.gz"
elif [ -f "${download_dir}/${artifact_name}.tar.gz" ]; then
tar -C "${PWD}" -xzf "${download_dir}/${artifact_name}.tar.gz"
else
die "Downloaded artifact does not contain ${tag}"
fi

[ -d "$work_dir" ] || die "Could not prepare ${work_dir}"
}

if [ $# -eq 0 ]; then
echo "Please provide release version, ex. 26.01.00."
exit 1
fi

require_cmd gh
require_cmd git
require_cmd debsign
require_cmd dput
require_cmd tar

gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

RELEASE_VERSION=$(normalize_version "$1")
TAG="V${RELEASE_VERSION}"
SOURCE_SLUG=$(repo_slug "$SOURCE_REPO")
UPSTREAM_SLUG=$(repo_slug "$UPSTREAM_REPO")
SOURCE_BRANCH=$(default_branch "$SOURCE_SLUG")
UPSTREAM_BRANCH=$(default_branch "$UPSTREAM_SLUG")
DEFAULT_GIT_NAME=$(global_git_config user.name || true)
DEFAULT_GIT_EMAIL=$(global_git_config user.email || true)
GIT_NAME=$(prompt_git_name "${DEFAULT_GIT_NAME}")
[ -n "${GIT_NAME}" ] || die "Git author name is required"
EMAIL_USER=$(prompt_email_user "$(default_email_user "${DEFAULT_GIT_EMAIL}")")
[ -n "${EMAIL_USER}" ] || die "Email user is required"
ARTIFACT_NAME="fwts-source-packages-${TAG}"
WORK_DIR="${PWD}/${TAG}"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fwts-release-gh-test.${RELEASE_VERSION}.XXXXXX")
CLONE_DIR="${TEMP_DIR}/source"
DOWNLOAD_DIR="${TEMP_DIR}/download"
mkdir -p "${DOWNLOAD_DIR}"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "The test flow will:"
echo "  1. clone ${SOURCE_REPO}"
echo "  2. reset ${SOURCE_REPO}:${SOURCE_BRANCH} to ${UPSTREAM_REPO}:${UPSTREAM_BRANCH}"
echo "  3. mirror tags so ${SOURCE_REPO} matches ${UPSTREAM_REPO}"
echo "  4. dispatch ${WORKFLOW_NAME} on ${SOURCE_REPO}"
echo "  5. download, sign and upload the source packages"
prompt_continue

git clone "$SOURCE_REPO" "$CLONE_DIR"
pushd "$CLONE_DIR" >/dev/null
git remote add upstream "$UPSTREAM_REPO"
git fetch origin "$SOURCE_BRANCH" --tags
git fetch upstream "$UPSTREAM_BRANCH" '+refs/tags/*:refs/tags/*'
popd >/dev/null

prepare_branch_exact "$CLONE_DIR" "$SOURCE_BRANCH" "$UPSTREAM_BRANCH"
push_branch_exact "$CLONE_DIR" "$SOURCE_BRANCH" "$UPSTREAM_BRANCH"
mirror_tags_exact "$CLONE_DIR"

RELEASES=$(workflow_releases "${SOURCE_SLUG}" "${SOURCE_BRANCH}")
[ -n "${RELEASES}" ] || die "Could not read RELEASES from ${SOURCE_REPO} ${WORKFLOW_NAME} on ${SOURCE_BRANCH}"
LATEST_SERIES=$(latest_series)

echo ""
echo "Please confirm GitHub Actions permissions, GPG signing setup and PPA upload rights."
prompt_continue

HEAD_SHA=$(gh api "repos/${SOURCE_SLUG}/commits/${SOURCE_BRANCH}" --jq .sha)
DISPATCH_AFTER=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo ""
echo "Dispatching ${WORKFLOW_NAME} on ${SOURCE_SLUG} for ${TAG}"
gh workflow run "$WORKFLOW_NAME" \
--repo "$SOURCE_SLUG" \
--ref "$SOURCE_BRANCH" \
-f version="${RELEASE_VERSION}" \
-f git_name="${GIT_NAME}" \
-f email_user="${EMAIL_USER}"

echo "Waiting for the workflow run to appear"
RUN_ID=$(find_workflow_run_id "$SOURCE_SLUG" "$SOURCE_BRANCH" "$HEAD_SHA" "$DISPATCH_AFTER") || \
die "Could not find the workflow run for ${TAG}"

echo "Watching workflow run ${RUN_ID}"
gh run watch "$RUN_ID" --repo "$SOURCE_SLUG" --exit-status

echo ""
echo "Downloading artifact ${ARTIFACT_NAME}"
gh run download "$RUN_ID" \
--repo "$SOURCE_SLUG" \
--name "$ARTIFACT_NAME" \
-D "$DOWNLOAD_DIR"

download_artifact_tree "$DOWNLOAD_DIR" "$ARTIFACT_NAME" "$TAG" "$WORK_DIR"

echo ""
echo "Signing source packages in ${WORK_DIR}"
for rel in ${RELEASES}; do
if [ ! -d "${WORK_DIR}/${rel}" ]; then
continue
fi

changes_files=( "${WORK_DIR}/${rel}"/*.changes )
[ -e "${changes_files[0]}" ] || die "Missing .changes file for ${rel}"

sign_changes "${changes_files[0]}"
done


echo ""
echo "Uploading the signed packages to ${PPA_TARGET}"
pushd "${WORK_DIR}" >/dev/null
changes_files=( */*.changes )
[ -e "${changes_files[0]}" ] || die "Missing .changes files under ${WORK_DIR}"
dput "${PPA_TARGET}" "${changes_files[@]}"
popd >/dev/null

echo "Check build status for ${PPA_TARGET} on Launchpad"
