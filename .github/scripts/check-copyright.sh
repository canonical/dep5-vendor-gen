#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks whether a committed debian/copyright file is up to date with what
# dep5-vendor-gen would generate from the current vendor tree(s).
#
# Inputs (environment variables, all set by action.yml):
#   COPYRIGHT_FILE     Path to the debian/copyright file to check.
#   WORKING_DIRECTORY  Directory to resolve COPYRIGHT_FILE and vendor dirs from.
#   VENDOR_DIRS        Space-separated vendor directories (may be empty to
#                       let dep5-vendor-gen auto-detect ./vendor*).
#   FAIL_ON_DIFF       "true"/"false" - whether to exit non-zero on a diff.
#   DEBUG              "true"/"false" - whether to pass --debug through.
#   DEP5_VENDOR_GEN    Path to the dep5-vendor-gen executable.
#   PUSH_FIX           "true"/"false" - opt-in fix mode: commit & push the
#                      regenerated file instead of (only) failing.
#   TOKEN              Token used to push the fix commit. Defaults to the
#                       workflow's GITHUB_TOKEN; a PAT/App token is
#                       recommended so the push retriggers workflows.
#   COMMIT_MESSAGE     Commit message for the fix commit.
#   COMMIT_USER_NAME    git user.name for the fix commit.
#   COMMIT_USER_EMAIL   git user.email for the fix commit.
#   GITHUB_EVENT_NAME   The triggering event name (push/pull_request/...).
#   GITHUB_REPOSITORY   "owner/repo" of the current repository (fork check).
#   PR_HEAD_REF         Branch name of the PR head (pull_request events).
#   PR_HEAD_REPO        "owner/repo" of the PR head repo (pull_request events).
#   PUSH_REF_NAME       Branch name for push events.
#
# Outputs (written to $GITHUB_OUTPUT):
#   up-to-date   "true" or "false"
#   diff         The unified diff (empty when up to date)
#   pushed       "true" if push-fix pushed a fix commit, "false" otherwise

set -euo pipefail

COPYRIGHT_FILE="${COPYRIGHT_FILE:-debian/copyright}"
WORKING_DIRECTORY="${WORKING_DIRECTORY:-.}"
VENDOR_DIRS="${VENDOR_DIRS:-}"
FAIL_ON_DIFF="${FAIL_ON_DIFF:-true}"
DEBUG="${DEBUG:-false}"
DEP5_VENDOR_GEN="${DEP5_VENDOR_GEN:?DEP5_VENDOR_GEN must be set}"
PUSH_FIX="${PUSH_FIX:-false}"
TOKEN="${TOKEN:-}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore: update debian/copyright via dep5-vendor-gen}"
COMMIT_USER_NAME="${COMMIT_USER_NAME:-github-actions[bot]}"
COMMIT_USER_EMAIL="${COMMIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
PR_HEAD_REF="${PR_HEAD_REF:-}"
PR_HEAD_REPO="${PR_HEAD_REPO:-}"
PUSH_REF_NAME="${PUSH_REF_NAME:-}"

cd "$WORKING_DIRECTORY"

debug_args=()
if [[ "$DEBUG" == "true" ]]; then
  debug_args+=(--debug)
fi

vendor_args=()
if [[ -n "$VENDOR_DIRS" ]]; then
  # shellcheck disable=SC2206 # intentional word-splitting of space-separated dirs
  vendor_args=($VENDOR_DIRS)
fi

tmp_copyright="$(mktemp)"
trap 'rm -f "$tmp_copyright"' EXIT

if [[ -f "$COPYRIGHT_FILE" ]]; then
  cp "$COPYRIGHT_FILE" "$tmp_copyright"
else
  echo "::warning::$COPYRIGHT_FILE does not exist yet; a fresh file will be generated for comparison"
  : > "$tmp_copyright"
fi

echo "Running dep5-vendor-gen against ${VENDOR_DIRS:-<auto-detected vendor dirs>}..."
"$DEP5_VENDOR_GEN" "${debug_args[@]}" --debian-copyright "$tmp_copyright" "${vendor_args[@]}"

diff_output=""
up_to_date=true
if [[ -f "$COPYRIGHT_FILE" ]]; then
  if ! diff_output="$(diff -u "$COPYRIGHT_FILE" "$tmp_copyright")"; then
    up_to_date=false
  fi
else
  # File did not exist before: everything generated is "new" from the diff's
  # point of view.
  diff_output="$(diff -u /dev/null "$tmp_copyright" || true)"
  up_to_date=false
fi

{
  echo "up-to-date=$up_to_date"
} >> "$GITHUB_OUTPUT"

{
  echo "diff<<DEP5_VENDOR_GEN_DIFF_EOF"
  echo "$diff_output"
  echo "DEP5_VENDOR_GEN_DIFF_EOF"
} >> "$GITHUB_OUTPUT"

if [[ "$up_to_date" == "true" ]]; then
  echo "pushed=false" >> "$GITHUB_OUTPUT"
  echo "✅ $COPYRIGHT_FILE is up to date." | tee -a "$GITHUB_STEP_SUMMARY"
  exit 0
fi

if [[ "$PUSH_FIX" == "true" ]]; then
  if [[ ("$GITHUB_EVENT_NAME" == "pull_request" || "$GITHUB_EVENT_NAME" == "pull_request_target") && -n "$PR_HEAD_REPO" && "$PR_HEAD_REPO" != "$GITHUB_REPOSITORY" ]]; then
    echo "::warning::push-fix is enabled, but this pull request is from fork '$PR_HEAD_REPO'; a token for this repository cannot push there. Falling back to the normal fail/warn behaviour."
  elif [[ -z "$TOKEN" ]]; then
    echo "::warning::push-fix is enabled, but no 'token' input was provided; skipping push and falling back to the normal fail/warn behaviour."
  else
    branch="$PUSH_REF_NAME"
    if [[ "$GITHUB_EVENT_NAME" == "pull_request" || "$GITHUB_EVENT_NAME" == "pull_request_target" ]]; then
      branch="$PR_HEAD_REF"
    fi

    if [[ -z "$branch" ]]; then
      echo "::warning::push-fix could not determine the branch to push to; skipping push and falling back to the normal fail/warn behaviour."
    else
      echo "Fetching and checking out branch '$branch' to push the fix commit..."
      git fetch --depth=1 origin "$branch"
      git checkout -B "$branch" "origin/$branch"

      # Regenerate the copyright file against the freshly checked-out revision
      # so the commit is never based on stale workspace output.
      : > "$tmp_copyright"
      if [[ -f "$COPYRIGHT_FILE" ]]; then
        cp "$COPYRIGHT_FILE" "$tmp_copyright"
      fi
      "$DEP5_VENDOR_GEN" "${debug_args[@]}" --debian-copyright "$tmp_copyright" "${vendor_args[@]}"

      mkdir -p "$(dirname "$COPYRIGHT_FILE")"
      cp "$tmp_copyright" "$COPYRIGHT_FILE"
      git add "$COPYRIGHT_FILE"

      git -c user.name="$COMMIT_USER_NAME" -c user.email="$COMMIT_USER_EMAIL" \
        commit -m "$COMMIT_MESSAGE"

      remote_url="$(git remote get-url origin)"
      push_url="$remote_url"
      if [[ "$remote_url" == https://* ]]; then
        push_url="${remote_url/https:\/\//https:\/\/x-access-token:${TOKEN}@}"
      fi

      if git push "$push_url" "HEAD:refs/heads/$branch"; then
        echo "pushed=true" >> "$GITHUB_OUTPUT"
        echo "✅ Pushed an updated $COPYRIGHT_FILE to '$branch'." | tee -a "$GITHUB_STEP_SUMMARY"
        exit 0
      else
        echo "::warning::push-fix failed to push the fix commit; falling back to the normal fail/warn behaviour."
      fi
    fi
  fi
fi

echo "pushed=false" >> "$GITHUB_OUTPUT"

{
  echo "## ❌ $COPYRIGHT_FILE is out of date"
  echo
  echo "Run \`dep5-vendor-gen ${VENDOR_DIRS}\` and commit the result."
  echo
  echo '```diff'
  echo "$diff_output"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

echo "$diff_output"

if [[ "$FAIL_ON_DIFF" == "true" ]]; then
  echo "::error file=${COPYRIGHT_FILE}::${COPYRIGHT_FILE} is out of date with the vendored dependencies. Run dep5-vendor-gen and commit the result."
  exit 1
fi

echo "::warning file=${COPYRIGHT_FILE}::${COPYRIGHT_FILE} is out of date with the vendored dependencies. Run dep5-vendor-gen and commit the result."
exit 0
