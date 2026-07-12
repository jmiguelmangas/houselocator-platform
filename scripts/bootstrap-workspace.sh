#!/usr/bin/env bash
# Clona, junto a este repo, los repos hermanos de HouseLocator que falten.
# Uso: cd houselocator-platform && ./scripts/bootstrap-workspace.sh [--org <github-org>]
set -euo pipefail

ORG="${HOUSELOCATOR_GH_ORG:-jmiguelmangas}"
if [[ "${1:-}" == "--org" ]]; then
  ORG="$2"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIBLINGS=(
  houselocator-ingest
  houselocator-bot
  houselocator-web
  houselocator-mortgages
)

echo "Workspace: ${REPO_ROOT}"

for repo in "${SIBLINGS[@]}"; do
  dest="${REPO_ROOT}/${repo}"
  if [[ -d "${dest}/.git" ]]; then
    echo "✓ ${repo} ya existe, se omite"
    continue
  fi
  echo "→ Clonando ${repo}..."
  if ! git clone "git@github.com:${ORG}/${repo}.git" "${dest}"; then
    echo "  (no se pudo clonar ${repo} — puede que aún no exista en GitHub; se omite)"
  fi
done

echo "Listo. Repos presentes en ${REPO_ROOT}:"
ls -1 "${REPO_ROOT}" | grep '^houselocator-'
