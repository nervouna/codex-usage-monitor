#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly PROJECT_RELATIVE_PATH="CodexUsageMonitor.xcodeproj/project.pbxproj"
readonly PROJECT_FILE="$REPO_ROOT/$PROJECT_RELATIVE_PATH"
readonly PROJECT_PATH="$REPO_ROOT/CodexUsageMonitor.xcodeproj"
readonly SCHEME="CodexUsageMonitor"
readonly APP_NAME="Codex Usage Monitor.app"
readonly BINARY_NAME="Codex Usage Monitor"
readonly STAGING_ROOT="$REPO_ROOT/.build/staging"
readonly RELEASES_DIR="$REPO_ROOT/.build/releases"

usage() {
    cat <<'EOF'
Usage: scripts/package.sh <adhoc|signed|notarized> [--dry-run] [--confirm-publish]

Modes:
  adhoc       Build a local verification package with an ad hoc signature.
  signed      Build a Developer ID trial package and commit the build bump.
  notarized   Push the build commit, submit to Apple, and staple the ticket.

Options:
  --dry-run          Show gates and planned actions without changing anything.
  --confirm-publish  Required for a non-dry-run notarized package.

Environment:
  DEVELOPER_ID_APPLICATION  Optional identity when more than one is available.
  DEVELOPMENT_TEAM         Optional team ID; derived from the identity by default.
  NOTARYTOOL_PROFILE       Required Keychain profile for notarized packages.
  PACKAGE_DATE             Optional YYYY-MM-DD override, primarily for testing.
EOF
}

fail() {
    print -u2 -- "error: $*"
    exit 1
}

mode="${1:-}"
case "$mode" in
    adhoc|signed|notarized) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
shift

dry_run=false
confirm_publish=false
while (( $# > 0 )); do
    case "$1" in
        --dry-run) dry_run=true ;;
        --confirm-publish) confirm_publish=true ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

if $confirm_publish && [[ "$mode" != "notarized" ]]; then
    fail "--confirm-publish is only valid for notarized packages"
fi
if [[ "$mode" == "notarized" ]] && ! $dry_run && ! $confirm_publish; then
    fail "notarized packaging requires --confirm-publish"
fi

cd "$REPO_ROOT"
[[ -f "$PROJECT_FILE" ]] || fail "project file not found: $PROJECT_FILE"
/usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not a Git worktree"

build_versions="$(
    /usr/bin/sed -nE 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' "$PROJECT_FILE" \
        | /usr/bin/sort -u
)"
[[ "$build_versions" == <-> ]] || fail "CURRENT_PROJECT_VERSION must be one shared integer"
current_build="$build_versions"
next_build=$((current_build + 1))

package_date="${PACKAGE_DATE:-$(/bin/date +%F)}"
validated_date="$(/bin/date -j -f '%Y-%m-%d' "$package_date" '+%Y-%m-%d' 2>/dev/null)" \
    || fail "PACKAGE_DATE must use YYYY-MM-DD"
[[ "$validated_date" == "$package_date" ]] || fail "PACKAGE_DATE must use YYYY-MM-DD"

package_basename="Codex-Usage-Monitor-macOS-universal-${mode}-${package_date}-build-${next_build}"
package_path="$RELEASES_DIR/${package_basename}.zip"
[[ ! -e "$package_path" ]] || fail "release already exists: $package_path"

head_commit="$(/usr/bin/git rev-parse HEAD)"
current_branch="$(/usr/bin/git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[[ -n "$current_branch" ]] || current_branch="(detached)"
worktree_status="$(/usr/bin/git status --porcelain=v1 --untracked-files=all)"

if [[ "$mode" != "adhoc" && -n "$worktree_status" ]]; then
    fail "$mode packaging requires a completely clean worktree (including untracked files)"
fi

if [[ "$mode" == "notarized" ]]; then
    [[ "$current_branch" == "main" ]] || fail "notarized packaging requires branch main"

    if ! $dry_run; then
        /usr/bin/git fetch origin '+refs/heads/main:refs/remotes/origin/main'
    fi
    remote_main="$(/usr/bin/git rev-parse --verify origin/main 2>/dev/null)" \
        || fail "origin/main is unavailable"
    [[ "$head_commit" == "$remote_main" ]] || {
        merge_base="$(/usr/bin/git merge-base HEAD origin/main 2>/dev/null || true)"
        if [[ "$merge_base" == "$remote_main" ]]; then
            fail "main is ahead of origin/main; push the existing commits separately"
        elif [[ "$merge_base" == "$head_commit" ]]; then
            fail "main is behind origin/main"
        else
            fail "main has diverged from origin/main"
        fi
    }
fi

typeset -a signing_arguments
signing_identity=""
development_team=""
if [[ "$mode" == "adhoc" ]]; then
    signing_arguments=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY=-
        ENABLE_HARDENED_RUNTIME=YES
    )
else
    available_identities="$(
        /usr/bin/security find-identity -v -p codesigning \
            | /usr/bin/sed -nE 's/.*"(Developer ID Application:.*)"/\1/p'
    )"
    signing_identity="${DEVELOPER_ID_APPLICATION:-}"
    if [[ -z "$signing_identity" ]]; then
        identity_count="$(print -r -- "$available_identities" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
        [[ "$identity_count" == "1" ]] || fail \
            "expected one Developer ID Application identity; set DEVELOPER_ID_APPLICATION explicitly"
        signing_identity="$available_identities"
    else
        print -r -- "$available_identities" | /usr/bin/grep -Fxq -- "$signing_identity" \
            || fail "DEVELOPER_ID_APPLICATION is not an available signing identity"
    fi

    development_team="${DEVELOPMENT_TEAM:-$(
        print -r -- "$signing_identity" \
            | /usr/bin/sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p'
    )}"
    [[ ${#development_team} -eq 10 && "$development_team" != *[^A-Z0-9]* ]] || fail \
        "could not derive DEVELOPMENT_TEAM from the signing identity"

    signing_arguments=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=$signing_identity"
        "DEVELOPMENT_TEAM=$development_team"
        ENABLE_HARDENED_RUNTIME=YES
    )
fi

if [[ "$mode" == "notarized" ]]; then
    [[ -n "${NOTARYTOOL_PROFILE:-}" ]] || fail \
        "NOTARYTOOL_PROFILE is required for notarized packages"
    /usr/bin/xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" >/dev/null \
        || fail "NOTARYTOOL_PROFILE could not authenticate with Apple"
fi

print -- "Packaging preflight"
print -- "  Mode:          $mode"
print -- "  Branch:        $current_branch"
print -- "  HEAD:          $head_commit"
print -- "  Current build: $current_build"
print -- "  Next build:    $next_build"
print -- "  Package:       $package_path"
if [[ -n "$worktree_status" ]]; then
    print -- "  Worktree:      dirty"
    if [[ "$mode" == "adhoc" ]]; then
        print -- "  Uncommitted files included in the package:"
        print -r -- "$worktree_status" | /usr/bin/sed 's/^/    /'
    fi
else
    print -- "  Worktree:      clean"
fi

print -- "Planned actions"
if [[ "$mode" == "adhoc" ]]; then
    print -- "  - Persist build $next_build in the worktree without committing it."
    print -- "  - Create and verify an ad hoc signed universal Release archive."
elif [[ "$mode" == "signed" ]]; then
    print -- "  - Run the complete XCTest suite."
    print -- "  - Commit only the build-number change; do not push it."
    print -- "  - Create and verify a Developer ID signed universal Release archive."
else
    print -- "  - Run the complete XCTest suite."
    print -- "  - Commit only the build-number change and push that commit to origin/main."
    print -- "  - Upload to Apple, wait for notarization, staple, and verify Gatekeeper."
fi

if $dry_run; then
    print -- "Dry run complete; no files, commits, refs, packages, or notarization requests were changed."
    exit 0
fi

/bin/mkdir -p "$STAGING_ROOT" "$RELEASES_DIR"
work_dir="$(/usr/bin/mktemp -d "$STAGING_ROOT/${package_basename}.incomplete.XXXXXX")"
cleanup_work_dir() {
    /bin/rm -rf -- "$work_dir"
}
trap cleanup_work_dir EXIT INT TERM

archive_path="$work_dir/${package_basename}.xcarchive"
derived_data_path="$work_dir/DerivedData"
staged_package_path="$work_dir/${package_basename}.zip"

if [[ "$mode" != "adhoc" ]]; then
    print -- "Running XCTest before consuming build $next_build..."
    /usr/bin/xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived_data_path" \
        test
fi

PACKAGE_CURRENT_BUILD="$current_build" PACKAGE_NEXT_BUILD="$next_build" \
    /usr/bin/perl -0pi -e '
        my $from = "CURRENT_PROJECT_VERSION = $ENV{PACKAGE_CURRENT_BUILD};";
        my $to = "CURRENT_PROJECT_VERSION = $ENV{PACKAGE_NEXT_BUILD};";
        my $count = s/\Q$from\E/$to/g;
        die "no build settings updated\n" unless $count;
    ' "$PROJECT_FILE"

updated_versions="$(
    /usr/bin/sed -nE 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' "$PROJECT_FILE" \
        | /usr/bin/sort -u
)"
[[ "$updated_versions" == "$next_build" ]] || fail "failed to persist build number $next_build"

if [[ "$mode" != "adhoc" ]]; then
    changed_files="$(/usr/bin/git diff --name-only)"
    [[ "$changed_files" == "$PROJECT_RELATIVE_PATH" ]] || fail \
        "build bump changed files outside $PROJECT_RELATIVE_PATH"
    /usr/bin/git diff --check -- "$PROJECT_RELATIVE_PATH"
    /usr/bin/git add -- "$PROJECT_RELATIVE_PATH"
    staged_files="$(/usr/bin/git diff --cached --name-only)"
    [[ "$staged_files" == "$PROJECT_RELATIVE_PATH" ]] || fail \
        "refusing to commit files outside the build-number change"
    /usr/bin/git diff --cached --quiet -- "$PROJECT_RELATIVE_PATH" \
        && fail "build-number change produced no staged diff"
    /usr/bin/git commit -m "chore: bump build number to $next_build"

    if [[ "$mode" == "notarized" ]]; then
        /usr/bin/git push origin HEAD:main
        /usr/bin/git fetch origin '+refs/heads/main:refs/remotes/origin/main'
        pushed_head="$(/usr/bin/git rev-parse HEAD)"
        pushed_remote="$(/usr/bin/git rev-parse origin/main)"
        [[ "$pushed_head" == "$pushed_remote" ]] || fail \
            "main and origin/main differ after pushing the build commit"
    fi
fi

print -- "Creating universal Release archive..."
/usr/bin/xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    -archivePath "$archive_path" \
    archive \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    "CURRENT_PROJECT_VERSION=$next_build" \
    "${signing_arguments[@]}"

app_path="$archive_path/Products/Applications/$APP_NAME"
[[ -d "$app_path" ]] || fail "archived app not found: $app_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
signature_info="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)"
print -r -- "$signature_info" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' \
    || fail "Hardened Runtime is not enabled"

if [[ "$mode" == "adhoc" ]]; then
    print -r -- "$signature_info" | /usr/bin/grep -Fxq 'Signature=adhoc' \
        || fail "package does not have an ad hoc signature"
else
    print -r -- "$signature_info" | /usr/bin/grep -Fq 'Authority=Developer ID Application:' \
        || fail "package is not signed with Developer ID Application"
    print -r -- "$signature_info" | /usr/bin/grep -Fxq "TeamIdentifier=$development_team" \
        || fail "package team identifier does not match DEVELOPMENT_TEAM"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staged_package_path"

if [[ "$mode" == "notarized" ]]; then
    /usr/bin/xcrun notarytool submit "$staged_package_path" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait
    /usr/bin/xcrun stapler staple "$app_path"
    /usr/bin/xcrun stapler validate "$app_path"
    /bin/rm -- "$staged_package_path"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staged_package_path"
fi

verify_dir="$work_dir/verify"
/bin/mkdir "$verify_dir"
/usr/bin/ditto -x -k "$staged_package_path" "$verify_dir"
verified_app="$verify_dir/$APP_NAME"
[[ -d "$verified_app" ]] || fail "ZIP does not contain $APP_NAME"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$verified_app"

verified_signature_info="$(/usr/bin/codesign -dv --verbose=4 "$verified_app" 2>&1)"
if [[ "$mode" == "adhoc" ]]; then
    print -r -- "$verified_signature_info" | /usr/bin/grep -Fxq 'Signature=adhoc' \
        || fail "unpacked app does not have an ad hoc signature"
else
    print -r -- "$verified_signature_info" | /usr/bin/grep -Fq 'Authority=Developer ID Application:' \
        || fail "unpacked app is not signed with Developer ID Application"
    print -r -- "$verified_signature_info" | /usr/bin/grep -Fxq "TeamIdentifier=$development_team" \
        || fail "unpacked app team identifier does not match DEVELOPMENT_TEAM"
fi

actual_build="$(/usr/bin/defaults read "$verified_app/Contents/Info" CFBundleVersion)"
[[ "$actual_build" == "$next_build" ]] || fail \
    "packaged build $actual_build does not match expected build $next_build"

binary_path="$verified_app/Contents/MacOS/$BINARY_NAME"
architectures="$(/usr/bin/lipo -archs "$binary_path")"
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] || fail \
    "package is not universal: $architectures"

if [[ "$mode" == "notarized" ]]; then
    /usr/bin/xcrun stapler validate "$verified_app"
    /usr/sbin/spctl -a -vvv -t execute "$verified_app"
fi

checksum="$(/usr/bin/shasum -a 256 "$staged_package_path" | /usr/bin/awk '{print $1}')"
/bin/mv -n -- "$staged_package_path" "$package_path"
[[ ! -e "$staged_package_path" && -f "$package_path" ]] || fail \
    "release path appeared while publishing: $package_path"

print -- "Package: $package_path"
print -- "Build:   $next_build"
print -- "SHA-256: $checksum"
