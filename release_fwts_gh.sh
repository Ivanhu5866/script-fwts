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

SOURCE_REPO="https://github.com/fwts/fwts"
WORKFLOW_NAME="release.yml"
PPA_TARGET="${PPA_TARGET:-ppa:firmware-testing-team/ppa-fwts-unstable-crack}"

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
	printf '%s\n' "${SOURCE_REPO#https://github.com/}" | sed 's#/$##'
}

default_branch() {
	gh repo view "$(repo_slug)" --json defaultBranchRef --jq .defaultBranchRef.name
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

if [ $# -eq 0 ]; then
	echo "Please provide release version, ex. 26.01.12."
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
REPO_SLUG=$(repo_slug)
DEFAULT_BRANCH=$(default_branch)
DEFAULT_GIT_NAME=$(global_git_config user.name || true)
DEFAULT_GIT_EMAIL=$(global_git_config user.email || true)
GIT_NAME=$(prompt_git_name "${DEFAULT_GIT_NAME}")
[ -n "${GIT_NAME}" ] || die "Git author name is required"
EMAIL_USER=$(prompt_email_user "$(default_email_user "${DEFAULT_GIT_EMAIL}")")
[ -n "${EMAIL_USER}" ] || die "Email user is required"
RELEASES=$(workflow_releases "${REPO_SLUG}" "${DEFAULT_BRANCH}")
[ -n "${RELEASES}" ] || die "Could not read RELEASES from ${SOURCE_REPO} ${WORKFLOW_NAME} on ${DEFAULT_BRANCH}"
LATEST_SERIES=$(latest_series)
ARTIFACT_NAME="fwts-source-packages-${TAG}"
WORK_DIR="${PWD}/${TAG}"
DOWNLOAD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fwts-release-gh.${RELEASE_VERSION}.XXXXXX")
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

echo "FWTS ${TAG} is to be released."
echo "The GitHub workflow will update changelog, version, tag, release notes and build unsigned source packages."
prompt_continue

echo ""
echo "Please confirm GitHub Actions permissions, GPG signing setup and PPA upload rights."
prompt_continue

HEAD_SHA=$(gh api "repos/${REPO_SLUG}/commits/${DEFAULT_BRANCH}" --jq .sha)
DISPATCH_AFTER=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo ""
echo "Dispatching ${WORKFLOW_NAME} on ${REPO_SLUG} for ${TAG}"
gh workflow run "$WORKFLOW_NAME" \
	--repo "$REPO_SLUG" \
	--ref "$DEFAULT_BRANCH" \
	-f version="${RELEASE_VERSION}" \
	-f git_name="${GIT_NAME}" \
	-f email_user="${EMAIL_USER}"

echo "Waiting for the workflow run to appear"
RUN_ID=$(find_workflow_run_id "$REPO_SLUG" "$DEFAULT_BRANCH" "$HEAD_SHA" "$DISPATCH_AFTER") || \
	die "Could not find the workflow run for ${TAG}"

echo "Watching workflow run ${RUN_ID}"
gh run watch "$RUN_ID" --repo "$REPO_SLUG" --exit-status

echo ""
echo "Downloading artifact ${ARTIFACT_NAME}"
gh run download "$RUN_ID" \
	--repo "$REPO_SLUG" \
	--name "$ARTIFACT_NAME" \
	-D "$DOWNLOAD_DIR"

[ ! -e "$WORK_DIR" ] || die "${WORK_DIR} already exists"

if [ -d "${DOWNLOAD_DIR}/package-build/${TAG}" ]; then
	mv "${DOWNLOAD_DIR}/package-build/${TAG}" "$WORK_DIR"
elif [ -d "${DOWNLOAD_DIR}/${TAG}" ]; then
	mv "${DOWNLOAD_DIR}/${TAG}" "$WORK_DIR"
elif [ -f "${DOWNLOAD_DIR}/package-build/${ARTIFACT_NAME}.tar.gz" ]; then
	tar -C "${PWD}" -xzf "${DOWNLOAD_DIR}/package-build/${ARTIFACT_NAME}.tar.gz"
elif [ -f "${DOWNLOAD_DIR}/${ARTIFACT_NAME}.tar.gz" ]; then
	tar -C "${PWD}" -xzf "${DOWNLOAD_DIR}/${ARTIFACT_NAME}.tar.gz"
else
	die "Downloaded artifact does not contain ${TAG}"
fi

[ -d "$WORK_DIR" ] || die "Could not prepare ${WORK_DIR}"

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
echo "do ADT test"
echo "sudo autopkgtest ${WORK_DIR}/${LATEST_SERIES}/fwts_${RELEASE_VERSION}-0ubuntu1.dsc -- null"
echo "..and check for the error status at the end of the test with:"
echo "echo \$?"
echo "0 is a pass, otherwise anything else is a fail."
wait_done

echo ""
echo "Uploading the signed packages to ${PPA_TARGET}"
pushd "${WORK_DIR}" >/dev/null
changes_files=( */*.changes )
[ -e "${changes_files[0]}" ] || die "Missing .changes files under ${WORK_DIR}"
dput "${PPA_TARGET}" "${changes_files[@]}"
popd >/dev/null

echo "Check build status for ${PPA_TARGET} on Launchpad"
echo ""
# update SHA256 on fwts.ubuntu.com(optional)
echo "Run the following commands on fwts.ubuntu.com: (optional)"
echo "  1. cp fwts_${RELEASE_VERSION}.orig.tar.gz fwts-V${RELEASE_VERSION}.tar.gz"
echo "  2. scp fwts-V${RELEASE_VERSION}.tar.gz ivanhu@kernel-bastion-ps5:~/"
echo "  3. ssh kernel-bastion-ps5.internal"
echo "  4. pe fwts"
echo "  5. juju scp /home/ivanhu/fwts-V${RELEASE_VERSION}.tar.gz 0:/srv/fwts.ubuntu.com/www/release/"
echo "  6. juju ssh 0"
echo "  7. cd /srv/fwts.ubuntu.com/www/release/"
echo "  8. sha256sum fwts-V${RELEASE_VERSION}.tar.gz >> SHA256SUMS"
echo "  9. exit"
echo ""
echo "When the build finishes, please do the following:"
echo "  1. copy package to PPA https://launchpad.net/~canonical-fwts-team/+archive/ubuntu/fwts-release-builds"
echo "  2. copy packages to stage PPA (Firmware Test Suite (Stable))"
echo "  3. create a new release note page https://wiki.ubuntu.com/FirmwareTestSuite/ReleaseNotes/xx.xx.xx"
echo "  4. upload the new FWTS package to the Ubuntu universe archive"
echo "  5. update milestone on https://launchpad.net/fwts"
echo "  6. build fwts snap, https://launchpad.net/~firmware-testing-team/fwts/+snap/fwts"
echo "  7. email to fwts-devel and fwts-announce lists"
echo "  8. build new fwts-live"
