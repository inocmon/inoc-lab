#!/usr/bin/env bash
set -euo pipefail

target_root="/opt/inoc-lab"
binary_name="inoc-lab-manager"
service_name="inoc-lab-manager"
service_dir="$target_root/services"
service_src="$service_dir/${service_name}.service"
service_path="/etc/systemd/system/${service_name}.service"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Erro: execute como root."
  exit 1
fi

if [[ ! -x "$target_root/$binary_name" ]]; then
  echo "Erro: binario nao encontrado em $target_root/$binary_name"
  exit 1
fi

echo ">> Instalando binario em /usr/bin/${binary_name}..."
install -m 0755 "$target_root/$binary_name" "/usr/bin/${binary_name}"

echo ">> Instalando unit systemd..."
if [[ -f "$service_src" ]]; then
  install -m 0644 "$service_src" "$service_path"
else
  cat > "$service_path" <<EOUNIT
[Unit]
Description=Inoc Lab Manager API
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${target_root}
EnvironmentFile=-${target_root}/.env
Environment=LAB_ROOT=${target_root}
Environment=CATALOG_DIR=${target_root}/catalog
Environment=TOPOLOGY_DIR=${target_root}/topologies
Environment=VM_BASE=${target_root}/vms
Environment=STATE_DIR=${target_root}/state
Environment=INSTANCES_DIR=${target_root}/instances
ExecStart=/usr/bin/${binary_name} --env ${target_root}/.env
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOUNIT
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl enable "$service_name" || true
  systemctl restart "$service_name" || true
else
  echo "Aviso: systemctl nao encontrado. Instale/ative o servico manualmente."
fi
