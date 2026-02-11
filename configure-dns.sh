#!/usr/bin/env bash
set -euo pipefail

domain=""
api_url=""
api_token=""
mode=""
api_key=""

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
    --api-url)
      api_url="${2:-}"
      shift 2
      ;;
    --token)
      api_token="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Uso: $0 --name \"inoc-lab-xyz.inocmon.com.br\" [--api-url \"https://app/api/lab-manager/dns-01\"] [--token \"TOKEN\"]"
      exit 0
      ;;
    *)
      echo "Argumento invalido: $1"
      exit 1
      ;;
  esac
done

target_root="/opt/inoc-lab"
env_file="${target_root}/.env"

read_env_value() {
  local key="$1"
  if [[ -f "$env_file" ]]; then
    grep -E "^${key}=" "$env_file" | tail -n 1 | cut -d= -f2-
  fi
}

if [[ -z "$api_url" ]]; then
  api_url="$(read_env_value "LAB_DNS01_API_URL")"
fi
if [[ -z "$api_key" ]]; then
  api_key="$(read_env_value "API_KEY")"
fi

if [[ "$mode" == "auth" || "$mode" == "cleanup" ]]; then
  if [[ -z "${CERTBOT_DOMAIN:-}" || -z "${CERTBOT_VALIDATION:-}" ]]; then
    echo "Erro: variaveis CERTBOT_DOMAIN/CERTBOT_VALIDATION nao encontradas."
    exit 1
  fi
  if [[ -z "$api_url" || -z "$api_token" ]]; then
    if [[ -z "$api_url" ]]; then
      echo "Erro: LAB_DNS01_API_URL nao informado."
      exit 1
    fi
    if [[ -z "$api_key" ]]; then
      echo "Erro: API_KEY nao informado no /opt/inoc-lab/.env."
      exit 1
    fi
    token_resp="$(curl -fsS -X POST "${api_url%/}/token" -H "X-API-Key: ${api_key}" -H "Content-Type: application/json" -d '{}' 2>/dev/null || true)"
    api_token="$(printf "%s" "$token_resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
    if [[ -z "$api_token" ]]; then
      echo "Erro: falha ao obter token temporario."
      exit 1
    fi
  fi
  if [[ "$mode" == "auth" ]]; then
    endpoint="${api_url%/}/start"
  else
    endpoint="${api_url%/}/cleanup"
  fi
  curl -fsS -X POST "$endpoint" \
    -H "X-LAB-DNS-TOKEN: ${api_token}" \
    -H "Content-Type: application/json" \
    -d "{\"domain\":\"${CERTBOT_DOMAIN}\",\"value\":\"${CERTBOT_VALIDATION}\"}" \
    >/dev/null
  exit 0
fi

if [[ -z "$domain" ]]; then
  echo "Erro: --name e obrigatorio."
  exit 1
fi

domain="$(echo "$domain" | sed -E 's#^https?://##; s#/.*$##; s/[.]$//')"
domain="$(echo "$domain" | tr '[:upper:]' '[:lower:]')"

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

if [[ -n "$api_url" ]]; then
  ensure_env_value "$env_file" "LAB_DNS01_API_URL" "$api_url"
fi

ensure_env_value "$env_file" "SSL_CERT" "/etc/letsencrypt/live/${domain}/fullchain.pem"
ensure_env_value "$env_file" "SSL_KEY" "/etc/letsencrypt/live/${domain}/privkey.pem"
ensure_env_value "$env_file" "SSL_CA" "/etc/letsencrypt/live/${domain}/chain.pem"

if [[ -z "$api_url" || -z "$api_token" ]]; then
  echo "SSL paths atualizados em ${env_file}"
  echo "Certificados esperados em /etc/letsencrypt/live/${domain}/"
  echo "Configure LAB_DNS01_API_URL no ${env_file} para gerar via DNS-01 (token temporario via API_KEY)."
  exit 0
fi

if ! command -v certbot >/dev/null 2>&1; then
  echo "Erro: certbot nao encontrado. Instale certbot antes de continuar."
  exit 1
fi

echo ">> Solicitando certificado wildcard via DNS-01..."
manual_ip_flag=""
if certbot certonly --help 2>/dev/null | grep -q -- '--manual-public-ip-logging-ok'; then
  manual_ip_flag="--manual-public-ip-logging-ok"
fi

certbot certonly --manual --preferred-challenges dns \
  --manual-auth-hook "${target_root}/configure-dns.sh auth" \
  --manual-cleanup-hook "${target_root}/configure-dns.sh cleanup" \
  --non-interactive --agree-tos --register-unsafely-without-email ${manual_ip_flag} \
  -d "*.${domain}" -d "${domain}"

echo "SSL paths atualizados em ${env_file}"
echo "Certificados prontos em /etc/letsencrypt/live/${domain}/"
