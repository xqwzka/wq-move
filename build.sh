#!/usr/bin/env bash
# Builds 聊天记录迁移.ipa (arm64, ad-hoc signed with the App Group entitlement;
# re-sign with your sideloading tool, keeping an App Group).
# The app policy is iOS 26.0 or later; the SDK version is intentionally not the
# deployment target. Set WQMOVE_FINAL_IPA to override the publication path.
# Adapted from the build.sh of WQ Files (kolbicz/WQFiles, GPL-3.0-or-later).
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
MINIMUM_IOS_VERSION=26.0
FINAL_IPA=${WQMOVE_FINAL_IPA:-聊天记录迁移.ipa}

# Publish only after the host regression suite passes, when one exists.
if [[ "${WQ_SKIP_PREFLIGHT:-0}" != 1 && -x "$ROOT/tests/run_all_tests.sh" ]]; then
    "$ROOT/tests/run_all_tests.sh"
fi
if [[ "$FINAL_IPA" != /* ]]; then
    FINAL_IPA="$ROOT/$FINAL_IPA"
fi
FINAL_DIR=$(dirname -- "$FINAL_IPA")
if [[ ! -d "$FINAL_DIR" ]]; then
    echo "final IPA directory does not exist: $FINAL_DIR" >&2
    exit 1
fi

plist_value() {
    plutil -extract "$1" raw -o - "$2"
}

fail() {
    echo "build validation failed: $*" >&2
    exit 1
}

EXPECTED_BUNDLE_ID=$(plist_value CFBundleIdentifier Info.plist)
EXPECTED_VERSION=$(plist_value CFBundleShortVersionString Info.plist)
EXPECTED_BUILD=$(plist_value CFBundleVersion Info.plist)
EXPECTED_MINIMUM_OS=$(plist_value MinimumOSVersion Info.plist)
APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' entitlements.plist)
[[ -n "$APP_GROUP" ]] || fail "entitlements.plist has no App Group"
[[ "$EXPECTED_MINIMUM_OS" == "$MINIMUM_IOS_VERSION" ]] || \
    fail "Info.plist minimum OS $EXPECTED_MINIMUM_OS does not match build policy $MINIMUM_IOS_VERSION"

OUT=$(mktemp -d "$FINAL_DIR/.WQMove-build.XXXXXX")
IPA_TMP=$(mktemp "$FINAL_DIR/.WQMove.ipa.XXXXXX")
rm -f -- "$IPA_TMP"
CHECK_DIR=""
cleanup() {
    if [[ -n "${OUT:-}" && -d "$OUT" ]]; then rm -rf -- "$OUT"; fi
    if [[ -n "${IPA_TMP:-}" && -e "$IPA_TMP" ]]; then rm -f -- "$IPA_TMP"; fi
    if [[ -n "${CHECK_DIR:-}" && -d "$CHECK_DIR" ]]; then rm -rf -- "$CHECK_DIR"; fi
}
trap cleanup EXIT

APP="$OUT/Payload/WQMove.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -arch arm64 \
    -miphoneos-version-min="$MINIMUM_IOS_VERSION" \
    -isysroot "$SDK" -Wall -Wextra -Werror -O2 \
    -framework UIKit -framework Foundation -framework Security -framework UniformTypeIdentifiers \
    WQCore.m WQAccess.m WQLocalization.m WQLaunchServices.m WQUI.m main.m -lsqlite3 -lz -o "$APP/WQMove"
cp Info.plist "$APP/Info.plist"
cp icons/AppIcon*.png "$APP/"
cp icons/Footer*.png "$APP/"
plutil -convert binary1 "$APP/Info.plist"
codesign -f -s - --entitlements entitlements.plist "$APP"

validate_app() {
    local app_path=$1
    [[ -x "$app_path/WQMove" ]] || fail "missing executable in $app_path"
    [[ -f "$app_path/Info.plist" ]] || fail "missing Info.plist in $app_path"
    [[ -f "$app_path/AppIcon1024.png" ]] || fail "missing AppIcon1024.png in $app_path"
    [[ -f "$app_path/FooterGitHub@3x.png" ]] || fail "missing FooterGitHub@3x.png in $app_path"
    [[ -f "$app_path/FooterTelegram@3x.png" ]] || fail "missing FooterTelegram@3x.png in $app_path"
    [[ "$(plist_value CFBundleIdentifier "$app_path/Info.plist")" == "$EXPECTED_BUNDLE_ID" ]] || \
        fail "bundle identifier does not match source metadata"
    [[ "$(plist_value CFBundleShortVersionString "$app_path/Info.plist")" == "$EXPECTED_VERSION" ]] || \
        fail "short version does not match source metadata"
    [[ "$(plist_value CFBundleVersion "$app_path/Info.plist")" == "$EXPECTED_BUILD" ]] || \
        fail "build version does not match source metadata"
    [[ "$(plist_value MinimumOSVersion "$app_path/Info.plist")" == "$EXPECTED_MINIMUM_OS" ]] || \
        fail "minimum OS does not match source metadata"
    codesign --verify --deep --strict "$app_path"
    local signed_entitlements
    signed_entitlements=$(codesign -d --entitlements :- "$app_path" 2>&1) || \
        fail "unable to inspect signed entitlements"
    [[ "$signed_entitlements" == *"$APP_GROUP"* ]] || \
        fail "signed app is missing required App Group $APP_GROUP"
}

# Package to a same-directory temporary sibling, then validate the actual ZIP
# contents and signature. The final path is untouched until all checks pass.
(cd "$OUT" && zip -qry "$IPA_TMP" Payload)
unzip -tqq "$IPA_TMP"
CHECK_DIR=$(mktemp -d "$OUT/ipa-check.XXXXXX")
unzip -q "$IPA_TMP" -d "$CHECK_DIR"
validate_app "$CHECK_DIR/Payload/WQMove.app"
mv -f -- "$IPA_TMP" "$FINAL_IPA"
IPA_TMP=""
echo "wrote $FINAL_IPA"
