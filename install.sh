#!/usr/bin/env bash
set -euo pipefail
umask 077

controller='' server='' token=''
extra=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --controller) controller="${2:?Informe o controlador}"; shift 2 ;;
    --server) server="${2:?Informe o servidor}"; shift 2 ;;
    --token) token="${2:?Informe o token}"; shift 2 ;;
    --image-root|--catalog-dir|--tls-cert|--tls-key|--tls-ca) extra+=("$1" "${2:?Informe o caminho}"); shift 2 ;;
    --skip-deps|--with-flows) extra+=("$1"); shift ;;
    *) echo "Opção desconhecida: $1" >&2; exit 2 ;;
  esac
done
if [ "$(id -u)" -ne 0 ]; then echo 'Execute o instalador como root.' >&2; exit 1; fi
if [[ ! "$controller" =~ ^https?://[^[:space:]]+$ || ! "$server" =~ ^[a-f0-9-]{36}$ || ! "$token" =~ ^[a-f0-9]{64}$ ]]; then
  echo 'Controlador, servidor e token válidos são obrigatórios.' >&2; exit 2
fi
if [ "$(uname -m)" != x86_64 ]; then echo 'Esta release requer Linux amd64.' >&2; exit 1; fi
if ! command -v apt-get >/dev/null; then echo 'Esta versão do instalador requer Debian ou Ubuntu.' >&2; exit 1; fi
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get update
  apt-get install -y python3 curl ca-certificates
fi
controller_scheme="$(python3 - "$controller" <<'PY'
import ipaddress,sys,urllib.parse
url=urllib.parse.urlsplit(sys.argv[1])
if url.scheme not in ('http','https') or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ('','/'):
    raise SystemExit('Controlador inválido.')
if url.scheme == 'http':
    try: address=ipaddress.ip_address(url.hostname)
    except ValueError: raise SystemExit('Controlador HTTP exige um IP privado literal.')
    networks=[ipaddress.ip_network(value) for value in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','127.0.0.0/8','169.254.0.0/16','::1/128','fc00::/7','fe80::/10')]
    if not any(address in network for network in networks): raise SystemExit('Controlador HTTP fora da rede privada.')
print(url.scheme)
PY
)"
stage="$(mktemp -d /var/tmp/inoc-lab-install.XXXXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$token" > "$stage/curl.conf"
printf '%s' "$token" > "$stage/token"
unset token
echo 'INOC Lab: verificando pareamento e release...'
curl --fail --silent --show-error --proto "=$controller_scheme" --connect-timeout 10 --max-time 60 \
  --config "$stage/curl.conf" "${controller%/}/inoc-lab/hosts/$server/bootstrap" -o "$stage/bootstrap.json"
curl --fail --silent --show-error --proto "=$controller_scheme" --connect-timeout 10 --max-time 600 \
  --config "$stage/curl.conf" "${controller%/}/inoc-lab/hosts/$server/release" -o "$stage/release.tar.gz"
python3 - "$stage" <<'PY'
import hashlib,json,pathlib,sys,tarfile
stage=pathlib.Path(sys.argv[1]); manifest=json.loads((stage/'bootstrap.json').read_text())['release']
if manifest.get('source_dirty') is not False or manifest.get('api_version') != 2: raise SystemExit('Release incompatível ou sem commit limpo.')
with (stage/'release.tar.gz').open('rb') as stream: actual=hashlib.file_digest(stream,'sha256').hexdigest() if hasattr(hashlib,'file_digest') else hashlib.sha256(stream.read()).hexdigest()
if actual != manifest['archive_sha256']: raise SystemExit('Checksum da release inválido; tente novamente para obter uma release consistente.')
with tarfile.open(stage/'release.tar.gz') as archive:
    for item in archive.getmembers():
        path=pathlib.PurePosixPath(item.name)
        if path.is_absolute() or '..' in path.parts or item.issym() or item.islnk() or not (item.isfile() or item.isdir()): raise SystemExit('Arquivo de release inválido.')
    archive.extractall(stage/'release')
PY
python3 "$stage/release/deploy/install.py" --stage "$stage" --controller "${controller%/}" --server "$server" "${extra[@]}"
