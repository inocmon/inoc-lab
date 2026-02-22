#!/usr/bin/env bash
set -euo pipefail

target_root="/opt/inoc-lab"
installer_path="${target_root}/inoc-lab-install.sh"
fallback_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inoc-lab-install.sh"

if [[ -x "$installer_path" ]]; then
  exec "$installer_path" dns "$@"
fi

if [[ -x "$fallback_path" ]]; then
  exec "$fallback_path" dns "$@"
fi

echo "Erro: inoc-lab-install.sh nao encontrado em ${installer_path}."
exit 1
