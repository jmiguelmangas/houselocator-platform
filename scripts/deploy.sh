#!/usr/bin/env bash
# Deploy al VPS: sincroniza el workspace por rsync y reconstruye el stack por SSH.
# Uso: HOUSELOCATOR_DEPLOY_HOST=user@host ./scripts/deploy.sh
set -euo pipefail

HOST="${HOUSELOCATOR_DEPLOY_HOST:?define HOUSELOCATOR_DEPLOY_HOST=user@host}"
REMOTE_PATH="${HOUSELOCATOR_DEPLOY_PATH:-~/houselocator}"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "→ Sincronizando ${WORKSPACE_ROOT} -> ${HOST}:${REMOTE_PATH}"
rsync -az --delete \
  --exclude '.git' --exclude '.env' --exclude '__pycache__' --exclude '.venv' \
  "${WORKSPACE_ROOT}/" "${HOST}:${REMOTE_PATH}/"

echo "→ Reconstruyendo stack en remoto"
ssh "${HOST}" "cd ${REMOTE_PATH}/houselocator-platform && docker compose up -d --build"

echo "Deploy completado."
