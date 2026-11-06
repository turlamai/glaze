#!/usr/bin/env bash
# Fail a production release before building anything when signing is required
# for a platform but its identity is absent.
#
# GLAZE_REQUIRE_SIGNED_INSTALLERS is a comma-separated platform list:
#   none / 0 / unset   unsigned installers allowed (default)
#   all / 1 / true     apple and windows required
#   apple              Apple Developer ID + notary required; Windows unsigned
#   windows            Authenticode required; Apple unsigned
#   apple,windows      both required
set -euo pipefail

raw="${GLAZE_REQUIRE_SIGNED_INSTALLERS:-0}"

case "$raw" in
  ""|0|false|none)
    echo "Signed installers are not required; unsigned artifacts are allowed."
    exit 0
    ;;
  1|true|all)
    required=(apple windows)
    ;;
  *)
    IFS=',' read -r -a required <<< "$raw"
    ;;
esac

missing=()
for platform in "${required[@]}"; do
  case "$platform" in
    apple)
      [ -n "${APPLE_SIGN_IDENTITY:-}" ] || missing+=("APPLE_SIGN_IDENTITY (apple)")
      [ -n "${APPLE_NOTARY_PROFILE:-}" ] || missing+=("APPLE_NOTARY_PROFILE (apple)")
      ;;
    windows)
      [ -n "${WINDOWS_SIGN_IDENTITY:-}" ] || missing+=("WINDOWS_SIGN_IDENTITY (windows)")
      ;;
    *)
      echo "Unknown platform '$platform' in GLAZE_REQUIRE_SIGNED_INSTALLERS." >&2
      echo "Use none, apple, windows, apple,windows, or all." >&2
      exit 2
      ;;
  esac
done

if [ "${#missing[@]}" -ne 0 ]; then
  echo "Signed installers are required for: ${required[*]}" >&2
  echo "These values are missing:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "Set the corresponding repository secrets or narrow GLAZE_REQUIRE_SIGNED_INSTALLERS." >&2
  exit 1
fi

echo "Signing identities are present for: ${required[*]}"
