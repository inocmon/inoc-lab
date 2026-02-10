#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lab_root="${LAB_ROOT:-$script_dir}"
catalog_dir="${CATALOG_DIR:-$lab_root/catalog}"
catalog_file="${catalog_dir}/images.json"

if [[ ! -f "$catalog_file" ]]; then
  echo "Erro: catalogo nao encontrado em ${catalog_file}"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Erro: python3 necessario para executar o download."
  exit 1
fi

python3 - "$catalog_file" "$lab_root" "$@" <<'PY'
import sys
import os
import json
import re
import time
import hashlib
import urllib.request
import urllib.parse
import http.cookiejar

catalog_path = sys.argv[1]
lab_root = sys.argv[2]
args = sys.argv[3:]

only_id = None
list_only = False
if "--list" in args:
    list_only = True
if "--only" in args:
    idx = args.index("--only")
    if idx + 1 < len(args):
        only_id = args[idx + 1]

def normalize_url(raw):
    raw = str(raw or "").strip()
    if not raw:
        return ""
    try:
        parsed = urllib.parse.urlparse(raw)
    except Exception:
        return raw
    host = parsed.hostname or ""
    path = parsed.path or ""
    query = urllib.parse.parse_qs(parsed.query or "")
    if "drive.google.com" in host:
        if path.startswith("/uc"):
            return raw
        m = re.search(r"/file/d/([^/]+)", path)
        if m:
            return f"https://drive.google.com/uc?export=download&id={m.group(1)}"
        file_id = query.get("id", [""])[0]
        if file_id:
            return f"https://drive.google.com/uc?export=download&id={file_id}"
    if "docs.google.com" in host:
        m = re.search(r"/document/d/([^/]+)", path)
        if m:
            return f"https://drive.google.com/uc?export=download&id={m.group(1)}"
    return raw

def extract_confirm_token(html):
    match = re.search(r"confirm=([0-9A-Za-z_-]+)", html)
    if match:
        return match.group(1)
    match = re.search(r"download_warning[^=]*=([0-9A-Za-z_-]+)", html)
    return match.group(1) if match else ""

def extract_drive_id(url, html=""):
    try:
        parsed = urllib.parse.urlparse(url)
        query = urllib.parse.parse_qs(parsed.query or "")
        file_id = query.get("id", [""])[0]
        if file_id:
            return file_id
        m = re.search(r"/file/d/([^/]+)", parsed.path or "")
        if m:
            return m.group(1)
        m = re.search(r"/document/d/([^/]+)", parsed.path or "")
        if m:
            return m.group(1)
    except Exception:
        pass
    m = re.search(r"(?:id=|/file/d/|/document/d/)([A-Za-z0-9_-]{10,})", html or "")
    return m.group(1) if m else ""

def build_opener():
    jar = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

def open_url(opener, url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    return opener.open(req)

def download_file(url, target, sha256=""):
    url = normalize_url(url)
    opener = build_opener()
    resp = open_url(opener, url)
    content_type = resp.headers.get("Content-Type", "")
    if ("google.com" in (urllib.parse.urlparse(url).hostname or "")) and "text/html" in content_type:
        html = resp.read().decode("utf-8", "ignore")
        token = extract_confirm_token(html)
        file_id = extract_drive_id(url, html)
        if token and file_id:
            confirm_url = f"https://drive.google.com/uc?export=download&id={file_id}&confirm={token}"
            resp = open_url(opener, confirm_url)
            content_type = resp.headers.get("Content-Type", "")
        else:
            raise RuntimeError("Google Drive retornou HTML; verifique se o link e publico.")

    total = resp.headers.get("Content-Length")
    total = int(total) if total and total.isdigit() else 0
    tmp_path = target + ".partial"
    os.makedirs(os.path.dirname(target), exist_ok=True)

    hasher = hashlib.sha256() if sha256 else None
    downloaded = 0
    last_print = 0.0
    chunk_size = 1024 * 1024

    with open(tmp_path, "wb") as out:
        while True:
            chunk = resp.read(chunk_size)
            if not chunk:
                break
            out.write(chunk)
            if hasher:
                hasher.update(chunk)
            downloaded += len(chunk)
            now = time.time()
            if now - last_print > 0.2:
                if total:
                    pct = downloaded * 100.0 / total
                    sys.stdout.write(f"\r  {downloaded/1024/1024:.1f} MB / {total/1024/1024:.1f} MB ({pct:.1f}%)")
                else:
                    sys.stdout.write(f"\r  {downloaded/1024/1024:.1f} MB")
                sys.stdout.flush()
                last_print = now

    if total:
        sys.stdout.write(f"\r  {downloaded/1024/1024:.1f} MB / {total/1024/1024:.1f} MB (100.0%)\n")
    else:
        sys.stdout.write(f"\r  {downloaded/1024/1024:.1f} MB\n")
    sys.stdout.flush()

    if hasher:
        digest = hasher.hexdigest()
        if digest.lower() != sha256.lower():
            os.remove(tmp_path)
            raise RuntimeError("SHA256 nao confere (arquivo removido).")

    os.replace(tmp_path, target)

def load_catalog(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

data = load_catalog(catalog_path)
images = data if isinstance(data, dict) else {}

if list_only:
    for key in sorted(images.keys()):
        print(key)
    sys.exit(0)

found = False
for image_id, image in images.items():
    if only_id and image_id != only_id:
        continue
    found = True
    path = image.get("path") or ""
    if not path:
        print(f"[{image_id}] path nao definido, ignorando.")
        continue
    target = path if os.path.isabs(path) else os.path.join(lab_root, path)
    if os.path.exists(target) and os.path.getsize(target) > 0:
        print(f"[{image_id}] OK (ja existe)")
        continue
    download = image.get("download")
    if not download:
        print(f"[{image_id}] Sem download configurado.")
        continue
    if isinstance(download, str):
        url = download
        sha256 = ""
    elif isinstance(download, dict):
        url = download.get("url") or download.get("href") or download.get("source") or ""
        sha256 = download.get("sha256") or download.get("hash") or ""
    else:
        print(f"[{image_id}] Campo download invalido.")
        continue
    url = normalize_url(url)
    if not url:
        print(f"[{image_id}] URL de download vazia.")
        continue

    print(f"[{image_id}] Baixando para {target}")
    try:
        download_file(url, target, sha256)
        print(f"[{image_id}] Concluido.")
    except Exception as exc:
        print(f"[{image_id}] Falha: {exc}")

if only_id and not found:
    print("Imagem nao encontrada no catalogo.")
PY
