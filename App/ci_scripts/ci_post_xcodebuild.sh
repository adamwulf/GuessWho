#!/bin/sh

set -e

# Build a tokenized push URL for origin from input username and token
github_authed_url() {
    # Get the original URL
    original_url=$(git remote get-url origin)
    # Extract the rest of the URL after the protocol
    rest_url=${original_url#*://}
    # Extract everything after github.com/
    github_path=${rest_url#*github.com/}
    # Construct the new URL with the token
    echo "https://${1}:${2}@github.com/${github_path}"
}

# Fetch the current version number from the built app
get_app_version() {
    # Get the path to the .app bundle
    app_path="${1}/Products/Applications"
    # Find the .app file
    app_file=$(find "$app_path" -name "*.app" -maxdepth 1)
    # Get the path to the Info.plist file
    plist_path="${app_file}/Contents/Info.plist"
    # Check if the plist file exists
    if [ ! -f "$plist_path" ]; then
        echo "Error: plist file not found at $plist_path"
        return 1
    fi

    # Extract the version number from the Info.plist file
    version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${plist_path}")

    # Check if the version number was successfully extracted
    if [ -z "$version" ]; then
        echo "Error: failed to extract version number from plist file"
        return 1
    fi
    echo $version
}

# Next, automatically tag the build in Github

if [ "$CI_XCODEBUILD_EXIT_CODE" -eq 0 ]; then
    echo "Build succeeded"
    tag="build/$CI_BUILD_NUMBER"

    # GITHUB_TOKEN can be configured in github -> account settings -> developer settings -> personal access tokens -> fine grained token -> read/write access to code
    remote_url=$(github_authed_url $GITHUB_USERNAME $GITHUB_TOKEN)

    # This script runs once per xcodebuild action, so the same build can reach
    # here more than once. Skip if the tag is already on the remote — never
    # force-push, so an existing build/N tag can't be moved to a new commit.
    if git ls-remote --tags "$remote_url" "refs/tags/$tag" | grep -q "refs/tags/$tag"; then
        echo "Tag $tag already exists on remote, skipping."
    else
        echo "Tagging $tag"
        git tag -a -m "Build $CI_BUILD_NUMBER" $tag
        git push "$remote_url" --tags
        echo "Successfully pushed tag to remote repo."
    fi
else
    echo "Build failed"
    # Build failed
fi
