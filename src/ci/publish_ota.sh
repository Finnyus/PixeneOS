#!/usr/bin/env bash

# Publish the update info of a release to the OTA server (the gh-pages branch).
#
# Reads from the environment:
#   DEVICE_NAME         Device code name
#   GRAPHENEOS_VERSION  GrapheneOS version of the release
#   ROOT                `apatch`, `magisk`, or `rootless` (legacy `true` -> `apatch`, `false` -> `rootless`)
#   RELEASE_TYPE        `force-publish` updates the server even without changes

set -o nounset -o pipefail -o errexit

CURRENT_COMMIT=$(git rev-parse --short HEAD)
FLAVOR=("apatch" "magisk" "rootless")

# Create `apatch`, `magisk`, and `rootless` directories if they don't exist
mkdir -p "${FLAVOR[@]}"

# Switch to gh-pages branch
git checkout gh-pages
echo -e "Updating Configs for the new release..."

# Select target directory based on ROOT flavor or the asset URL in <device_name>.json
if [[ "${ROOT:-}" == "apatch" || "${ROOT:-}" == "true" ]] || grep -q apatch "${DEVICE_NAME}.json"; then
  TARGET_FILE="${FLAVOR[0]}/${DEVICE_NAME}.json"
elif [[ "${ROOT:-}" == "magisk" ]] || grep -q magisk "${DEVICE_NAME}.json"; then
  TARGET_FILE="${FLAVOR[1]}/${DEVICE_NAME}.json"
else
  TARGET_FILE="${FLAVOR[2]}/${DEVICE_NAME}.json"
fi

# Check if the target file exists, if not create an empty one to avoid any issues
if [ ! -f "${TARGET_FILE}" ]; then
  echo -e "touching ${TARGET_FILE}..."
  touch "${TARGET_FILE}"
fi

# Copy from `./` to `./<flavor>/` if the update info changed or if it's a force-publish
# A plain version check is not enough: a force rebuild keeps the version but changes the asset URL
if [[ "${RELEASE_TYPE:-}" == "force-publish" ]] || ! cmp -s "${DEVICE_NAME}.json" "${TARGET_FILE}"; then
  echo -e "Copying ${DEVICE_NAME}.json to ${TARGET_FILE}..."
  cp "${DEVICE_NAME}.json" "${TARGET_FILE}"
  git add "${TARGET_FILE}"
else
  echo -e "Deployed version (${GRAPHENEOS_VERSION}) is same as current GrapheneOS release (${GRAPHENEOS_VERSION}).\nUpdate skipped."
fi

# Commit and push the changes if there is something to publish
if ! git diff-index --quiet HEAD; then
  git commit -m "release(${CURRENT_COMMIT}): bump GrapheneOS version to ${GRAPHENEOS_VERSION}"
  # Rebase to survive concurrent pushes from parallel device builds, see multi-release.yml
  git pull --rebase origin gh-pages
  git push origin gh-pages
fi

# Switch back to main branch
git checkout main
