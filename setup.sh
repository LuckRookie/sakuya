#!/usr/bin/env bash
# Install the Sakuya mandate as one marked block in a host's stable instruction file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${SAKUYA_STATE:-$HOME/.sakuya}"
BEGIN='<!-- SAKUYA:BEGIN -->'
END='<!-- SAKUYA:END -->'
TARGET=""
DIR=""
DRY=0
UNINSTALL=0
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log(){ printf '%s\n' "$*"; }

usage(){ cat <<'EOF'
Usage: ./setup.sh TARGET [--dir PATH] [--hermes-home PATH] [--dry-run] [--uninstall]

TARGET: pi | codex | opencode | omp | hermes | all

The installer writes one marked mandate block. It never installs skills, schemas,
memories, hooks, or workspace templates. --uninstall removes only that block.
EOF
}

[ $# -gt 0 ] || { usage; exit 1; }
TARGET="$1"; shift
case "$TARGET" in pi|codex|opencode|omp|hermes|all) ;; -h|--help) usage; exit 0 ;; *) die "unknown target: $TARGET" ;; esac

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die '--dir requires a path'; DIR="$2"; shift 2 ;;
    --hermes-home) [ $# -ge 2 ] || die '--hermes-home requires a path'; HERMES_HOME="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ "$UNINSTALL" = 0 ]; then
  [ -s "$ROOT/mandate.md" ] || die "missing mandate.md in $ROOT"
  [ "$(tail -c 1 "$ROOT/mandate.md" | wc -l)" -eq 1 ] || die 'mandate.md must end with a newline'
  if grep -qF "$BEGIN" "$ROOT/mandate.md" || grep -qF "$END" "$ROOT/mandate.md"; then
    die 'mandate.md contains reserved installer markers'
  fi
fi

resolve(){
  local target="$1"
  if [ -n "$DIR" ] && [ "$target" != hermes ]; then
    case "$target" in omp) printf '%s/.omp/RULES.md\n' "$DIR" ;; *) printf '%s/AGENTS.md\n' "$DIR" ;; esac
    return
  fi
  case "$target" in
    pi) printf '%s/.pi/agent/AGENTS.md\n' "$HOME" ;;
    codex) printf '%s/AGENTS.md\n' "${CODEX_HOME:-$HOME/.codex}" ;;
    opencode) printf '%s/.config/opencode/AGENTS.md\n' "$HOME" ;;
    omp) printf '%s/.omp/agent/RULES.md\n' "$HOME" ;;
    hermes) printf '%s/SOUL.md\n' "$HERMES_HOME" ;;
  esac
}

has_block(){ [ -f "$1" ] && grep -qxF "$BEGIN" "$1" && grep -qxF "$END" "$1"; }
malformed_block(){
  [ -f "$1" ] || return 1
  local any_begins any_ends exact_begins exact_ends begin_line end_line
  any_begins="$(grep -cF "$BEGIN" "$1" || true)"; any_ends="$(grep -cF "$END" "$1" || true)"
  exact_begins="$(grep -cxF "$BEGIN" "$1" || true)"; exact_ends="$(grep -cxF "$END" "$1" || true)"
  if [ "$any_begins" -ne "$exact_begins" ] || [ "$any_ends" -ne "$exact_ends" ] ||
     [ "$exact_begins" -ne "$exact_ends" ] || [ "$exact_begins" -gt 1 ]; then return 0; fi
  [ "$exact_begins" -eq 0 ] && return 1
  begin_line="$(grep -nxF "$BEGIN" "$1" | cut -d: -f1)"
  end_line="$(grep -nxF "$END" "$1" | cut -d: -f1)"
  [ "$begin_line" -ge "$end_line" ]
}

render_block(){
  printf '%s\n' "$BEGIN"
  cat "$ROOT/mandate.md"
  printf '%s\n' "$END"
}

block_bounds(){
  local file="$1"
  printf '%s %s\n' \
    "$(grep -nxF "$BEGIN" "$file" | cut -d: -f1)" \
    "$(grep -nxF "$END" "$file" | cut -d: -f1)"
}

without_block(){
  local file="$1" begin_line end_line
  read -r begin_line end_line < <(block_bounds "$file")
  head -n "$((begin_line - 1))" "$file"
  tail -n "+$((end_line + 1))" "$file"
}

backup_unmarked(){
  local target="$1" file="$2" stamp path_id backup
  [ -f "$file" ] || return 0
  has_block "$file" && return 0
  stamp="$(date +%Y%m%d-%H%M%S)"
  path_id="$(printf '%s' "$file" | cksum | awk '{print $1}')"
  backup="$STATE/backups/${target}-${stamp}-${path_id}-$(basename "$file")"
  log "backup: $file -> $backup"
  [ "$DRY" = 1 ] || { mkdir -p "$(dirname "$backup")"; cp -p "$file" "$backup"; }
}

install_one(){
  local target="$1" file tmp
  file="$(resolve "$target")"
  log "install $target -> $file"
  malformed_block "$file" && die "malformed or duplicated Sakuya markers in $file; refusing to edit"
  if [ -s "$file" ] && [ "$(tail -c 1 "$file" | wc -l)" -eq 0 ]; then
    die "$file has no final newline; refusing to edit because exact uninstall would be impossible"
  fi
  [ "$DRY" = 1 ] && return 0
  backup_unmarked "$target" "$file"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "$(dirname "$file")/.sakuya.XXXXXX")"
  if [ -f "$file" ]; then cp -p "$file" "$tmp"; else chmod 0644 "$tmp"; fi
  if has_block "$file"; then
    local begin_line end_line
    read -r begin_line end_line < <(block_bounds "$file")
    : > "$tmp"
    head -n "$((begin_line - 1))" "$file" >> "$tmp"
    render_block >> "$tmp"
    tail -n "+$((end_line + 1))" "$file" >> "$tmp"
  else
    render_block >> "$tmp"
  fi
  mv "$tmp" "$file"
}

uninstall_one(){
  local target="$1" file tmp
  file="$(resolve "$target")"
  malformed_block "$file" && die "malformed or duplicated Sakuya markers in $file; refusing to edit"
  if ! has_block "$file"; then log "skip $target: no Sakuya block in $file"; return 0; fi
  log "uninstall $target <- $file"
  [ "$DRY" = 1 ] && return 0
  tmp="$(mktemp "$(dirname "$file")/.sakuya.XXXXXX")"
  cp -p "$file" "$tmp"
  without_block "$file" > "$tmp"
  mv "$tmp" "$file"
}

run_one(){ if [ "$UNINSTALL" = 1 ]; then uninstall_one "$1"; else install_one "$1"; fi; }

if [ "$TARGET" = all ]; then
  # With --dir, Codex/OpenCode/Pi share AGENTS.md; one write is sufficient.
  if [ -n "$DIR" ]; then run_one pi; run_one omp; run_one hermes
  else for target in hermes codex opencode pi omp; do run_one "$target"; done
  fi
else
  run_one "$TARGET"
fi
