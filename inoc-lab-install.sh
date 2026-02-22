#!/usr/bin/env bash
set -euo pipefail

target_root="/opt/inoc-lab"
binary_name="inoc-lab-manager"
service_name="inoc-lab-manager"
service_dir="$target_root/services"
service_src="$service_dir/${service_name}.service"
service_path="/etc/systemd/system/${service_name}.service"
env_file="$target_root/.env"
env_example_file="$target_root/.env.example"

ensure_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if [[ -f "$file" ]]; then
    if grep -q "^${key}=" "$file"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
      echo "${key}=${value}" >> "$file"
    fi
  else
    printf "%s=%s\n" "$key" "$value" > "$file"
  fi
}

read_env_value() {
  local key="$1"
  if [[ -f "$env_file" ]]; then
    grep -E "^${key}=" "$env_file" | tail -n 1 | cut -d= -f2- | tr -d '\r'
  fi
}

normalize_domain() {
  local raw="${1:-}"
  raw="$(echo "$raw" | sed -E 's#^https?://##; s#/.*$##; s/[.]$//')"
  echo "$raw" | tr '[:upper:]' '[:lower:]'
}

extract_json_token() {
  local body="${1:-}"
  local token=""
  if command -v jq >/dev/null 2>&1; then
    token="$(printf "%s" "$body" | jq -r '.token // empty' 2>/dev/null || true)"
  fi
  if [[ -z "$token" ]]; then
    token="$(printf "%s" "$body" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  fi
  printf "%s" "$token"
}

restart_service_if_exists() {
  local target_service="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  if systemctl list-unit-files --type=service --all 2>/dev/null | grep -q "^${target_service}[[:space:]]"; then
    systemctl restart "$target_service" >/dev/null 2>&1 || true
  fi
}

usage_main() {
  cat <<'EOF'
Uso:
  /opt/inoc-lab/inoc-lab-install.sh [--url DOMINIO --apikey CHAVE] [--api-url URL_DNS01] [--skip-dns]
  /opt/inoc-lab/inoc-lab-install.sh install [--url DOMINIO --apikey CHAVE] [--api-url URL_DNS01] [--skip-dns]
  /opt/inoc-lab/inoc-lab-install.sh dns --name DOMINIO [--api-url URL_DNS01] [--token TOKEN]
  /opt/inoc-lab/inoc-lab-install.sh dns --url DOMINIO --apikey CHAVE [--api-url URL_DNS01]
  /opt/inoc-lab/inoc-lab-install.sh dns auth
  /opt/inoc-lab/inoc-lab-install.sh dns cleanup

Por padrão, com --url + --apikey, o instalador tenta emitir o certificado via DNS-01 automaticamente.
EOF
}

install_main() {
  local install_url=""
  local install_apikey=""
  local install_api_url=""
  local domain=""
  local auto_dns="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        install_url="${2:-}"
        shift 2
        ;;
      --apikey)
        install_apikey="${2:-}"
        shift 2
        ;;
      --api-url)
        install_api_url="${2:-}"
        shift 2
        ;;
      --skip-dns)
        auto_dns="false"
        shift
        ;;
      -h|--help)
        usage_main
        return 0
        ;;
      *)
        echo "Argumento invalido: $1"
        return 1
        ;;
    esac
  done

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Erro: execute como root."
    return 1
  fi

  if [[ -n "$install_url" || -n "$install_apikey" ]]; then
    if [[ -z "$install_url" || -z "$install_apikey" ]]; then
      echo "Erro: use --url e --apikey juntos."
      return 1
    fi
    if [[ ! -f "$env_example_file" ]]; then
      echo "Erro: arquivo base nao encontrado em $env_example_file"
      return 1
    fi
    domain="$(normalize_domain "$install_url")"
    if [[ -z "$domain" ]]; then
      echo "Erro: --url invalido."
      return 1
    fi
    cp -f "$env_example_file" "$env_file"
    ensure_env_value "$env_file" "API_KEY" "$install_apikey"
    ensure_env_value "$env_file" "SSL_CERT" "/etc/letsencrypt/live/${domain}/fullchain.pem"
    ensure_env_value "$env_file" "SSL_KEY" "/etc/letsencrypt/live/${domain}/privkey.pem"
    ensure_env_value "$env_file" "SSL_CA" "/etc/letsencrypt/live/${domain}/chain.pem"
    if [[ -n "$install_api_url" ]]; then
      ensure_env_value "$env_file" "LAB_DNS01_API_URL" "$install_api_url"
    fi
    echo ">> .env recriado a partir de .env.example com API_KEY e SSL para ${domain}."
  fi

  if [[ ! -x "$target_root/$binary_name" ]]; then
    echo "Erro: binario nao encontrado em $target_root/$binary_name"
    return 1
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
    if [[ -x "$target_root/image-sync.sh" ]]; then
      echo ">> Sincronizando imagens..."
      "$target_root/image-sync.sh" || echo "Aviso: falha ao sincronizar imagens."
    else
      echo "Aviso: image-sync.sh nao encontrado em $target_root"
    fi
  else
    echo "Aviso: systemctl nao encontrado. Instale/ative o servico manualmente."
  fi

  if [[ -n "$domain" && "$auto_dns" == "true" ]]; then
    local dns_api_url="$install_api_url"
    if [[ -z "$dns_api_url" ]]; then
      dns_api_url="$(read_env_value "LAB_DNS01_API_URL")"
    fi
    if [[ -n "$dns_api_url" ]]; then
      echo ">> Gerando certificado wildcard automaticamente (DNS-01)..."
      dns_main --name "$domain" --api-url "$dns_api_url"
    else
      echo "Aviso: LAB_DNS01_API_URL nao informado; certificado nao foi gerado automaticamente."
      echo "Defina --api-url (ou LAB_DNS01_API_URL no .env) para habilitar DNS-01 automatico."
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$service_name" || true
  fi

  return 0
}

dns_main() {
  local domain=""
  local api_url="${LAB_DNS01_API_URL:-}"
  local api_token="${LAB_DNS01_API_TOKEN:-}"
  local mode=""
  local api_key="${LAB_DNS01_API_KEY:-}"
  local propagation_seconds="${LAB_DNS01_PROPAGATION_SECONDS:-15}"
  local url_arg_provided="false"
  local apikey_arg_provided="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      auth|cleanup)
        mode="$1"
        shift
        ;;
      --name)
        domain="${2:-}"
        shift 2
        ;;
      --url)
        domain="${2:-}"
        url_arg_provided="true"
        shift 2
        ;;
      --apikey)
        api_key="${2:-}"
        apikey_arg_provided="true"
        shift 2
        ;;
      --api-url)
        api_url="${2:-}"
        shift 2
        ;;
      --token)
        api_token="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage_main
        return 0
        ;;
      *)
        echo "Argumento invalido: $1"
        return 1
        ;;
    esac
  done

  if [[ -z "$api_url" ]]; then
    api_url="$(read_env_value "LAB_DNS01_API_URL")"
  fi
  if [[ -z "$api_key" ]]; then
    api_key="$(read_env_value "API_KEY")"
  fi

  if [[ "$mode" == "auth" || "$mode" == "cleanup" ]]; then
    if [[ -z "${CERTBOT_DOMAIN:-}" || -z "${CERTBOT_VALIDATION:-}" ]]; then
      echo "Erro: variaveis CERTBOT_DOMAIN/CERTBOT_VALIDATION nao encontradas."
      return 1
    fi
    if [[ -z "$api_url" ]]; then
      echo "Erro: LAB_DNS01_API_URL nao informado."
      return 1
    fi
    if [[ -z "$api_token" && -z "$api_key" ]]; then
      echo "Erro: API_KEY nao informado no /opt/inoc-lab/.env."
      return 1
    fi
    if [[ -z "$api_token" && -n "$api_key" ]]; then
      local token_resp token_http token_body
      token_resp="$(curl -sS -X POST "${api_url%/}/token" \
        -H "X-API-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d '{}' \
        -w $'\n%{http_code}' 2>&1 || true)"
      token_http="$(printf "%s" "$token_resp" | tail -n1 | tr -d '\r')"
      token_body="$(printf "%s" "$token_resp" | sed '$d')"
      if [[ ! "$token_http" =~ ^2[0-9][0-9]$ ]]; then
        echo "Aviso: token temporario indisponivel (HTTP ${token_http:-000}). Tentando via X-API-Key."
        if [[ -n "$token_body" ]]; then
          echo "Resposta: ${token_body}"
        fi
        api_token=""
      else
        api_token="$(extract_json_token "$token_body")"
        if [[ -z "$api_token" ]]; then
          echo "Aviso: token temporario vazio. Tentando via X-API-Key."
          if [[ -n "$token_body" ]]; then
            echo "Resposta: ${token_body}"
          fi
        fi
      fi
    fi

    local endpoint
    if [[ "$mode" == "auth" ]]; then
      endpoint="${api_url%/}/start"
    else
      endpoint="${api_url%/}/cleanup"
    fi
    local dns_payload
    dns_payload="{\"domain\":\"${CERTBOT_DOMAIN}\",\"value\":\"${CERTBOT_VALIDATION}\"}"
    if [[ -n "$api_token" ]]; then
      curl -fsS -X POST "$endpoint" \
        -H "X-LAB-DNS-TOKEN: ${api_token}" \
        -H "Content-Type: application/json" \
        -d "$dns_payload" \
        >/dev/null
    else
      curl -fsS -X POST "$endpoint" \
        -H "X-API-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "$dns_payload" \
        >/dev/null
    fi
    if [[ "$mode" == "auth" ]]; then
      sleep "$propagation_seconds"
    fi
    return 0
  fi

  if [[ "$url_arg_provided" == "true" && "$apikey_arg_provided" == "true" ]]; then
    if [[ -f "$env_example_file" ]]; then
      cp -f "$env_example_file" "$env_file"
    fi
  fi

  if [[ "$apikey_arg_provided" == "true" && -n "$api_key" ]]; then
    ensure_env_value "$env_file" "API_KEY" "$api_key"
  fi

  if [[ -z "$domain" && "$apikey_arg_provided" == "true" ]]; then
    echo "API_KEY atualizada em ${env_file}"
    return 0
  fi

  if [[ -z "$domain" ]]; then
    echo "Erro: --name e obrigatorio."
    return 1
  fi

  domain="$(normalize_domain "$domain")"
  if [[ -n "$api_url" ]]; then
    ensure_env_value "$env_file" "LAB_DNS01_API_URL" "$api_url"
  fi

  ensure_env_value "$env_file" "SSL_CERT" "/etc/letsencrypt/live/${domain}/fullchain.pem"
  ensure_env_value "$env_file" "SSL_KEY" "/etc/letsencrypt/live/${domain}/privkey.pem"
  ensure_env_value "$env_file" "SSL_CA" "/etc/letsencrypt/live/${domain}/chain.pem"

  if [[ -z "$api_url" ]]; then
    echo "SSL paths atualizados em ${env_file}"
    echo "Certificados esperados em /etc/letsencrypt/live/${domain}/"
    echo "Configure LAB_DNS01_API_URL no ${env_file} para gerar via DNS-01 (token temporario via API_KEY)."
    return 0
  fi

  if [[ -z "$api_token" && -z "$api_key" ]]; then
    echo "Erro: API_KEY nao informado no ${env_file} e nenhum --token foi passado."
    echo "Informe API_KEY no .env ou execute novamente com --token."
    return 1
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    echo "Erro: certbot nao encontrado. Instale certbot antes de continuar."
    return 1
  fi

  echo ">> Solicitando certificado wildcard via DNS-01..."
  local manual_ip_flag=""
  if certbot certonly --help 2>/dev/null | grep -q -- '--manual-public-ip-logging-ok'; then
    manual_ip_flag="--manual-public-ip-logging-ok"
  fi

  LAB_DNS01_API_URL="$api_url" LAB_DNS01_API_TOKEN="$api_token" LAB_DNS01_API_KEY="$api_key" LAB_DNS01_PROPAGATION_SECONDS="$propagation_seconds" \
  certbot certonly --manual --preferred-challenges dns \
    --manual-auth-hook "${target_root}/configure-dns.sh auth" \
    --manual-cleanup-hook "${target_root}/configure-dns.sh cleanup" \
    --non-interactive --agree-tos --register-unsafely-without-email ${manual_ip_flag} \
    -d "*.${domain}" -d "${domain}"

  echo ">> Recarregando servico do lab-manager para aplicar novo certificado..."
  restart_service_if_exists "${service_name}.service"
  echo "SSL paths atualizados em ${env_file}"
  echo "Certificados prontos em /etc/letsencrypt/live/${domain}/"
  return 0
}

main() {
  local cmd="${1:-install}"
  case "$cmd" in
    dns)
      shift
      dns_main "$@"
      ;;
    install)
      shift
      install_main "$@"
      ;;
    help|-h|--help)
      usage_main
      ;;
    *)
      install_main "$@"
      ;;
  esac
}

main "$@"
