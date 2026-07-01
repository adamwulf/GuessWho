#!/bin/sh

# Stamp the build number from Xcode Cloud's monotonic counter.
# CI_BUILD_NUMBER is set by Xcode Cloud and increments per workflow run,
# guaranteeing App Store Connect sees a new value every upload.
#
# GuessWho versions via xcconfig (App/Config/SharedVersion.xcconfig) as the
# single source of truth shared by both app targets, so we stamp
# CURRENT_PROJECT_VERSION there rather than a per-target Info.plist.

set -e

if [ -z "$CI_BUILD_NUMBER" ]; then
    echo "CI_BUILD_NUMBER is not set; skipping build number stamp."
    exit 0
fi

VERSION_XCCONFIG="$CI_PRIMARY_REPOSITORY_PATH/App/Config/SharedVersion.xcconfig"

if [ ! -f "$VERSION_XCCONFIG" ]; then
    echo "Error: version xcconfig not found at $VERSION_XCCONFIG"
    exit 1
fi

echo "Setting CURRENT_PROJECT_VERSION to $CI_BUILD_NUMBER in $VERSION_XCCONFIG"
sed -i '' -E "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER/" "$VERSION_XCCONFIG"
