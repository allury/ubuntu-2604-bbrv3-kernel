#!/usr/bin/env bash
# Print a patch drift report's summary, and its diff when it is short, as
# GitHub Actions annotations. Unlike the job log and the artifacts, annotations
# can be read without signing in, so the drift can be reviewed from anywhere.
set -euo pipefail

report="${1:?Usage: annotate-patch-drift.sh <report-file>}"
# The runner cuts every annotation message at 4096 characters without saying
# so; a diff that does not fit is left to the report file instead.
max_diff_bytes=4000

escape() {
  local text="$1"
  text="${text//'%'/'%25'}"
  text="${text//$'\r'/}"
  printf '%s' "${text//$'\n'/'%0A'}"
}

summary="$(sed -n -E '/^(Review baseline|Built source|Patched files|Changed since baseline|Lines added|Lines removed): /p' \
  "$report" | paste -sd ';' -)"
printf '::notice title=Patch baseline drift::%s\n' "$(escape "$summary")"

diff_text="$(sed -n '/^diff --git /,$p' "$report")"
if [[ -n "$diff_text" ]]; then
  diff_lines="$(wc -l <<<"$diff_text")"
  diff_bytes="$(printf '%s' "$diff_text" | LC_ALL=C wc -c)"
  if (( diff_bytes <= max_diff_bytes )); then
    printf '::notice title=Patch baseline drift diff::%s\n' "$(escape "$diff_text")"
  else
    printf '::notice title=Patch baseline drift diff::%s lines, too long for an annotation; see PATCH-BASELINE-DRIFT.txt.\n' \
      "$diff_lines"
  fi
fi
