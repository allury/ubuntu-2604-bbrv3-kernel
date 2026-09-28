#!/usr/bin/env bash
# Compare a BBRv3 patch with the Google BBRv3 release it was ported from.
#
# Google's change is the difference between the Linux release its branch is
# based on and the branch itself. The port's change is the difference between
# the Ubuntu source tag named in the patch file and that tag with the patch
# applied. The report lists every line one change makes and the other does
# not, and compares whole files where Google replaces the implementation.
# All inputs are pinned, so a second run must produce the same bytes; CI
# checks the committed reports that way.
set -euo pipefail

usage='Usage: audit-google-bbrv3.sh <reference-file> <patch-file> <git-dir> <report-file>'
reference_file="${1:?$usage}"
patch_file="${2:?$usage}"
git_dir="${3:?$usage}"
report_file="${4:?$usage}"
ubuntu_repository="${UBUNTU_KERNEL_REPOSITORY:?Set UBUNTU_KERNEL_REPOSITORY to the Ubuntu kernel Git repository.}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Byte order for every sort and comparison, and literal pathspecs: file names
# come from the diffs, never patterns.
export LC_ALL=C GIT_LITERAL_PATHSPECS=1

[[ -f "$reference_file" ]] || die "Missing reference file: $reference_file"
[[ -f "$patch_file" ]] || die "Missing patch file: $patch_file"

# The reference file holds one "key value" pair per line; blank lines and
# lines starting with # are ignored. Unknown keys are errors, not typos to
# skip silently.
unexpected="$(awk '
  /^[[:space:]]*(#|$)/ { next }
  NF != 2 || $1 !~ /^(google-repository|google-tag|google-commit|base-repository|base-tag|base-commit|google-commits|whole-file)$/
' "$reference_file")"
[[ -z "$unexpected" ]] || die "Unexpected lines in $reference_file: $unexpected"

reference_values() {
  awk -v key="$1" '$1 == key { print $2 }' "$reference_file"
}

reference_value() {
  local key="$1" pattern="$2" values
  mapfile -t values < <(reference_values "$key")
  (( ${#values[@]} == 1 )) || die "$reference_file must set $key exactly once."
  [[ "${values[0]}" =~ $pattern ]] || die "$reference_file has an unexpected $key: ${values[0]}"
  printf '%s\n' "${values[0]}"
}

url_pattern='^(https|file)://[^[:space:]]+$'
tag_pattern='^[A-Za-z0-9][A-Za-z0-9._-]*$'
commit_pattern='^[0-9a-f]{40}$'
google_repository="$(reference_value google-repository "$url_pattern")"
google_tag="$(reference_value google-tag "$tag_pattern")"
google_commit="$(reference_value google-commit "$commit_pattern")"
base_repository="$(reference_value base-repository "$url_pattern")"
base_tag="$(reference_value base-tag "$tag_pattern")"
base_commit="$(reference_value base-commit "$commit_pattern")"
google_commits="$(reference_value google-commits '^[1-9][0-9]{0,3}$')"
mapfile -t whole_files < <(reference_values whole-file)
for path in "${whole_files[@]}"; do
  [[ "$path" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ && "$path" != *..* ]] ||
    die "$reference_file has an unexpected whole-file: $path"
done

patch_name="$(basename -- "$patch_file")"
[[ "$patch_name" =~ ^bbrv3-ubuntu-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*)\.patch$ ]] ||
  die "Cannot derive the Ubuntu source tag from $patch_name."
ubuntu_tag="Ubuntu-${BASH_REMATCH[1]}"
patch_path="$(cd -- "$(dirname -- "$patch_file")" && pwd)/$patch_name"
patch_sha256="$(sha256sum -- "$patch_path")"
patch_sha256="${patch_sha256%% *}"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

[[ -d "$git_dir/.git" ]] || git init --quiet "$git_dir"

# Pin every setting that changes diff output, whatever the local Git config.
g() {
  git -C "$git_dir" \
    -c core.quotePath=true \
    -c diff.algorithm=myers \
    -c diff.indentHeuristic=true \
    -c diff.interHunkContext=0 \
    -c diff.mnemonicPrefix=false \
    -c diff.noprefix=false \
    -c diff.relative=false \
    -c diff.renames=false \
    -c diff.suppressBlankEmpty=false \
    -c color.ui=never \
    "$@"
}
diff_options=(--no-color --no-ext-diff --no-textconv --no-renames -O/dev/null)

# Prints the commit a remote tag points at.
remote_tag_commit() {
  local repository="$1" tag="$2" refs
  refs="$(git ls-remote "$repository" "refs/tags/$tag" "refs/tags/$tag^{}")" ||
    die "Cannot list the tags of $repository."
  awk -v ref="refs/tags/$tag" '
    $2 == ref "^{}" { peeled = $1 }
    $2 == ref { direct = $1 }
    END { print (peeled != "" ? peeled : direct) }
  ' <<<"$refs"
}

[[ "$(remote_tag_commit "$google_repository" "$google_tag")" == "$google_commit" ]] ||
  die "$google_tag in $google_repository no longer points at $google_commit."
[[ "$(remote_tag_commit "$base_repository" "$base_tag")" == "$base_commit" ]] ||
  die "$base_tag in $base_repository does not point at $base_commit."

# Google's commits plus the base commit they sit on; the base tree comes with
# them, so the Linux release itself is never downloaded.
g fetch --quiet --no-tags --depth="$(( google_commits + 1 ))" "$google_repository" "$google_commit"
g cat-file -e "$google_commit^{commit}" || die "Could not fetch $google_commit."
[[ "$(g rev-parse --verify --quiet "$google_commit~$google_commits^{commit}" || true)" == "$base_commit" &&
  "$(g rev-list --count "$base_commit..$google_commit")" == "$google_commits" ]] ||
  die "$google_tag is not $base_tag plus $google_commits commits."

g fetch --quiet --no-tags --depth=1 "$ubuntu_repository" "+refs/tags/$ubuntu_tag:refs/tags/$ubuntu_tag"
ubuntu_commit="$(g rev-parse --verify "refs/tags/$ubuntu_tag^{commit}")"

# Apply the patch to an index built from the Ubuntu tag; no checkout needed.
export GIT_INDEX_FILE="$work/index"
g read-tree "$ubuntu_commit"
g apply --cached "$patch_path"
patched_tree="$(g write-tree)"
unset GIT_INDEX_FILE

g diff "${diff_options[@]}" -U0 "$base_commit" "$google_commit" > "$work/google.diff"
g diff "${diff_options[@]}" -U0 "$ubuntu_commit" "$patched_tree" > "$work/port.diff"
mapfile -t google_files < <(g diff "${diff_options[@]}" --name-only "$base_commit" "$google_commit")
mapfile -t port_files < <(g diff "${diff_options[@]}" --name-only "$ubuntu_commit" "$patched_tree")

# Succeeds when the first argument equals one of the others.
contains() {
  local wanted="$1" item
  shift
  for item in "$@"; do
    [[ "$item" != "$wanted" ]] || return 0
  done
  return 1
}

for path in "${whole_files[@]}"; do
  if ! contains "$path" "${google_files[@]}" || ! contains "$path" "${port_files[@]}"; then
    die "whole-file $path is not changed by both Google and the port."
  fi
done

# Parses both -U0 diffs, pairs up identical lines and writes the sections of
# the report that need the pairing. Per-file change listings go to $work for
# the ordered comparison.
analysis_program() {
  cat <<'AWK'
function fail(message) {
  printf "ERROR: %s\n", message > "/dev/stderr"
  failed = 1
  exit 1
}

function normalize(text) {
  gsub(/[ \t]+/, " ", text)
  sub(/^ /, "", text)
  sub(/ $/, "", text)
  return text
}

function start_file(line,   rest, half) {
  rest = substr(line, 12)
  if (index(rest, "\"") || substr(rest, 1, 2) != "a/")
    fail("unsupported file header: " line)
  half = (length(rest) - 1) / 2
  file = substr(rest, 3, half - 2)
  if (rest != "a/" file " b/" file)
    fail("unsupported file header: " line)
  touched[side, file] = 1
  if (!(file in known)) {
    known[file] = 1
    files[++file_count] = file
  }
  in_hunk = 0
}

function range_count(range,   comma) {
  range = substr(range, 2)
  comma = index(range, ",")
  return comma ? substr(range, comma + 1) + 0 : 1
}

function start_hunk(line,   rest, end_of_ranges, ranges, parts) {
  rest = substr(line, 4)
  end_of_ranges = index(rest, " @@")
  if (end_of_ranges == 0)
    fail("unsupported hunk header: " line)
  ranges = substr(rest, 1, end_of_ranges - 1)
  context = substr(rest, end_of_ranges + 3)
  sub(/^ /, "", context)
  if (split(ranges, parts, " ") != 2)
    fail("unsupported hunk header: " line)
  old_left = range_count(parts[1])
  new_left = range_count(parts[2])
  in_hunk = old_left > 0 || new_left > 0
}

function add_line(sign, text,   key) {
  key = normalize(text)
  if (key == "")
    return
  line_count++
  line_side[line_count] = side
  line_file[line_count] = file
  line_sign[line_count] = sign
  line_context[line_count] = context
  line_text[line_count] = text
  line_key[line_count] = key
  total[side, file, sign]++
  total[side, sign]++
}

function push(queue, key, value) {
  queue[key] = queue[key] " " value
}

function pop(queue, key,   rest, space, value) {
  if (!(key in queue) || queue[key] == "")
    return 0
  rest = substr(queue[key], 2)
  space = index(rest, " ")
  if (space) {
    value = substr(rest, 1, space - 1)
    queue[key] = substr(rest, space)
  } else {
    value = rest
    queue[key] = ""
  }
  return value + 0
}

function compared(i) {
  return !(line_file[i] in whole) && !(line_file[i] in created_only)
}

function counts(which, f, kind) {
  return sprintf("+%d -%d", tally[which, f, kind, "+"] + 0, tally[which, f, kind, "-"] + 0)
}

function print_unmatched(which, f, heading,   i, printed, last_context) {
  printed = 0
  last_context = SUBSEP
  for (i = 1; i <= line_count; i++) {
    if (line_side[i] != which || line_file[i] != f || (i in mate))
      continue
    if (!printed) {
      print "  " heading
      printed = 1
    }
    if (line_context[i] != last_context) {
      print "    @@ " line_context[i]
      last_context = line_context[i]
    }
    print "    " line_sign[i] line_text[i]
  }
}

{
  side = (FILENAME == google_diff) ? "G" : "P"
  line = $0
  if (in_hunk) {
    first = substr(line, 1, 1)
    if (first == "-" && old_left > 0) {
      old_left--
      add_line("-", substr(line, 2))
    } else if (first == "+" && new_left > 0) {
      new_left--
      add_line("+", substr(line, 2))
    } else if (first == " " && old_left > 0 && new_left > 0) {
      old_left--
      new_left--
    } else if (first != "\\") {
      fail("unexpected line in a hunk of " file ": " line)
    }
    if (old_left == 0 && new_left == 0)
      in_hunk = 0
    next
  }
  if (substr(line, 1, 11) == "diff --git ") { start_file(line); next }
  if (substr(line, 1, 3) == "@@ ") { start_hunk(line); next }
  if (line ~ /^new file mode /) { created[side, file] = 1; next }
  if (line ~ /^Binary files /) { binary[file] = 1; next }
  if (line ~ /^(index |old mode |new mode |deleted file mode |--- |\+\+\+ |\\ )/) next
  fail("unexpected diff line: " line)
}

END {
  if (failed)
    exit 1

  split(whole_files, parts, " ")
  for (i in parts)
    whole[parts[i]] = 1

  # Sort the file names; there are only a few dozen.
  for (i = 2; i <= file_count; i++) {
    name = files[i]
    for (j = i - 1; j >= 1 && files[j] > name; j--)
      files[j + 1] = files[j]
    files[j + 1] = name
  }

  # Files one side creates and the other does not touch are listed only.
  for (i = 1; i <= file_count; i++) {
    f = files[i]
    if (((("G", f) in created) && !(("P", f) in touched)) ||
        ((("P", f) in created) && !(("G", f) in touched)))
      created_only[f] = 1
  }

  # Pair identical lines within a file first, then across files.
  for (i = 1; i <= line_count; i++)
    if (line_side[i] == "P" && compared(i))
      push(same_file, line_file[i] SUBSEP line_sign[i] SUBSEP line_key[i], i)
  for (i = 1; i <= line_count; i++)
    if (line_side[i] == "G" && compared(i)) {
      j = pop(same_file, line_file[i] SUBSEP line_sign[i] SUBSEP line_key[i])
      if (j) {
        mate[i] = j
        mate[j] = i
      }
    }
  for (i = 1; i <= line_count; i++)
    if (line_side[i] == "P" && compared(i) && !(i in mate) && length(line_key[i]) >= min_moved)
      push(other_file, line_sign[i] SUBSEP line_key[i], i)
  for (i = 1; i <= line_count; i++)
    if (line_side[i] == "G" && compared(i) && !(i in mate) && length(line_key[i]) >= min_moved) {
      j = pop(other_file, line_sign[i] SUBSEP line_key[i])
      if (j) {
        mate[i] = j
        mate[j] = i
        pair = line_file[i] SUBSEP line_file[j]
        if (!(pair in moved)) {
          moved[pair] = 1
          moved_pairs[++moved_count] = pair
        }
        moved[pair, line_sign[i]]++
      }
    }

  for (i = 1; i <= line_count; i++) {
    if (!compared(i))
      kind = "all"
    else if (i in mate)
      kind = "matched"
    else
      kind = "only"
    tally[line_side[i], line_file[i], kind, line_sign[i]]++
    if (kind == "only")
      unmatched[line_side[i], line_sign[i]]++
  }

  width = 4
  for (i = 1; i <= file_count; i++)
    if (length(files[i]) > width)
      width = length(files[i])
  row = "%-" width "s  %-13s  %-13s  %-13s  %-13s  %s"

  printf "Files compared line by line: %d\n", \
    file_count - length_of(whole) - length_of(created_only) > summary_file
  printf "Lines only in Google's change: +%d -%d\n", \
    unmatched["G", "+"], unmatched["G", "-"] > summary_file
  printf "Lines only in the port: +%d -%d\n", \
    unmatched["P", "+"], unmatched["P", "-"] > summary_file
  close(summary_file)

  print "Files"
  print "-----"
  print "Non-blank changed lines per file. \"Only\" columns count lines without a"
  print "matching line in the other change, in the same file or another file."
  print ""
  print_row("File", "Google", "Port", "Only Google", "Only port", "Note")
  for (i = 1; i <= file_count; i++) {
    f = files[i]
    g_counts = sprintf("+%d -%d", total["G", f, "+"] + 0, total["G", f, "-"] + 0)
    p_counts = sprintf("+%d -%d", total["P", f, "+"] + 0, total["P", f, "-"] + 0)
    if (!(("G", f) in touched)) g_counts = "-"
    if (!(("P", f) in touched)) p_counts = "-"
    note = ""
    if (f in whole) {
      only_g = only_p = "-"
      note = "compared as a whole file below"
    } else if (f in created_only) {
      only_g = only_p = "-"
      note = (("G", f) in created) ? "created by Google, not in the port" : "created by the port, not by Google"
    } else {
      only_g = counts("G", f, "only")
      only_p = counts("P", f, "only")
    }
    if (f in binary)
      note = note (note == "" ? "" : "; ") "binary"
    print_row(f, g_counts, p_counts, only_g, only_p, note)
  }
  print ""

  print "Lines matched in another file"
  print "-----------------------------"
  if (moved_count == 0)
    print "None."
  for (i = 2; i <= moved_count; i++) {
    pair = moved_pairs[i]
    for (j = i - 1; j >= 1 && moved_pairs[j] > pair; j--)
      moved_pairs[j + 1] = moved_pairs[j]
    moved_pairs[j + 1] = pair
  }
  for (i = 1; i <= moved_count; i++) {
    split(moved_pairs[i], pair_files, SUBSEP)
    printf "%s (Google) -> %s (port): +%d -%d\n", pair_files[1], pair_files[2], \
      moved[moved_pairs[i], "+"] + 0, moved[moved_pairs[i], "-"] + 0
  }
  print ""

  print "Unmatched lines"
  print "---------------"
  print "Lines one change makes and the other does not, in diff order, under the"
  print "function Git names in each hunk header."
  any = 0
  for (i = 1; i <= file_count; i++) {
    f = files[i]
    if ((f in whole) || (f in created_only))
      continue
    if (tally["G", f, "only", "+"] + tally["G", f, "only", "-"] + tally["P", f, "only", "+"] + tally["P", f, "only", "-"] == 0)
      continue
    any = 1
    print ""
    print f
    print_unmatched("G", f, "Only in Google's change:")
    print_unmatched("P", f, "Only in the port:")
  }
  if (!any) {
    print ""
    print "None."
  }

  # Per-file listings for the ordered comparison.
  for (i = 1; i <= file_count; i++) {
    f = files[i]
    if ((f in whole) || (f in created_only))
      continue
    print i "\t" f > (listing_dir "/files")
    for (which = 1; which <= 2; which++) {
      s = which == 1 ? "G" : "P"
      out = listing_dir "/" s "-" i
      printf "" > out
      last_context = SUBSEP
      for (j = 1; j <= line_count; j++) {
        if (line_side[j] != s || line_file[j] != f)
          continue
        if (line_context[j] != last_context) {
          print "@@ " line_context[j] > out
          last_context = line_context[j]
        }
        print line_sign[j] line_text[j] > out
      }
      close(out)
    }
  }
}

function print_row(a, b, c, d, e, note,   text) {
  text = sprintf(row, a, b, c, d, e, note)
  sub(/ +$/, "", text)
  print text
}

function length_of(array,   key, n) {
  n = 0
  for (key in array)
    n++
  return n
}
AWK
}

mkdir -p -- "$work/listings"
awk -v google_diff="$work/google.diff" -v whole_files="${whole_files[*]}" -v min_moved=10 \
  -v listing_dir="$work/listings" -v summary_file="$work/summary.txt" \
  "$(analysis_program)" "$work/google.diff" "$work/port.diff" > "$work/analysis.txt"

{
  printf '%s\n' 'Google BBRv3 port audit'
  printf '%s\n' '======================='
  printf '\n'
  printf 'Patch: %s\n' "$patch_name"
  printf 'Patch SHA-256: %s\n' "$patch_sha256"
  printf 'Port base: %s %s\n' "$ubuntu_tag" "$ubuntu_commit"
  printf '  from %s\n' "$ubuntu_repository"
  printf 'Google reference: %s %s\n' "$google_tag" "$google_commit"
  printf '  from %s\n' "$google_repository"
  printf 'Google base: %s %s, %d commits below the reference\n' "$base_tag" "$base_commit" "$google_commits"
  printf '  from %s\n' "$base_repository"
  printf 'Files changed: %d by Google, %d by the port\n' "${#google_files[@]}" "${#port_files[@]}"
  cat -- "$work/summary.txt"
  for path in "${whole_files[@]}"; do
    added='' removed=''
    read -r added removed _ < <(
      g diff "${diff_options[@]}" --numstat "$google_commit" "$patched_tree" -- "$path"
    ) || true
    printf 'Whole file %s, port against Google: +%s -%s\n' "$path" "${added:-0}" "${removed:-0}"
  done
  printf '\n'
  printf '%s\n' 'Method'
  printf '%s\n' '------'
  printf '%s\n' "Google's change is the diff from $base_tag to $google_tag. The port's change"
  printf '%s\n' "is the diff from $ubuntu_tag to that tag with the patch applied. Both are"
  printf '%s\n' 'taken without context lines and compared line by line after collapsing'
  printf '%s\n' 'whitespace; blank lines are ignored. A line counts as matched when the'
  printf '%s\n' 'other change has the same line with the same sign in the same file, or'
  printf '%s\n' 'failing that, for lines of at least 10 characters, in another file. Files'
  printf '%s\n' 'one change creates and the other does not touch are listed, not compared.'
  printf '%s\n' 'Whole files are compared as final content, together with the Linux'
  printf '%s\n' 'changes to them between the two bases that the port had to carry over.'
  printf '\n'
  printf '%s\n' 'Google commits, oldest first'
  printf '%s\n' '----------------------------'
  g log --reverse --no-decorate --format='%H %s' "$base_commit..$google_commit" |
    awk '{ print substr($0, 1, 12) substr($0, 41) }'
  printf '\n'
  cat -- "$work/analysis.txt"
  for path in "${whole_files[@]}"; do
    printf '\n'
    printf 'Whole file: %s\n' "$path"
    printf '%s\n' '-------------------------------------------------------------------------'
    printf '%s\n' "The port's final file against Google's:"
    printf '\n'
    g diff "${diff_options[@]}" --full-index --src-prefix=google/ --dst-prefix=port/ \
      "$google_commit" "$patched_tree" -- "$path"
    printf '\n'
    printf '%s\n' "Linux changes to this file from $base_tag to $ubuntu_tag, which replacing"
    printf '%s\n' 'the file would drop unless the port carries them over:'
    printf '\n'
    g diff "${diff_options[@]}" --full-index --src-prefix="$base_tag/" --dst-prefix="$ubuntu_tag/" \
      "$base_commit" "$ubuntu_commit" -- "$path"
  done
  printf '\n'
  printf '%s\n' 'Changes in order'
  printf '%s\n' '----------------'
  printf '%s\n' "Each file's changed lines in diff order, Google's listing against the port's"
  printf '%s\n' '(whitespace-only differences ignored). Hunk headers name the function.'
  while IFS=$'\t' read -r index path; do
    status=0
    diff -U1 -b --label "google/$path" --label "port/$path" \
      "$work/listings/G-$index" "$work/listings/P-$index" > "$work/ordered.diff" || status=$?
    case "$status" in
      0) printf '\n%s: same changes in the same order\n' "$path" ;;
      1) printf '\n'; cat -- "$work/ordered.diff" ;;
      *) die "diff failed for $path." ;;
    esac
  done < "$work/listings/files"
} > "$work/report.txt"

mkdir -p -- "$(dirname -- "$report_file")"
mv -- "$work/report.txt" "$report_file"
sed '/^$/q' "$report_file"
