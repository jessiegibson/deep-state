#!/usr/bin/env bash
# Bulk-create the MeetingAgent backlog as GitHub issues on jessiegibson/deep-state.
#
# Why a script: the Cowork sandbox has no authenticated GitHub access. Run this on
# your Mac, where `gh` is installed and logged in.
#
# Prereqs:
#   brew install gh            # if not installed
#   gh auth login              # one time
#
# Usage:
#   bash scripts/create_github_issues.sh            # creates labels + issues
#   DRY_RUN=1 bash scripts/create_github_issues.sh  # print what would be created
#
set -euo pipefail

REPO="jessiegibson/deep-state"
DRY_RUN="${DRY_RUN:-0}"

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: $*"
  else
    "$@"
  fi
}

# --- Labels (idempotent: ignore "already exists" errors) -------------------
ensure_label() {
  local name="$1" color="$2" desc="$3"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: gh label create '$name' --color $color --description '$desc'"
    return
  fi
  gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" 2>/dev/null \
    || gh label edit "$name" --repo "$REPO" --color "$color" --description "$desc" 2>/dev/null \
    || true
}

ensure_label "feature"     "1d76db" "New user-facing capability"
ensure_label "tech-debt"   "fbca04" "Cleanup, refactor, or consistency fix"
ensure_label "testflight"  "0e8a16" "Blocks or supports a TestFlight release"
ensure_label "ios"         "5319e7" "iOS target parity work"
ensure_label "phase-5"     "c5def5" "Longer-term idea, not scheduled"

# --- Issues ----------------------------------------------------------------
# create_issue "title" "label" "body"
create_issue() {
  local title="$1" label="$2" body="$3"
  run gh issue create --repo "$REPO" --title "$title" --label "$label" --body "$body"
}

# Features not done
create_issue "2.2 Transcript editing before save" "feature" \
  "Add an in-line edit UI between transcription-complete and saveTranscript. TranscriptViewModel already exists; needs a sheet to edit before persisting."

create_issue "2.5 Language selection" "feature" \
  "WhisperKit supports language selection but no settings UI exposes it. Add a picker in settings and pass the choice through to the transcriber."

create_issue "3.4 Full-text search across saved transcripts" "feature" \
  "No search across saved transcripts today. First pass can be in-memory; see phase-5 SQLite FTS5 issue for the scalable version."

create_issue "4.2 Export formats (PDF, DOCX, SRT)" "feature" \
  "Transcripts are markdown only. Add export to PDF, DOCX, and SRT."

create_issue "4.3 Menu bar mode (NSStatusItem)" "feature" \
  "Add an NSStatusItem menu-bar mode for quick start/stop without the main window."

create_issue "4.4 App Store prep beyond TestFlight" "testflight" \
  "Privacy policy URL, screenshots, App Store description, and a final code-signing review before public release."

# Tech debt
create_issue "Reconcile bundle ID vs iCloud container name" "tech-debt" \
  "macOS bundle ID com.soloai.deepState does not match container iCloud.soloai.MeetingAgent. Works at runtime but reads as a mismatch. Pick a consistent naming and update entitlements + container."

create_issue "Reconcile CLAUDE.md with current project state" "tech-debt" \
  "CLAUDE.md lists an outdated bundle ID, references missing documentation/ files, and predates the refactor/structure reorganization. Update it."

create_issue "Decide on deep-state/ iOS target: parity or defer" "ios" \
  "iOS target lacks calendar, diarization, and labeling. Either bring to parity (EventKit works on iOS) or formally defer and document the decision."

create_issue "Expand unit test coverage on extracted units" "tech-debt" \
  "The Phase 2 refactor created testable units (AudioRecorder, ScreenRecorder, WhisperTranscriber, SummaryService). Add tests beyond the current four files."

# Phase 5 ideas
create_issue "5.1 SQLite FTS5 search index" "phase-5" "Scalable full-text search backing for 3.4."
create_issue "5.5 Meeting analytics dashboard" "phase-5" "Aggregate stats across recorded meetings."
create_issue "5.6 Obsidian export" "phase-5" "Export transcripts/summaries in an Obsidian-friendly format."
create_issue "5.7 Smart chapters via LLM" "phase-5" "Use the LLM to segment a transcript into chapters."
create_issue "5.8 Batch re-transcribe" "phase-5" "Re-run transcription across a batch of saved recordings."
create_issue "5.9 Webhook integration" "phase-5" "Fire webhooks on meeting save / summary complete."

echo "Done. Review issues at: https://github.com/$REPO/issues"
