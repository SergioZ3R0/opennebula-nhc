#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

missing=0

while IFS= read -r file; do
  case "$file" in
    *.rb | *.sh | *.yml | *.yaml | bin/* | systemd/* | etc/*)
      if ! grep -q "SPDX-License-Identifier: Apache-2.0" "$file"; then
        echo "missing SPDX header: $file" >&2
        missing=1
      fi
      ;;
  esac

  case "$file" in
    *.rb | bin/*)
      if ! grep -q "frozen_string_literal: true" "$file"; then
        echo "missing frozen_string_literal: $file" >&2
        missing=1
      fi
      ;;
  esac
done < <(git ls-files)

exit "$missing"
