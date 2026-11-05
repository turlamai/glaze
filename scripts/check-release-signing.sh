#!/usr/bin/env bash
# Fail a production release before building anything when signed installers are
# required but the signing identities are absent. Unsigned releases remain the
# default; set the repository variable GLAZE_REQUIRE_SIGNED_INSTALLERS=1 to
# make this gate mandatory.
set -euo pipefail

if [ "${GLAZE_REQUIRE_SIGNED_INSTALLERS:-0}" != "1" ]; then
  echo "Signed installers are not required; unsigned artifacts are allowed."
  exit 0
fi

missing=()
for name in APPLE_SIGN_IDENTITY APPLE_NOTARY_PROFILE WINDOWS_SIGN_IDENTITY; do
  if [ -z "${!name:-}" ]; then
    missing+=("$name")
  fi
done

if [ "${#missing[@]}" -ne 0 ]; then
  echo "Signed installers are required but these values are missing:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "Set the corresponding repository secrets or unset GLAZE_REQUIRE_SIGNED_INSTALLERS." >&2
  exit 1
fi

echo "Signing identities are present."
