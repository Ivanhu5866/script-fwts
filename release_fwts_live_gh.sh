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

BUILD_REPO="${BUILD_REPO:-https://github.com/Ivanhu5866/fwts-live-build}"
LIVE_REPO="${LIVE_REPO:-https://github.com/fwts/fwts-live}"
WORKFLOW_NAME="build-live-image.yml"

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

global_git_config() {
	local key="$1"
	git config --global --get "$key"
}

default_email_user() {
	local git_email="$1"
	printf '%s\n' "${git_email%@*}"
}

prompt_continue() {
	read -r -p "Please [ENTER] to continue or Ctrl+C to abort"
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

if [ $# -eq 0 ]; then
	echo "Please provide release version, ex. 26.03.00."
	exit 1
fi

require_cmd gh
require_cmd git

gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

RELEASE_VERSION=$(normalize_version "$1")
TAG="V${RELEASE_VERSION}"
IMAGE_NAME="fwts-live-${RELEASE_VERSION}-x86_64.img.xz"
BUILD_SLUG=$(repo_slug "$BUILD_REPO")
LIVE_SLUG=$(repo_slug "$LIVE_REPO")
BUILD_BRANCH=$(gh repo view "$BUILD_SLUG" --json defaultBranchRef --jq .defaultBranchRef.name)
DEFAULT_GIT_NAME=$(global_git_config user.name || true)
GIT_NAME=$(prompt_git_name "${DEFAULT_GIT_NAME}")
[ -n "${GIT_NAME}" ] || die "Git author name is required"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fwts-live-release.${RELEASE_VERSION}.XXXXXX")
CLONE_DIR="${TEMP_DIR}/fwts-live"
DOWNLOAD_DIR="${TEMP_DIR}/download"
mkdir -p "${DOWNLOAD_DIR}"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "The release flow will:"
echo "  1. dispatch ${WORKFLOW_NAME} on ${BUILD_REPO}"
echo "  2. watch the build to completion"
echo "  3. download ${IMAGE_NAME} from the build release"
echo "  4. clone ${LIVE_REPO} and update SHA256SUM.txt"
echo "  5. create release ${RELEASE_VERSION}-x86_64 on ${LIVE_REPO}"
prompt_continue

# Step 1+2: dispatch and watch
HEAD_SHA=$(gh api "repos/${BUILD_SLUG}/commits/${BUILD_BRANCH}" --jq .sha)
DISPATCH_AFTER=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo ""
echo "Dispatching ${WORKFLOW_NAME} on ${BUILD_SLUG} for ${RELEASE_VERSION}"
gh workflow run "$WORKFLOW_NAME" \
	--repo "$BUILD_SLUG" \
	--ref "$BUILD_BRANCH" \
	-f version="${RELEASE_VERSION}" \
	-f git_name="${GIT_NAME}"

echo "Waiting for the workflow run to appear..."
RUN_ID=$(find_workflow_run_id "$BUILD_SLUG" "$BUILD_BRANCH" "$HEAD_SHA" "$DISPATCH_AFTER") || \
	die "Could not find the workflow run"

echo "Watching workflow run ${RUN_ID}"
gh run watch "$RUN_ID" --repo "$BUILD_SLUG" --exit-status

# Step 3: download image from build repo release
echo ""
echo "Downloading ${IMAGE_NAME} from ${BUILD_REPO} release ${TAG}"
gh release download "$TAG" \
	--repo "$BUILD_SLUG" \
	--pattern "$IMAGE_NAME" \
	--dir "$DOWNLOAD_DIR"

IMAGE_FILE="${DOWNLOAD_DIR}/${IMAGE_NAME}"
[ -f "$IMAGE_FILE" ] || die "Downloaded image not found: ${IMAGE_FILE}"

# Step 4: clone fwts-live and update SHA256SUM.txt
echo ""
echo "Cloning ${LIVE_REPO}"
git clone "$LIVE_REPO" "$CLONE_DIR"

CHECKSUM=$(sha256sum "$IMAGE_FILE" | awk '{print $1}')
echo "${CHECKSUM}  ${IMAGE_NAME}" >> "${CLONE_DIR}/SHA256SUM.txt"

pushd "$CLONE_DIR" >/dev/null
git config user.name "${GIT_NAME}"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add SHA256SUM.txt
git commit -s -m "${RELEASE_VERSION}-x86_64"
git tag "${RELEASE_VERSION}-x86_64"
git push origin master
git push origin "${RELEASE_VERSION}-x86_64"
popd >/dev/null

# Step 5: create release on fwts/fwts-live
echo ""
echo "Creating release ${RELEASE_VERSION}-x86_64 on ${LIVE_REPO}"
gh release create "${RELEASE_VERSION}-x86_64" \
	--repo "$LIVE_SLUG" \
	--title "${RELEASE_VERSION}-x86_64" \
	--notes "fwts-live image ${RELEASE_VERSION} (x86_64)" \
	"${IMAGE_FILE}"

echo ""
echo "Done. fwts-live ${RELEASE_VERSION}-x86_64 released on ${LIVE_REPO}"
