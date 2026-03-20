#!/usr/bin/env bash
# project-watcher.sh — Background daemon: watch Project #2, auto-assign to idle oracle
#
# Start:  tmux new-session -d -s project-watcher 'bash scripts/project-watcher.sh'
# Stop:   tmux kill-session -t project-watcher
# Log:    cat /tmp/oracle-project-watcher.log
# Status: tmux attach -t project-watcher

set -uo pipefail

OWNER="allday9z"
PROJECT_NUM=2
REPO="allday9z/m2developer.com"
INTERVAL=300  # 5 minutes
MAW="/Users/uficon_dev/.bun/bin/maw"
SEEN_FILE="/tmp/oracle-project-watcher-seen.txt"
LOG_FILE="/tmp/oracle-project-watcher.log"

# ── Oracle priority list (first = highest priority) ─────────────────────────
# Format: "oracle-name|tmux-session"
ORACLE_FLEET=(
  "conductor|04-conductor"
  "m2manager|03-m2manager"
  "devops|07-devops"
  "database|05-database"
  "phukhao|01-phukhao"
  "opensourcenatbrain|02-opensourcenatbrain"
)

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

touch "$SEEN_FILE"

# ── Check if oracle is idle (not processing a task) ─────────────────────────
is_oracle_idle() {
  local session=$1
  # Capture last 3 lines of tmux pane
  local pane_content
  pane_content=$(tmux capture-pane -t "${session}:0" -p -S -3 2>/dev/null || echo "")

  # Idle = pane shows the "❯ " empty prompt (Claude waiting for input)
  # Busy = pane is actively streaming output (no empty prompt at end)
  if echo "$pane_content" | grep -q "^❯ $"; then
    return 0  # idle
  fi
  # Also check for separator line pattern (another idle indicator)
  if echo "$pane_content" | grep -q "^─────" && echo "$pane_content" | grep -q "❯"; then
    return 0  # idle
  fi
  return 1  # busy or unknown
}

# ── Find best available oracle based on priority ────────────────────────────
find_available_oracle() {
  log "   🔎 Checking oracle fleet availability..."
  for entry in "${ORACLE_FLEET[@]}"; do
    local name="${entry%%|*}"
    local session="${entry##*|}"

    # Check tmux session exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
      log "   ○ ${name} — session not found, skip"
      continue
    fi

    if is_oracle_idle "$session"; then
      log "   ✅ ${name} is IDLE → selected"
      echo "$name"
      return 0
    else
      log "   ⏳ ${name} is BUSY"
    fi
  done

  # All busy → fallback to conductor
  log "   ⚠️  All oracles busy → fallback to conductor"
  echo "conductor"
}

# ── Main loop ────────────────────────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "🔍 Oracle Project Watcher v2 — started"
log "📋 Project #${PROJECT_NUM} @ ${OWNER} | repo: ${REPO}"
log "🤖 Auto-assign to idle oracle via maw"
log "⏱  Interval: ${INTERVAL}s"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

while true; do
  log ""
  log "── Scan #$(date '+%H:%M') ──────────────────────────────"

  # ── 1. Fetch non-Done project items ────────────────────────────────────
  ITEMS_JSON=$(gh project item-list $PROJECT_NUM --owner "$OWNER" --format json --limit 100 2>/dev/null)
  [ -z "$ITEMS_JSON" ] && ITEMS_JSON='{"items":[]}'

  PENDING=$(echo "$ITEMS_JSON" | python3 - 2>/dev/null <<'PYEOF'
import json, sys
data = json.load(sys.stdin)
done = {"Done", "Closed", "Complete", "Completed"}
for item in data.get("items", []):
    if item.get("status", "") in done: continue
    repo = item.get("repository", "")
    if "allday9z/m2developer.com" not in repo: continue
    c = item.get("content", {})
    if c.get("type") != "Issue": continue
    print(f"{c['number']}|{c['title']}|{item.get('status','No Status')}")
PYEOF
)

  if [ -z "$PENDING" ]; then
    log "✅ No pending items — all clear"
    log "💤 Next scan in ${INTERVAL}s"
    sleep "$INTERVAL"
    continue
  fi

  NEW_COUNT=0
  while IFS='|' read -r NUM TITLE STATUS; do
    [ -z "$NUM" ] && continue

    # Already dispatched this session?
    if grep -q "^${NUM}$" "$SEEN_FILE" 2>/dev/null; then
      continue
    fi

    # Plan already exists?
    PLAN_COUNT=$(gh issue list \
      --repo "$REPO" \
      --search "plan: #${NUM} in:title" \
      --state open \
      --json number \
      --jq 'length' 2>/dev/null || echo "0")

    if [ "$PLAN_COUNT" -gt 0 ]; then
      echo "$NUM" >> "$SEEN_FILE"
      continue
    fi

    # ── NEW TASK DETECTED ──────────────────────────────────────────────
    log "📌 NEW: #${NUM} [${STATUS}] ${TITLE}"
    NEW_COUNT=$((NEW_COUNT + 1))

    # ── 2. Find idle oracle (priority check) ──────────────────────────
    TARGET_ORACLE=$(find_available_oracle)

    # ── 3. Dispatch via maw ────────────────────────────────────────────
    MSG="New task in Project #2: Issue #${NUM} — '${TITLE}' (status: ${STATUS}). Please run nnn #${NUM} to create a detailed implementation plan, then add it to Project #2 with label 'plan'. Repo: ${REPO}."

    log "   → Dispatching to: ${TARGET_ORACLE}"

    if $MAW hey "$TARGET_ORACLE" "$MSG" --force 2>/dev/null; then
      log "   ✅ Dispatched → ${TARGET_ORACLE}"
    else
      log "   ⚠️  maw failed → creating skeleton plan directly"
      PLAN_NUM=$(gh issue create \
        --repo "$REPO" \
        --title "plan: ${TITLE} (#${NUM})" \
        --label "plan" \
        --body "## Plan for #${NUM}

**Source**: #${NUM} — ${TITLE}
**Status**: ${STATUS}
**Auto-assigned**: ${TARGET_ORACLE} (unavailable — skeleton created)
**Detected**: $(date '+%Y-%m-%d %H:%M %Z')

- [ ] Analysis
- [ ] Implementation Steps
- [ ] Testing

*🤖 Oracle Project Watcher — run \`nnn #${NUM}\` to expand*" \
        --json number --jq '.number' 2>/dev/null || echo "")

      [ -n "$PLAN_NUM" ] && \
        gh project item-add $PROJECT_NUM --owner "$OWNER" \
          --url "https://github.com/${REPO}/issues/${PLAN_NUM}" 2>/dev/null || true
      [ -n "$PLAN_NUM" ] && log "   ✅ Skeleton plan #${PLAN_NUM} created"
    fi

    echo "$NUM" >> "$SEEN_FILE"
    log ""

  done <<< "$PENDING"

  [ "$NEW_COUNT" -eq 0 ] && log "✅ All items already planned"
  log "💤 Next scan in ${INTERVAL}s"
  sleep "$INTERVAL"
done
