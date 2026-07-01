#!/bin/sh

set -e

# Define a function to push to the remote repo with input username and token
git_push_tags_with_token() {
    # Get the original URL
    original_url=$(git remote get-url origin)
    # Extract the protocol and the rest of the URL
    protocol=${original_url%%://*}
    rest_url=${original_url#*://}
    # Extract everything after github.com/
    github_path=${rest_url#*github.com/}
    # Construct the new URL with the token
    new_url="https://${1}:${2}@github.com/${github_path}"
    # Push the tags
    git push $new_url --tags -f
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
    echo "Tagging $tag"
    # Annotated tags need a committer identity, and Xcode Cloud's build
    # environment doesn't configure one; set a repo-local identity if absent.
    if ! git config user.email > /dev/null; then
        git config user.name "Xcode Cloud"
        git config user.email "ci@xcodecloud.apple.com"
    fi
    git tag -a -m "Build $CI_BUILD_NUMBER" $tag

    # GITHUB_TOKEN can be configured in github -> account settings -> developer settings -> personal access tokens -> fine grained token -> read/write access to code
    git_push_tags_with_token $GITHUB_USERNAME $GITHUB_TOKEN

    echo "Successfully pushed tag to remote repo."
else
    echo "Build failed"
    # Build failed
fi
