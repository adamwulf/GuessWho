#!/bin/sh

set -e

# Build a tokenized push URL for origin from input username and token.
# Handles both HTTPS (https://github.com/owner/repo.git) and SSH
# (git@github.com:owner/repo.git) origins: remove the scheme or "git@" prefix,
# then take everything after the FIRST github.com separator (colon OR slash),
# so the rebuilt URL always has exactly one slash between github.com and the
# owner. A plain ${rest_url#*github.com/} only matches the HTTPS form and leaves
# an SSH origin's "github.com:owner/repo" in place, which makes a broken URL.
github_authed_url() {
    # Get the original URL
    original_url=$(git remote get-url origin)
    # Remove an https:// (or similar) scheme if present
    rest_url=${original_url#*://}
    # Remove an SSH "git@" prefix if present
    rest_url=${rest_url#git@}
    # Take everything after the first github.com separator (colon OR slash)
    github_path=${rest_url#github.com[:/]}
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

    # --- Generate TestFlight "What to Test" notes -------------------------
    # Xcode Cloud auto-uploads App/TestFlight/WhatToTest.<locale>.txt as the
    # tester-facing "What to Test" notes. We generate it here from the commit
    # range since the last build, so nothing is committed to the repo — the
    # file lives only in this ephemeral clone. Gated on the signed-app path so
    # it runs only for distribution builds that actually upload to TestFlight.
    if [ -n "$CI_APP_STORE_SIGNED_APP_PATH" ] && [ -d "$CI_APP_STORE_SIGNED_APP_PATH" ]; then
        # Xcode Cloud clones shallow and without tags; deepen so the tag range
        # and commit history are reachable for git describe / git log. Depth 100
        # spans roughly twenty builds of history, so it reaches the previous
        # build/* tag without paying for a full --unshallow every run. Try the
        # configured origin first; fall back to the tokenized URL with an explicit
        # refspec, because the credentials Xcode Cloud used to clone are not
        # guaranteed to still work for an ad-hoc fetch. Keep stderr suppressed on
        # the tokenized fetch — git echoes the failing URL, which carries the PAT.
        if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
            git fetch --deepen 100 2>/dev/null \
                || git fetch --deepen 100 "$remote_url" '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null \
                || true
        fi
        git fetch "$remote_url" 'refs/tags/*:refs/tags/*' 2>/dev/null || true

        # Previous build's tag = lower bound. build/* numbers can skip (failed
        # or manual runs), so use the most recent reachable tag, not N-1. This
        # runs before the new build/$CI_BUILD_NUMBER tag is created below, so
        # HEAD's nearest build/* tag is genuinely the previous build.
        #
        # A build/* tag can already sit ON the commit being built, which would
        # make the range empty and silently swap the real notes for the
        # placeholder. This script runs once per xcodebuild action, so a sibling
        # action (we archive iOS and Mac Catalyst) can tag this very commit first,
        # and a rebuild re-runs against an already-tagged commit. Stepping back to
        # HEAD^ skips every tag on HEAD at once, not just the newest of them.
        head_sha=$(git rev-parse HEAD)
        prev_tag=$(git describe --tags --match 'build/*' --abbrev=0 HEAD 2>/dev/null || echo "")
        if [ -n "$prev_tag" ] && [ "$(git rev-list -n 1 "$prev_tag")" = "$head_sha" ]; then
            prev_tag=$(git describe --tags --match 'build/*' --abbrev=0 'HEAD^' 2>/dev/null || echo "")
        fi
        if [ -n "$prev_tag" ]; then
            notes=$(git log --no-merges --pretty=format:'- %s' "${prev_tag}..HEAD")
        else
            # First build ever: no prior tag. Cap to the last 20 commits.
            notes=$(git log --no-merges -20 --pretty=format:'- %s' HEAD)
        fi

        # An empty notes file uploaded to TestFlight is worse than a placeholder
        # line. Reaching the placeholder almost always means the history lookup
        # failed rather than that nothing shipped, so log a warning where the
        # build report will show it.
        if [ -z "$notes" ]; then
            notes="- Maintenance build (no source changes since last build)"
            echo "warning: What-to-Test found no commits; falling back to the placeholder"
        fi

        notes_dir="$CI_PRIMARY_REPOSITORY_PATH/App/TestFlight"
        mkdir -p "$notes_dir"
        printf '%s\n' "$notes" > "$notes_dir/WhatToTest.en-US.txt"
        echo "Wrote What-to-Test notes (previous tag: ${prev_tag:-none}, shallow: $(git rev-parse --is-shallow-repository))"
    fi
    # ---------------------------------------------------------------------

    # This script runs once per xcodebuild action, so the same build can reach
    # here more than once. Skip if the tag is already on the remote — never
    # force-push, so an existing build/N tag can't be moved to a new commit.
    if git ls-remote --tags "$remote_url" "refs/tags/$tag" | grep -q "refs/tags/$tag"; then
        echo "Tag $tag already exists on remote, skipping."
    else
        echo "Tagging $tag"
        git tag -a -m "Build $CI_BUILD_NUMBER" $tag
        # Push only the new tag ref, never every local tag. A blanket --tags can
        # re-push (and a force could move) an already-shipped build/N tag onto a
        # different commit and corrupt the range used for future notes.
        git push "$remote_url" "refs/tags/$tag"
        echo "Successfully pushed tag to remote repo."
    fi
else
    echo "Build failed"
    # Build failed
fi
