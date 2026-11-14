#!/usr/bin/env bash
# Install herdr-multi-agent-setup (the Lead + Engineer/Reviewer pairs) into $HOME.
# Usage: ./install.sh [--rc <shell-rc-file>]
# Env:   HERDR_SETUP_SKIP_RELOAD=1  skip the herdr config reload step
#
# Manifest (~/.local/share/herdr-multi-agent-setup/manifest), tab-separated lines:
#   orig   <dest> absent|keep|<backup>  state of <dest> before the FIRST install
#                                       (written once, never changed)
#   backup <dest> <backup>              later safety backups, oldest first
#   sha    <dest> <sha256>              hash of what install last wrote (latest wins)
#   dir    <path>                       directory created by install
#   rc     <file>                       rc file holding the managed block
#   rcnew  <file>                       rc file created by install
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEGIN_MARK="# >>> herdr-multi-agent-setup >>>"
END_MARK="# <<< herdr-multi-agent-setup <<<"
TAB=$'\t'

RC_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rc)
      [ $# -ge 2 ] || { echo "install: --rc needs a file argument" >&2; exit 2; }
      RC_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ./install.sh [--rc <shell-rc-file>]"; exit 0 ;;
    *)
      echo "install: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$RC_FILE" ]; then
  case "${SHELL:-}" in
    */zsh) RC_FILE="$HOME/.zshrc" ;;
    *)     RC_FILE="$HOME/.bashrc" ;;
  esac
fi

MANIFEST_DIR="$HOME/.local/share/herdr-multi-agent-setup"
MANIFEST="$MANIFEST_DIR/manifest"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HAVE_HERDR=0; HAVE_CLAUDE=0
command -v herdr  >/dev/null 2>&1 && HAVE_HERDR=1
command -v claude >/dev/null 2>&1 && HAVE_CLAUDE=1
[ "$HAVE_HERDR"  -eq 1 ] || echo "warning: 'herdr' not found on PATH (see https://herdr.dev)" >&2
[ "$HAVE_CLAUDE" -eq 1 ] || echo "warning: 'claude' (Claude Code CLI) not found on PATH" >&2

# Append a manifest line (tab-separated fields) unless it is already present.
record() {
  local line
  line="$(printf '%s\t' "$@")"
  line="${line%"$TAB"}"
  grep -Fxq -- "$line" "$MANIFEST" || printf '%s\n' "$line" >> "$MANIFEST"
}

# make_dir <path>: create <path> and any missing parents, printing each
# directory it creates (parents first).
make_dir() {
  local d="$1"
  [ -d "$d" ] && return 0
  make_dir "$(dirname "$d")"
  mkdir "$d"
  printf '%s\n' "$d"
}

# ensure_dir <path>: make_dir + record created directories in the manifest.
ensure_dir() {
  local d
  make_dir "$1" > "$TMP_DIR/newdirs"
  while IFS= read -r d; do
    record dir "$d"
  done < "$TMP_DIR/newdirs"
}

# The manifest directory must exist before anything can be recorded.
make_dir "$MANIFEST_DIR" > "$TMP_DIR/manifest_dirs"
touch "$MANIFEST"
while IFS= read -r d; do record dir "$d"; done < "$TMP_DIR/manifest_dirs"

has_orig() {
  D="$1" awk -F'\t' '$1 == "orig" && $2 == ENVIRON["D"] { found = 1 } END { exit !found }' "$MANIFEST"
}

# manifest_value <type> <dest>: field 3 of the last <type> line for <dest>.
manifest_value() {
  T="$1" D="$2" awk -F'\t' '$1 == ENVIRON["T"] && $2 == ENVIRON["D"] { v = $3 } END { print v }' "$MANIFEST"
}

# backup_path <dest>: unused "<dest>.bak.<stamp>[.N]" path.
backup_path() {
  local b="$1.bak.$STAMP" n=1
  while [ -e "$b" ] || [ -L "$b" ]; do
    b="$1.bak.$STAMP.$n"
    n=$((n + 1))
  done
  printf '%s\n' "$b"
}

# file_sha <file>: SHA-256 of a file's content.
file_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | cut -d' ' -f1
  else
    sha256sum < "$1" | cut -d' ' -f1
  fi
}

# set_sha <dest>: replace the sha line for <dest> with the hash of its content now.
set_sha() {
  local dest="$1" sum
  sum="$(file_sha "$dest")"
  D="$dest" awk -F'\t' '!($1 == "sha" && $2 == ENVIRON["D"])' "$MANIFEST" > "$TMP_DIR/manifest.new"
  printf 'sha\t%s\t%s\n' "$dest" "$sum" >> "$TMP_DIR/manifest.new"
  cat "$TMP_DIR/manifest.new" > "$MANIFEST"
}

# install_file <source> <dest> <mode>
# Records the destination's pre-install state once (orig line), backs up
# differing files, and skips identical ones (re-runs create no new backups).
install_file() {
  local src="$1" dest="$2" mode="$3" backup first=1
  has_orig "$dest" && first=0
  ensure_dir "$(dirname "$dest")"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if cmp -s "$src" "$dest"; then
      [ "$first" -eq 1 ] && record orig "$dest" keep
      if [ "$(manifest_value orig "$dest")" = "keep" ]; then
        # The user's own pre-existing file: never change its mode.
        if [ "$mode" = "755" ] && [ ! -x "$dest" ]; then
          echo "warning: $dest is not executable; left as is (it existed before install)" >&2
        fi
      else
        chmod "$mode" "$dest"
      fi
      set_sha "$dest"
      echo "unchanged: $dest"
      return 0
    fi
    # Re-install over our own unedited output: nothing of the user's to save,
    # so skip the safety backup. Not for orig=keep files: there the first
    # safety backup is the user's own content, which uninstall restores.
    if [ "$first" -eq 0 ] && [ "$(manifest_value orig "$dest")" != "keep" ] &&
       [ "$(file_sha "$dest")" = "$(manifest_value sha "$dest")" ]; then
      echo "replacing: $dest (unedited previous install; no backup needed)"
    else
      backup="$(backup_path "$dest")"
      cp -p "$dest" "$backup"
      if [ "$first" -eq 1 ]; then
        record orig "$dest" "$backup"
      else
        record backup "$dest" "$backup"
      fi
      echo "backed up: $dest -> $backup"
    fi
  else
    [ "$first" -eq 1 ] && record orig "$dest" absent
  fi
  cp "$src" "$dest.tmp.$$"
  chmod "$mode" "$dest.tmp.$$"
  mv -f "$dest.tmp.$$" "$dest"
  set_sha "$dest"
  echo "installed: $dest"
}

install_file "$REPO_DIR/prompts/lead_prompt.txt"    "$HOME/.claude/lead_prompt.txt"   644
install_file "$REPO_DIR/config/herdr/config.toml"   "$HOME/.config/herdr/config.toml" 644
install_file "$REPO_DIR/bin/lead"                   "$HOME/.local/bin/lead"           755
install_file "$REPO_DIR/bin/lead-notify"            "$HOME/.local/bin/lead-notify"    755
install_file "$REPO_DIR/config/claude/lead-settings.json" "$HOME/.claude/lead/settings.json" 644

# Herdr skill for Claude Code
if [ "$HAVE_HERDR" -eq 1 ]; then
  if herdr --skill > "$TMP_DIR/SKILL.md" 2>/dev/null && [ -s "$TMP_DIR/SKILL.md" ]; then
    install_file "$TMP_DIR/SKILL.md" "$HOME/.claude/skills/herdr/SKILL.md" 644
  else
    echo "warning: 'herdr --skill' failed; skipping SKILL.md" >&2
  fi
else
  echo "warning: herdr missing; skipping ~/.claude/skills/herdr/SKILL.md" >&2
fi

# Shell rc: one fenced block, replaced in place on re-run.
RC_EXISTED=1
[ -e "$RC_FILE" ] || { RC_EXISTED=0; : > "$TMP_DIR/rc.orig"; }
[ "$RC_EXISTED" -eq 1 ] && cp "$RC_FILE" "$TMP_DIR/rc.orig"

# rc content with the managed block removed (to detect user-defined aliases).
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0 == b { skip = 1; next }
  $0 == e { skip = 0; next }
  !skip   { print }
' "$TMP_DIR/rc.orig" > "$TMP_DIR/rc.outside"

{
  echo "$BEGIN_MARK"
  echo "# Managed by herdr-multi-agent-setup install.sh; edits here are overwritten."
  # shellcheck disable=SC2016  # literal $PATH/$HOME must reach the rc file unexpanded
  echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  if ! grep -Eq '^[[:space:]]*alias[[:space:]]+hlead=' "$TMP_DIR/rc.outside"; then
    echo 'alias hlead="herdr --session main"'
  fi
  echo "$END_MARK"
} > "$TMP_DIR/rc.block"

if grep -Fxq "$BEGIN_MARK" "$TMP_DIR/rc.orig"; then
  # Replace the existing block in place.
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v blockfile="$TMP_DIR/rc.block" '
    $0 == b { while ((getline l < blockfile) > 0) print l; skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$TMP_DIR/rc.orig" > "$TMP_DIR/rc.new"
else
  { cat "$TMP_DIR/rc.orig"
    [ -s "$TMP_DIR/rc.orig" ] && [ -n "$(tail -c1 "$TMP_DIR/rc.orig")" ] && echo
    cat "$TMP_DIR/rc.block"
  } > "$TMP_DIR/rc.new"
fi

if [ "$RC_EXISTED" -eq 1 ] && cmp -s "$TMP_DIR/rc.new" "$RC_FILE"; then
  echo "unchanged: $RC_FILE (herdr-multi-agent-setup block up to date)"
else
  cat "$TMP_DIR/rc.new" > "$RC_FILE"   # write through, preserving symlinks/perms
  echo "updated:   $RC_FILE (herdr-multi-agent-setup block)"
fi
[ "$RC_EXISTED" -eq 0 ] && record rcnew "$RC_FILE"
record rc "$RC_FILE"

if grep -Eq '^[[:space:]]*alias[[:space:]]+lead=' "$TMP_DIR/rc.outside"; then
  echo "warning: $RC_FILE defines 'alias lead=...', which shadows ~/.local/bin/lead; remove that alias" >&2
fi

# Reload herdr config if a server is already running (never start/stop one).
# Capture the status first, then grep it (no pipe, so no SIGPIPE/pipefail issue).
SERVER_STATUS=""
if [ "${HERDR_SETUP_SKIP_RELOAD:-0}" != "1" ] && [ "$HAVE_HERDR" -eq 1 ]; then
  SERVER_STATUS="$(herdr status server 2>/dev/null || true)"
fi
if [ "${HERDR_SETUP_SKIP_RELOAD:-0}" = "1" ]; then
  echo "note: HERDR_SETUP_SKIP_RELOAD=1, not reloading herdr config"
elif grep -q '^status: running' <<< "$SERVER_STATUS"; then
  if herdr server reload-config; then
    echo "reloaded herdr config"
  else
    echo "warning: herdr config reload failed; run 'herdr server reload-config' manually" >&2
  fi
else
  echo "note: no running herdr server detected; config applies next time herdr starts"
fi

cat <<NEXT

Done. Next steps:
  source "$RC_FILE"     # or open a new terminal
  hlead                 # start/attach the Herdr session
  Ctrl+b r              # open a Lead pane (or just run: lead)
Uninstall with: $REPO_DIR/uninstall.sh
NEXT
