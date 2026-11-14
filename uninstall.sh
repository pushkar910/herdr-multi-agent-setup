#!/usr/bin/env bash
# Reverse what install.sh did, using the install manifest. Each installed file
# returns to its pre-install state (see the manifest format in install.sh).
# Env: HERDR_SETUP_SKIP_RELOAD=1 skips the herdr config reload step.
set -euo pipefail

BEGIN_MARK="# >>> herdr-multi-agent-setup >>>"
END_MARK="# <<< herdr-multi-agent-setup <<<"
MANIFEST_DIR="$HOME/.local/share/herdr-multi-agent-setup"
MANIFEST="$MANIFEST_DIR/manifest"
TAB=$'\t'

if [ ! -f "$MANIFEST" ]; then
  echo "uninstall: no manifest at $MANIFEST; nothing to do."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp "$MANIFEST" "$TMP_DIR/manifest"

STAMP="$(date +%Y%m%d-%H%M%S)"

file_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | cut -d' ' -f1
  else
    sha256sum < "$1" | cut -d' ' -f1
  fi
}

# manifest_field <type> <dest> first|last: field 3 of the first/last <type> line for <dest>.
manifest_field() {
  T="$1" D="$2" W="$3" awk -F'\t' '
    $1 == ENVIRON["T"] && $2 == ENVIRON["D"] { v = $3; if (!n++) f = $3 }
    END { if (n) print (ENVIRON["W"] == "first" ? f : v) }
  ' "$TMP_DIR/manifest"
}

exists() { [ -e "$1" ] || [ -L "$1" ]; }

# is_edited <dest>: true if <dest> differs from what install last wrote.
is_edited() {
  local want have
  want="$(manifest_field sha "$1" last)"
  have="$(file_sha "$1" 2>/dev/null || true)"
  [ -z "$want" ] || [ "$have" != "$want" ]
}

# keep_edits <dest>: move a user-edited <dest> aside instead of losing it.
keep_edits() {
  local aside="$1.bak.uninstall.$STAMP" n=1
  while exists "$aside"; do aside="$1.bak.uninstall.$STAMP.$n"; n=$((n + 1)); done
  mv -f "$1" "$aside"
  echo "kept your edits: $1 -> $aside"
}

# restore_from <dest> <backup>: put <backup> back in place (consuming it),
# first moving any user edits of <dest> aside.
restore_from() {
  if exists "$1" && is_edited "$1"; then keep_edits "$1"; fi
  mv -f "$2" "$1"
  echo "restored: $1 (from $2)"
}

# Files: return each destination to the state recorded in its orig line.
awk -F'\t' '$1 == "orig" { print $2 "\t" $3 }' "$TMP_DIR/manifest" > "$TMP_DIR/origs"
while IFS="$TAB" read -r dest state; do
  [ -n "$dest" ] || continue
  case "$state" in
    absent)
      if ! exists "$dest"; then
        echo "absent:   $dest"
      elif is_edited "$dest"; then
        keep_edits "$dest"
      else
        rm -f "$dest"
        echo "removed:  $dest"
      fi
      ;;
    keep)
      # Identical before the first install. If a later install replaced it,
      # the first safety backup holds the user's last own content.
      first="$(manifest_field backup "$dest" first)"
      if [ -n "$first" ] && exists "$first"; then
        restore_from "$dest" "$first"
      else
        echo "kept:     $dest (existed unchanged before install)"
      fi
      ;;
    *)
      if exists "$state"; then
        restore_from "$dest" "$state"
      else
        echo "warning: original backup $state is missing; leaving $dest as is" >&2
      fi
      ;;
  esac
done < "$TMP_DIR/origs"

# Shell rc blocks.
awk -F'\t' '$1 == "rc" { print $2 }' "$TMP_DIR/manifest" | sort -u > "$TMP_DIR/rcs"
while IFS= read -r rc; do
  [ -n "$rc" ] || continue
  if [ -f "$rc" ] && grep -Fxq "$BEGIN_MARK" "$rc"; then
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip   { print }
    ' "$rc" > "$TMP_DIR/rc.new"
    cat "$TMP_DIR/rc.new" > "$rc"
    echo "cleaned:  herdr-multi-agent-setup block removed from $rc"
  fi
  if grep -Fxq "rcnew${TAB}$rc" "$TMP_DIR/manifest" && [ -f "$rc" ] && [ ! -s "$rc" ]; then
    rm -f "$rc"
    echo "removed:  $rc (created by install, now empty)"
  fi
done < "$TMP_DIR/rcs"

rm -f "$MANIFEST"
echo "removed:  manifest"

# Directories install created: remove only if empty, deepest first.
# Reverse lexical order puts every child path before its parent.
awk -F'\t' '$1 == "dir" { print $2 }' "$TMP_DIR/manifest" | sort -ru > "$TMP_DIR/dirs"
while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -d "$d" ] || continue
  if rmdir "$d" 2>/dev/null; then
    echo "removed:  $d/"
  else
    echo "kept:     $d/ (not empty)"
  fi
done < "$TMP_DIR/dirs"

# Capture the status first, then grep it (no pipe, so no SIGPIPE/pipefail issue).
if [ "${HERDR_SETUP_SKIP_RELOAD:-0}" = "1" ]; then
  echo "note: HERDR_SETUP_SKIP_RELOAD=1, not reloading herdr config"
else
  SERVER_STATUS=""
  if command -v herdr >/dev/null 2>&1; then
    SERVER_STATUS="$(herdr status server 2>/dev/null || true)"
  fi
  if grep -q '^status: running' <<< "$SERVER_STATUS"; then
    herdr server reload-config || echo "warning: herdr config reload failed" >&2
  else
    echo "note: no running herdr server detected; nothing to reload"
  fi
fi
echo "Uninstall complete."
