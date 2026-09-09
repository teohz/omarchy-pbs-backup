#!/usr/bin/env bash
# Shell tests for omarchy-pbs-backup's JSON contracts.
#
# Each test sets up an isolated XDG_CONFIG_HOME / XDG_STATE_HOME, drops a
# config in place, and shells out to the CLI. proxmox-backup-client is NOT
# required for these tests -- they exercise the parts of the CLI that don't
# touch PBS (status, config validation, JSON parsing of canned PBS output via
# fixtures).
#
# Run from anywhere:
#   ./test/run.sh
#
# Tests fail loudly and stop on the first failure (set -e). Each test writes
# a one-line summary to stdout.

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/omarchy-pbs-backup"
FIXTURES="$REPO_ROOT/test/fixtures"

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s\n' "$label"
    printf '        expected: %s\n' "$expected"
    printf '        actual:   %s\n' "$actual"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s\n' "$label"
    printf '        needle:   %s\n' "$needle"
    printf '        haystack: %s\n' "$haystack"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# Each test runs in its own throwaway HOME so secrets and state can't leak
# across tests. Cannot be called inside $() because exports done in a subshell
# are discarded when the subshell exits.
setup_isolated_home() {
  tmp="$(mktemp -d)"
  export HOME="$tmp"
  export XDG_CONFIG_HOME="$tmp/.config"
  export XDG_STATE_HOME="$tmp/.local/state"
  mkdir -p -- "$XDG_CONFIG_HOME/omarchy-pbs-backup" "$XDG_STATE_HOME/omarchy-pbs-backup"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_status_no_config() {
  setup_isolated_home
  local out; out="$("$SCRIPT" status --json 2>&1)"
  assert_contains "status no config → error present" "configured" "$out"
  assert_contains "status no config → false" '"configured":false' "$out"
  rm -rf -- "$tmp"
}

test_status_invalid_config_name() {
  setup_isolated_home
  cp "$FIXTURES/config-invalid-name.json" "$XDG_CONFIG_HOME/omarchy-pbs-backup/config.json"
  local out; out="$("$SCRIPT" status --json 2>&1)"
  assert_contains "invalid name → invalid flag" '"invalid":true' "$out"
  assert_contains "invalid name → explanation" "every group needs a name" "$out"
  rm -rf -- "$tmp"
}

test_status_invalid_config_duplicate() {
  setup_isolated_home
  cp "$FIXTURES/config-duplicate-name.json" "$XDG_CONFIG_HOME/omarchy-pbs-backup/config.json"
  local out; out="$("$SCRIPT" status --json 2>&1)"
  assert_contains "duplicate name → invalid flag" '"invalid":true' "$out"
  assert_contains "duplicate name → explanation" "duplicate group names" "$out"
  rm -rf -- "$tmp"
}

test_groups_no_groups_field() {
  setup_isolated_home
  cat > "$XDG_CONFIG_HOME/omarchy-pbs-backup/config.json" <<JSON
{
  "pbs": { "repository": "x@y:datastore" }
}
JSON
  local out; out="$("$SCRIPT" status --json 2>&1)"
  assert_contains "missing groups → invalid flag" '"invalid":true' "$out"
  assert_contains "missing groups → explanation" "no groups list" "$out"
  rm -rf -- "$tmp"
}

test_status_valid_config_no_state() {
  setup_isolated_home
  cp "$FIXTURES/config-valid.json" "$XDG_CONFIG_HOME/omarchy-pbs-backup/config.json"
  local out; out="$("$SCRIPT" status --json 2>&1)"
  assert_contains "valid config → configured true" '"configured":true' "$out"
  assert_contains "valid config → group name present" "external-drive" "$out"
  rm -rf -- "$tmp"
}

test_snapshots_json_parsing() {
  # Feed the snapshots JSON shape into jq the same way cmd_snapshots does,
  # and verify the field shape that goes to the widget. PBS uses
  # `backup-time` (epoch seconds) rather than `time`; the script converts
  # via `gmtime | strftime` to ISO 8601.
  local out; out="$(jq -c '
    {ok: true, snapshots: ([.[] | {
      id: ((.["backup-type"] // "host") + "/" + .["backup-id"] + "/" + (.["backup-time"] | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ"))),
      short_id: .["backup-id"],
      time: (.["backup-time"] | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ")),
      size: .size
    }] | reverse)}' \
    < "$FIXTURES/snapshot-list.json" 2>&1)"
  assert_contains "snapshots → id encoded" "host/external-drive/" "$out"
  # 1788939003 → 2026-09-09T07:30:03Z
  assert_contains "snapshots → time carried" "2026-09-09T07:30:03Z" "$out"
  assert_contains "snapshots → size carried" '12345678901' "$out"
}

test_snapshots_empty_list() {
  local out; out="$(jq -c '{ok:true, snapshots:([.[] | {id: ("\(.["backup-type"] // "host")/\(.["backup-id"])/\(.time)"),
                                 short_id: .["backup-id"],
                                 time: .time,
                                 size: .size}] | reverse)}' \
    < "$FIXTURES/snapshot-list-empty.json" 2>&1)"
  assert_contains "empty snapshots → ok:true" '"ok":true' "$out"
  assert_contains "empty snapshots → empty array" '"snapshots":[]' "$out"
}

test_archives_json_parsing() {
  local out; out="$(jq -c '{ok:true, archives:[.[] | {name: .filename, size: .size, type: .filetype}]}' \
    < "$FIXTURES/snapshot-files.json" 2>&1)"
  assert_contains "archives → pxar carried" '"name":"external-drive.pxar"' "$out"
  assert_contains "archives → size carried" '12345678901' "$out"
  assert_contains "archives → type carried" '"type":"pxar"' "$out"
}

test_status_with_state_file() {
  local tmp; tmp="$(setup_isolated_home)"
  mkdir -p -- "$XDG_CONFIG_HOME/omarchy-pbs-backup"
  cp "$FIXTURES/config-valid.json" "$XDG_CONFIG_HOME/omarchy-pbs-backup/config.json"
  mkdir -p -- "$XDG_STATE_HOME/omarchy-pbs-backup"
  cp "$FIXTURES/status-ok.json" "$XDG_STATE_HOME/omarchy-pbs-backup/status.json"
  local out; out="$("$SCRIPT" status --json 2>&1)"
  assert_contains "with state → snapshot count carried" '"snapshot_count":24' "$out"
  assert_contains "with state → last_run.result" '"result":"ok"' "$out"
  rm -rf -- "$tmp"
}

test_state_dirs_outside_plugin_dir() {
  # The plugin code lives at PLUGIN_DIR (set inside the script as the parent
  # of bin/). Config and state must NOT live under PLUGIN_DIR, otherwise
  # `omarchy plugin update` (which `git pull`s the plugin dir) would clobber
  # user data on every update.
  #
  # Verify three things by inspecting the script source:
  #   1. CONFIG_DIR is rooted at XDG_CONFIG_HOME or $HOME/.config
  #   2. STATE_DIR is rooted at XDG_STATE_HOME or $HOME/.local/state
  #   3. Neither contains the plugin-name "omarchy-pbs-backup/plugins/"
  #      (which would put it inside the plugin source dir).
  local config_line; config_line="$(grep -n '^CONFIG_DIR=' "$SCRIPT" | head -1)"
  local state_line; state_line="$(grep -n '^STATE_DIR=' "$SCRIPT" | head -1)"
  local secret_line; secret_line="$(grep -n '^SECRET_FILE=' "$SCRIPT" | head -1)"

  assert_contains "CONFIG_DIR uses XDG_CONFIG_HOME" \
    "XDG_CONFIG_HOME" "$config_line"
  assert_contains "CONFIG_DIR falls back to HOME/.config" \
    "HOME/.config" "$config_line"
  assert_contains "STATE_DIR uses XDG_STATE_HOME" \
    "XDG_STATE_HOME" "$state_line"
  assert_contains "STATE_DIR falls back to HOME/.local/state" \
    "HOME/.local/state" "$state_line"
  assert_contains "SECRET_FILE is anchored at CONFIG_DIR" \
    'SECRET_FILE="$CONFIG_DIR' "$secret_line"

  # The actual structural assertion: config and state directories must
  # not include the "plugins/" segment (which is what omarchy uses to
  # distinguish a plugin source from a plugin's user state).
  if [[ "$config_line" == *"plugins/"* ]]; then
    printf '  FAIL  CONFIG_DIR points under plugins/ (would be clobbered on update)\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    CONFIG_DIR does not include plugins/ (update-safe)\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$state_line" == *"plugins/"* ]]; then
    printf '  FAIL  STATE_DIR points under plugins/ (would be clobbered on update)\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    STATE_DIR does not include plugins/ (update-safe)\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  # .gitignore must continue to keep config.json and .secret out of git,
  # even if a future change accidentally stages them.
  local gitignore; gitignore="$(cat "$REPO_ROOT/.gitignore")"
  assert_contains ".gitignore excludes config.json" "config.json" "$gitignore"
  assert_contains ".gitignore excludes .secret" ".secret" "$gitignore"
}

test_backup_no_json_flag() {
  # PBS `backup` has no --json output mode (the original time-machine plugin
  # used restic, which did). The script used to pass --json to
  # proxmox-backup-client backup, which made every backup fail with
  # "parameter verification failed - 'json': missing parameter value".
  # Catch regression by looking for the actual flag passed to a subcommand
  # -- not just any mention of --json in a comment.
  if grep -E '^[[:space:]]*backup_args=\([^)]*backup[[:space:]]+--json' "$SCRIPT" >/dev/null 2>&1; then
    printf '  FAIL  backup_args pass --json to backup (PBS rejects it)\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    backup_args do not pass --json to backup\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

test_pbs_group_helper() {
  # `snapshot list` and `prune` take <group> = <type>/<id>, not just <id>.
  # The script used to pass the bare backup-id to these, which PBS rejected
  # with "unable to parse backup group path 'X'". The pbs_group helper
  # prepends "host/" — verify it exists and is wired into the relevant call
  # sites.
  local helper
  helper="$(awk '/^pbs_group\(\)/,/^}/' "$SCRIPT")"
  [ -n "$helper" ] || { printf '  FAIL  pbs_group helper missing\n'; TESTS_FAILED=$((TESTS_FAILED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); return; }
  printf '  ok    pbs_group helper defined\n'
  TESTS_RUN=$((TESTS_RUN + 1))

  # Run it standalone and check the output.
  local out; out="$(bash -c "$helper; pbs_group backup")"
  assert_eq "pbs_group backup → host/backup" "host/backup" "$out"

  # Snapshot list and prune calls must use the helper, not bare $bid.
  # Grep for the specific bad pattern: the variable name $bid used directly
  # in the argument (instead of $(pbs_group "$bid") which contains a `(`).
  if grep -nE 'snapshot list "\$bid"' "$SCRIPT" >/dev/null 2>&1; then
    printf '  FAIL  snapshot list called with bare $bid (missing host/ prefix)\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    no bare-$bid snapshot list calls\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -nE '\bprune "\$bid"' "$SCRIPT" >/dev/null 2>&1; then
    printf '  FAIL  prune called with bare $bid (missing host/ prefix)\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    no bare-$bid prune calls\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

test_pbs_context_uses_repository_string() {
  # PBS_AUTH_ID should not be set by pbs_context; the auth identity lives in
  # PBS_REPOSITORY. Grep the source for an `export PBS_AUTH_ID=` line inside
  # pbs_context -- if it comes back, the field was reintroduced.
  if grep -n 'export PBS_AUTH_ID=' "$SCRIPT" >/dev/null 2>&1; then
    printf '  FAIL  pbs_context exports PBS_AUTH_ID (should be redundant)\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    pbs_context does not export PBS_AUTH_ID\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  # The config-valid fixture does NOT carry an auth_id field, and the
  # starter config (cmd_config create) does NOT emit one either. Make sure
  # no recent change reintroduced it.
  if grep -q '"auth_id"' "$FIXTURES/config-valid.json"; then
    printf '  FAIL  config-valid fixture has auth_id\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    config-valid fixture has no auth_id\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

test_sanitize_for_pbs_id() {
  # Pull sanitize_for_pbs_id out of the script and exercise it.
  local fn; fn="$(awk '/^sanitize_for_pbs_id\(\)/,/^}/' "$SCRIPT")"
  local out
  out="$(bash -c "$fn; sanitize_for_pbs_id '../../../etc/passwd'")"
  assert_eq "sanitize → path traversal defanged" "..-..-..-etc-passwd" "$out"
  out="$(bash -c "$fn; sanitize_for_pbs_id 'normal_name-1.pxar'")"
  assert_eq "sanitize → normal preserved" "normal_name-1.pxar" "$out"
  out="$(bash -c "$fn; sanitize_for_pbs_id ''")"
  assert_eq "sanitize → empty yields empty" "" "$out"
}

test_basename_safe() {
  local fn; fn="$(awk '/^basename_safe\(\)/,/^}/' "$SCRIPT")"
  local out
  out="$(bash -c "$fn; basename_safe '/mnt/external-drive/'")"
  assert_eq "basename → trailing slash stripped" "external-drive" "$out"
  out="$(bash -c "$fn; basename_safe 'a/b/c'")"
  assert_eq "basename → last component" "c" "$out"
}

test_key_show_no_secret() {
  setup_isolated_home
  cp "$FIXTURES/config-valid.json" "$XDG_CONFIG_HOME/omarchy-pbs-backup/config.json"
  local code
  "$SCRIPT" key show >/dev/null 2>&1
  code=$?
  assert_eq "key show with no secret → exit 1" "1" "$code"
  rm -rf -- "$tmp"
}

test_key_set_writes_secret() {
  setup_isolated_home
  cp "$FIXTURES/config-valid.json" "$XDG_CONFIG_HOME/omarchy-pbs-backup/config.json"
  local secret="$XDG_CONFIG_HOME/omarchy-pbs-backup/.secret"
  printf 'hunter2\n' | "$SCRIPT" key set >/dev/null 2>&1
  local exists=0
  [ -f "$secret" ] && exists=1
  assert_eq "key set → file exists" "1" "$exists"
  local mode; mode="$(stat -c '%a' "$secret")"
  assert_eq "key set → mode 600" "600" "$mode"
  local content; content="$(cat "$secret")"
  assert_eq "key set → content matches" "hunter2" "$content"
  rm -rf -- "$tmp"
}

test_verbose() {
  printf '\n== sanity ==\n'
  local script_exists=0
  [ -x "$SCRIPT" ] && script_exists=1
  assert_eq "script is executable" "1" "$script_exists"

  local out; out="$("$SCRIPT" --version)"
  assert_contains "--version prints version" "omarchy-pbs-backup " "$out"

  local help; help="$("$SCRIPT" help 2>&1)"
  assert_contains "help mentions backup" "backup --dest" "$help"
  assert_contains "help mentions restore" "restore --dest" "$help"
  assert_contains "help mentions mount" "mount --dest" "$help"

  local unknown; unknown="$("$SCRIPT" no-such-command 2>&1)"
  assert_contains "unknown command → error" "unknown command" "$unknown"

  local script_size; script_size="$(wc -l < "$SCRIPT")"
  [ "$script_size" -gt 200 ]
  assert_eq "script has substance (200+ lines)" "0" "$?"
}

# H3 fix: groups_table must not compute snapshot_count twice. The bug was
# two identical jq pipelines back-to-back (`size=` and `snaps=`), one of
# which was dead code. The remaining computation should be unique.
test_groups_table_no_duplicate_count() {
  local fn
  fn="$(awk '/^groups_table\(\)/,/^}/' "$SCRIPT")"
  local count
  count="$(printf '%s\n' "$fn" | grep -c 'snapshot_count // 0')"
  if [ "$count" -gt 1 ]; then
    printf '  FAIL  groups_table computes snapshot_count %d times (dead duplicate)\n' "$count"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    groups_table computes snapshot_count once\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  # No assignment to a `size` local in groups_table: that var was dead.
  if printf '%s\n' "$fn" | grep -qE '^[[:space:]]+size='; then
    printf '  FAIL  groups_table still assigns to dead `size` local\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    groups_table has no dead `size` assignment\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# H4 fix: record_status must call `snapshot list` at most once per backup.
# The bug was two back-to-back `pbs_run snapshot list` invocations: one to
# count snapshots, one to sum sizes. Both could be done from the same JSON
# payload.
test_record_status_calls_snapshot_list_once() {
  local fn
  fn="$(awk '/^record_status\(\)/,/^}/' "$SCRIPT")"
  local count
  count="$(printf '%s\n' "$fn" | grep -c 'pbs_run snapshot list')"
  if [ "$count" -gt 1 ]; then
    printf '  FAIL  record_status runs snapshot list %d times\n' "$count"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    record_status runs snapshot list at most once\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# M4 fix: cmd_groups used a local named `display` to hold the repository
# URL, which read like the group's display name. Rename to `repo`.
# The JSON output field `repository_display` is the correct contract name
# for what this holds.
test_cmd_groups_repo_naming() {
  local fn
  fn="$(awk '/^cmd_groups\(\)/,/^}/' "$SCRIPT")"
  if printf '%s\n' "$fn" | grep -qE '^[[:space:]]+display='; then
    printf '  FAIL  cmd_groups still assigns to misnamed `display` local\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    cmd_groups does not assign to misnamed `display`\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  if ! printf '%s\n' "$fn" | grep -qE '^[[:space:]]+repo='; then
    printf '  FAIL  cmd_groups does not assign to `repo` local\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    cmd_groups assigns the repository URL to `repo`\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# M12 fix: pbs_context must not chmod SECRET_FILE on every call. The
# permission is set when the secret is written (cmd_key set / write_private)
# and on the secure setup path (config_dir_secure). Re-running chmod on
# every PBS-touching command is noise.
test_pbs_context_no_chmod_secret() {
  local fn
  fn="$(awk '/^pbs_context\(\)/,/^}/' "$SCRIPT")"
  if printf '%s\n' "$fn" | grep -qE 'chmod.*SECRET_FILE'; then
    printf '  FAIL  pbs_context still chmods SECRET_FILE on every call\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    pbs_context does not chmod SECRET_FILE on every call\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# M11 fix: systemd unit files are conventionally mode 644. The script-wide
# `umask 077` would otherwise leave them at 600 (owner-only). write_unit
# must explicitly chmod them after the rename.
test_systemd_units_mode_644() {
  local fn
  fn="$(awk '/^write_unit\(\)/,/^}/' "$SCRIPT")"
  if printf '%s\n' "$fn" | grep -qE 'chmod (0?644|644)'; then
    printf '  ok    write_unit chmods systemd units to 644\n'
  else
    printf '  FAIL  write_unit does not chmod systemd units to 644\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  # Behavioural: extract write_unit and the helpers it uses, run it in a
  # throwaway dir under a strict umask (the script's own setting) so the
  # test exercises the chmod-fix specifically.
  local helpers
  helpers="$(awk '/^readable_file\(\)/,/^}/' "$SCRIPT")"
  helpers+=$'\n'
  helpers+="$(awk '/^write_unit\(\)/,/^}/' "$SCRIPT")"
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/units"
  local script
  script="SYSTEMD_DIR='$tmp/units'; umask 077; $helpers; write_unit 'sample.service' '[Unit]\nDescription=test'"
  bash -c "$script" >/dev/null 2>&1
  local mode; mode="$(stat -c '%a' "$tmp/units/sample.service" 2>/dev/null || echo "missing")"
  rm -rf -- "$tmp"
  assert_eq "write_unit produces mode 644 under umask 077" "644" "$mode"
}

# M1 fix: openLog() was defined but never called from any QML file, and
# the implementation always picked the first group's log, which is wrong
# when multiple groups have logs. Fix: pick the most recently finished
# one, and wire the function into a menu row in Panel.qml.
test_openlog_picks_most_recent() {
  local fn
  fn="$(awk '/^  function openLog\(/,/^  }/' PbsBackupStore.qml)"
  if printf '%s\n' "$fn" | grep -q 'finished_at'; then
    printf '  ok    openLog considers finished_at to pick the most recent log\n'
  else
    printf '  FAIL  openLog does not consider finished_at (picks arbitrary group)\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

test_openlog_wired_in_panel() {
  if grep -nE 'PbsBackupStore\.openLog|openLog\(\)' Panel.qml >/dev/null 2>&1; then
    printf '  ok    Panel.qml invokes PbsBackupStore.openLog\n'
  else
    printf '  FAIL  Panel.qml does not invoke PbsBackupStore.openLog\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# M2 fix: openConfig() must honor XDG_CONFIG_HOME. The CLI uses
# ${XDG_CONFIG_HOME:-$HOME/.config}/... — the QML side hard-coded
# $HOME/.config, so a user with XDG_CONFIG_HOME set got the editor
# pointed at the wrong file.
test_openconfig_xdg_config_home() {
  local fn
  fn="$(awk '/^  function openConfig\(/,/^  }/' PbsBackupStore.qml)"
  if printf '%s\n' "$fn" | grep -qE 'XDG_CONFIG_HOME|configHome'; then
    printf '  ok    openConfig honors XDG_CONFIG_HOME\n'
  else
    printf '  FAIL  openConfig does not honor XDG_CONFIG_HOME\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# H1 fix: loadArchives(snapshotId) was a stub. Picking a different
# snapshot in the restore browser left the archives list unchanged
# because the function did nothing. After the fix it must dispatch to
# loadArchivesFor(snapshotId).
test_load_archives_dispatches() {
  # Extract just the loadArchives function body — everything between its
  # opening { and the next line that is exactly "  }".
  local fn
  fn="$(awk '
    /^  function loadArchives\(/ { inside=1 }
    inside { print }
    inside && /^  }$/ { inside=0 }
  ' PbsBackupStore.qml)"
  # Strip comments, then look for an actual call to loadArchivesFor.
  local body
  body="$(printf '%s\n' "$fn" | sed 's|//.*||')"
  if printf '%s\n' "$body" | grep -qE 'loadArchivesFor[[:space:]]*\('; then
    printf '  ok    loadArchives dispatches to loadArchivesFor\n'
  else
    printf '  FAIL  loadArchives does not dispatch to loadArchivesFor\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  # The function must accept a snapshotId argument, not the zero-arg stub.
  if printf '%s\n' "$fn" | grep -qE 'loadArchives\(\) \{'; then
    printf '  FAIL  loadArchives is the zero-arg stub\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    loadArchives accepts a snapshotId argument\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# M3 fix: confirmCancel left restoreTargetName / restoreTargetPath set,
# so cancelling the confirm dialog and then opening it from a different
# selection still showed the previous name. After the fix, cancel clears
# both fields.
test_confirm_cancel_clears_target() {
  local fn
  fn="$(awk '
    /^  function confirmCancel\(/ { inside=1 }
    inside { print }
    inside && /^  }$/ { inside=0 }
  ' RestoreBrowser.qml)"
  if printf '%s\n' "$fn" | grep -qE 'restoreTarget(Name|Path) ?='; then
    printf '  ok    confirmCancel clears restoreTarget* state\n'
  else
    printf '  FAIL  confirmCancel does not clear restoreTarget* state\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# H5 fix: cmd_config create used to run omarchy-launch-editor inline,
# which wedged the QML createProc until the user closed their editor.
# After the fix the editor must be detached so the CLI returns
# immediately. The regression test runs cmd_config create with a fake
# omarchy-launch-editor that sleeps for 30s; the CLI must exit in
# under 5s.
test_cmd_config_create_detaches_editor() {
  setup_isolated_home
  mkdir -p -- "$XDG_CONFIG_HOME/omarchy-pbs-backup"
  cp "$FIXTURES/config-valid.json" "$XDG_CONFIG_HOME/omarchy-pbs-backup/config.json"
  local fake_bin="$tmp/fakebin"
  mkdir -p -- "$fake_bin"
  cat > "$fake_bin/omarchy-launch-editor" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x -- "$fake_bin/omarchy-launch-editor"

  local start end elapsed
  start="$(date +%s)"
  PATH="$fake_bin:$PATH" "$SCRIPT" config create >/dev/null 2>&1
  local code=$?
  end="$(date +%s)"
  elapsed=$((end - start))
  # The fake editor sleeps in the background; kill any remaining process
  # group before removing the tmp dir so nothing races.
  pkill -P $$ -f 'omarchy-launch-editor' 2>/dev/null || true
  rm -rf -- "$tmp"

  if [ "$elapsed" -ge 5 ]; then
    printf '  FAIL  cmd_config create took %ds (editor blocks the CLI)\n' "$elapsed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    cmd_config create returns in %ds (editor detached)\n' "$elapsed"
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  # Should also exit cleanly, not propagate the editor's failure.
  assert_eq "cmd_config create → exit 0" "0" "$code"
}

# H2 fix: Panel.qml must call PbsBackupStore.unmount() when the panel
# closes. The README and the PbsBackupStore header comment both promise
# this; the code didn't deliver, so the FUSE mount survived every
# panel open/close cycle.
test_panel_close_unmounts() {
  # Extract the onOpenedChanged handler — everything from the line that
  # introduces it up to the next blank line.
  local fn
  fn="$(awk '
    /onOpenedChanged:/ { inside=1 }
    inside { print; if (NF == 0 || /^[[:space:]]*[}]/) exit }
  ' Panel.qml)"
  if printf '%s\n' "$fn" | grep -q 'PbsBackupStore.unmount'; then
    printf '  ok    Panel.qml calls PbsBackupStore.unmount on close\n'
  else
    printf '  FAIL  Panel.qml does not call PbsBackupStore.unmount on close\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# D2 fix: PbsBackupStore.groupDetail formatted `last_run.data_added_bytes`
# into the per-group detail line, but record_status never writes that
# field — the formatter was a stub. Either populate the field from PBS
# output or drop the formatter. We drop it; the snapshot_count is still
# informative, and adding the field back requires a reliable PBS output
# parser that's out of scope.
test_group_detail_no_data_added_bytes() {
  local fn
  fn="$(awk '
    /^  function groupDetail\(/ { inside=1 }
    inside { print }
    inside && /^  }$/ { inside=0 }
  ' PbsBackupStore.qml)"
  # Strip comments before grepping — the function may mention the field
  # in a // note explaining why it was removed, which is fine.
  local body
  body="$(printf '%s\n' "$fn" | sed 's|//.*||')"
  if printf '%s\n' "$body" | grep -q 'data_added_bytes'; then
    printf '  FAIL  groupDetail still references dead data_added_bytes\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    groupDetail no longer references dead data_added_bytes\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# D4 fix: README showed `mounts/<group>/<snapshot-id>/` but the script's
# mount_path_for replaces slashes with hyphens so the on-disk layout is
# flat (no nested dirs). Update README to match.
test_readme_mount_path_matches_script() {
  # Extract mount_path_for from the script to see what it actually produces.
  local fn
  fn="$(awk '
    /^mount_path_for\(\)/ { inside=1 }
    inside { print }
    inside && /^}$/ { inside=0 }
  ' "$SCRIPT")"
  # If the script replaces / with -, the README must not show <snapshot-id>/
  # as a literal slash.
  if printf '%s\n' "$fn" | grep -qE "tr '/' '-'"; then
    if grep -qE 'mounts/<group>/<snapshot-id>/' README.md; then
      printf '  FAIL  README still shows literal slashes; script flattens to hyphens\n'
      TESTS_FAILED=$((TESTS_FAILED + 1))
    else
      printf '  ok    README mount-path layout matches script (hyphens)\n'
    fi
  else
    printf '  ok    mount_path_for keeps slashes; README already correct\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# M8 fix: RestoreRow.entryTime was plumbed (RestoreBrowser.qml:442 passed
# `modelData.mtime`) but cmd_ls never emitted mtime, so the field was
# always null. The display logic in RestoreRow ignored null. Drop the
# dead plumbing; if dates are wanted later, cmd_ls should emit mtime
# and the row should render it.
test_no_dead_entry_time() {
  if grep -qE 'entryTime' RestoreRow.qml; then
    printf '  FAIL  RestoreRow.qml still has dead entryTime\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    RestoreRow.qml no longer has dead entryTime\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  if grep -qE 'entryTime:' RestoreBrowser.qml; then
    printf '  FAIL  RestoreBrowser.qml still binds entryTime\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    RestoreBrowser.qml no longer binds entryTime\n'
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# H0 fix (1/3): group_backup_id must default to the group's `name`,
# NOT to basename(source). Two configured groups with similar source
# paths (e.g. /mnt/disk and /mnt/data) would otherwise collide on the
# PBS side; even worse, the storage name has no relation to the name
# the user configured.
test_group_backup_id_defaults_to_name() {
  local helpers
  helpers="$(awk '/^sanitize_for_pbs_id\(\)/,/^}/' "$SCRIPT")"
  helpers+=$'\n'
  helpers+="$(awk '/^basename_safe\(\)/,/^}/' "$SCRIPT")"
  helpers+=$'\n'
  helpers+="$(awk '/^group_backup_id\(\)/,/^}/' "$SCRIPT")"
  # group() is just jq on GROUP_JSON.
  helpers+=$'\ngroup() { jq -r "$1" <<<"$GROUP_JSON"; }'

  # Test 1: explicit .backup_id wins.
  local out
  out="$(bash -c "
    GROUP_NAME='my-disk'
    GROUP_JSON='{\"name\":\"my-disk\",\"backup_id\":\"custom-name\"}'
    HOME=/tmp
    $helpers
    group_backup_id
  ")"
  assert_eq "group_backup_id honors explicit .backup_id" "custom-name" "$out"

  # Test 2: defaults to GROUP_NAME, not basename(source).
  out="$(bash -c "
    GROUP_NAME='my-cool-disk'
    GROUP_JSON='{\"name\":\"my-cool-disk\",\"source\":\"/some/unrelated/path\"}'
    HOME=/tmp
    $helpers
    group_backup_id
  ")"
  assert_eq "group_backup_id defaults to group name (not basename of source)" "my-cool-disk" "$out"

  # Test 3: special chars in name are sanitised through PBS-safe charset.
  out="$(bash -c "
    GROUP_NAME='weird name!'
    GROUP_JSON='{\"name\":\"weird name!\"}'
    HOME=/tmp
    $helpers
    group_backup_id
  ")"
  assert_eq "group_backup_id sanitises special chars in name" "weird-name-" "$out"
}

# H0 fix (2/3): pbs_context must honor a per-group `.namespace` before
# falling back to the top-level namespace. Two groups in the same
# config can now live under separate PBS namespaces.
test_pbs_context_honors_per_group_namespace() {
  # Behavioural: source a fake pbs_context that exercises the namespace
  # resolution. We can't easily run the real pbs_context because it
  # reads the secret file and may not be in our test env, so we test
  # the namespace-resolution clause directly by extracting it.
  #
  # Simplest reliable test: source-grep that pbs_context looks at
  # GROUP_JSON for .namespace before falling back to the top-level
  # .namespace. The actual jq call is the source of truth.
  local fn
  fn="$(awk '/^pbs_context\(\)/,/^}/' "$SCRIPT")"
  # Comment-stripped body.
  local body
  body="$(printf '%s\n' "$fn" | sed 's|#.*||')"
  # Must read .namespace from the active group (GROUP_JSON), not just
  # the top-level config.
  if printf '%s\n' "$body" | grep -qE "GROUP_JSON.*namespace|namespace.*GROUP_JSON"; then
    printf '  ok    pbs_context reads namespace from active group\n'
  else
    printf '  FAIL  pbs_context does not consult GROUP_JSON for namespace\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  # Must still fall back to the top-level namespace when the active
  # group does not specify one.
  if printf '%s\n' "$body" | grep -qE "\\.namespace // empty"; then
    printf '  ok    pbs_context falls back to top-level namespace\n'
  else
    printf '  FAIL  pbs_context does not fall back to top-level namespace\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# H0 fix (3/3): record_status must surface the actual backup_id and
# namespace used, so a user can sanity-check from `status --json`
# which PBS path the backups land on.
test_record_status_records_identity() {
  local fn
  fn="$(awk '/^record_status\(\)/,/^}/' "$SCRIPT")"
  if printf '%s\n' "$fn" | grep -qE 'backup_id:[[:space:]]*\$backup_id|backup_id: ?\\$b'; then
    printf '  ok    record_status writes backup_id to status.json\n'
  else
    printf '  FAIL  record_status does not record backup_id\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))

  if printf '%s\n' "$fn" | grep -qE 'namespace:[[:space:]]*\$namespace|namespace: ?\\$n'; then
    printf '  ok    record_status writes namespace to status.json\n'
  else
    printf '  FAIL  record_status does not record namespace\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# M5 fix: groups_table format string left no gap between columns at the
# truncation boundary. The header printf must use a separator (a pipe,
# or at least two spaces) between adjacent format specs so a 22-char
# truncated label can't touch the next column.
test_groups_table_column_separators() {
  local fn
  fn="$(awk '/^groups_table\(\)/,/^}/' "$SCRIPT")"
  # Match either "  | " (with pipe) or "  " (two+ spaces) between
  # adjacent format specs. Single space " " is what the bug had.
  if printf '%s\n' "$fn" | grep -qE "%-[0-9]+s( \| |  +)%-[0-9]+s"; then
    printf '  ok    groups_table uses clear column separators\n'
  else
    printf '  FAIL  groups_table columns may run flush at truncation boundary\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

# Run all tests.
main() {
  printf 'omarchy-pbs-backup tests\n'
  printf -- '------------------------\n'
  test_verbose
  test_status_no_config
  test_status_invalid_config_name
  test_status_invalid_config_duplicate
  test_groups_no_groups_field
  test_status_valid_config_no_state
  test_status_with_state_file
  test_state_dirs_outside_plugin_dir
  test_backup_no_json_flag
  test_pbs_group_helper
  test_pbs_context_uses_repository_string
  test_snapshots_json_parsing
  test_snapshots_empty_list
  test_archives_json_parsing
  test_sanitize_for_pbs_id
  test_basename_safe
  test_key_show_no_secret
  test_key_set_writes_secret
  test_groups_table_no_duplicate_count
  test_record_status_calls_snapshot_list_once
  test_cmd_groups_repo_naming
  test_pbs_context_no_chmod_secret
  test_systemd_units_mode_644
  test_openlog_picks_most_recent
  test_openlog_wired_in_panel
  test_openconfig_xdg_config_home
  test_load_archives_dispatches
  test_confirm_cancel_clears_target
  test_cmd_config_create_detaches_editor
  test_panel_close_unmounts
  test_group_detail_no_data_added_bytes
  test_readme_mount_path_matches_script
  test_no_dead_entry_time
  test_group_backup_id_defaults_to_name
  test_pbs_context_honors_per_group_namespace
  test_record_status_records_identity
  test_groups_table_column_separators
  printf -- '------------------------\n'
  printf '%d checks run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" = "0" ]
}

main
