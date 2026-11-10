#!/usr/bin/env bash
#
# apply-service-template.sh — one source of truth for the canonical bun-API
# Dockerfile and .dockerignore.
#
# The plain Bun HTTP-API services share a byte-identical Dockerfile (differing
# only by port) and .dockerignore. Rather than hand-maintain ~13 copies (which
# drift), the canonical versions live in this repo under templates/, and this
# script stamps them into each sibling service repo listed in services.manifest,
# substituting __PORT__ with that service's port.
#
# Each repo still keeps its own Dockerfile on disk — the shared CI
# (johnqh/workflows) builds each repo from its own context — this just keeps
# those files generated from one template instead of edited by hand.
#
# Usage (run from anywhere inside the repo):
#   scripts/apply-service-template.sh            # write/update every listed repo
#   scripts/apply-service-template.sh --check    # report drift only; change nothing (exit 1 if drift)
#   scripts/apply-service-template.sh music_api sudojo_api   # limit to specific repos
#
# Sibling repos are expected one directory up from this repo (…/projects/<repo>).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"            # sudobility_dockerized
PROJECTS_ROOT="$(cd "$REPO_ROOT/.." && pwd)"   # parent dir holding sibling repos
TEMPLATE_DF="$REPO_ROOT/templates/Dockerfile.bun-api"
TEMPLATE_DI="$REPO_ROOT/templates/dockerignore"
MANIFEST="$REPO_ROOT/services.manifest"

for f in "$TEMPLATE_DF" "$TEMPLATE_DI" "$MANIFEST"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done

check=0
only=()
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    -*) echo "error: unknown option $arg" >&2; exit 1 ;;
    *) only+=("$arg") ;;
  esac
done

wanted() { # $1 repo — true unless an explicit subset was given that excludes it
  [ ${#only[@]} -eq 0 ] && return 0
  local r
  for r in "${only[@]}"; do [ "$r" = "$1" ] && return 0; done
  return 1
}

drift=0
stamped=0
# Read "repo port" rows, skipping blanks and # comments.
while read -r repo port _rest; do
  [ -z "${repo:-}" ] && continue
  case "$repo" in \#*) continue ;; esac
  wanted "$repo" || continue

  dir="$PROJECTS_ROOT/$repo"
  if [ ! -d "$dir" ]; then
    echo "skip (not checked out): $repo"
    continue
  fi
  if [ -z "${port:-}" ]; then
    echo "skip (no port in manifest): $repo" >&2
    continue
  fi

  if [ "$check" -eq 1 ]; then
    if ! diff -q <(sed "s/__PORT__/$port/g" "$TEMPLATE_DF") "$dir/Dockerfile" >/dev/null 2>&1; then
      echo "DRIFT  Dockerfile    $repo"; drift=1
    fi
    if ! diff -q "$TEMPLATE_DI" "$dir/.dockerignore" >/dev/null 2>&1; then
      echo "DRIFT  .dockerignore $repo"; drift=1
    fi
  else
    sed "s/__PORT__/$port/g" "$TEMPLATE_DF" > "$dir/Dockerfile"
    cp "$TEMPLATE_DI" "$dir/.dockerignore"
    echo "stamped: $repo (port $port)"
    stamped=$((stamped + 1))
  fi
done < "$MANIFEST"

if [ "$check" -eq 1 ]; then
  if [ "$drift" -eq 0 ]; then echo "No drift — all listed repos match the template."; else exit 1; fi
else
  echo "Done — stamped $stamped repo(s) from templates/Dockerfile.bun-api + templates/dockerignore."
fi
