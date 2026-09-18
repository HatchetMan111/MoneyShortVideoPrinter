#!/usr/bin/env bash
# =============================================================================
# MoneyPrinterTurbo — Container-Setup (läuft IM LXC, Debian 12, als root)
# Wird vom Host-Installer per pct push + pct exec aufgerufen oder manuell:
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/MoneyShortVideoPrinter/main/install/setup-container.sh | bash
# Idempotent: kann mehrfach laufen (Upstream-Update, venv-Reuse, config bleibt).
# Debugging: DEBUG=1 bash -x setup-container.sh  -> volles Trace-Log
# =============================================================================
set -euo pipefail

# --- Variablen (oben, Community-Scripts-Stil) ---------------------------------
APP="moneyprinterturbo"
BASE_DIR="/opt/moneyprinterturbo"
SRC_DIR="${BASE_DIR}/MoneyPrinterTurbo"   # Upstream-Clone (harry0703/MoneyPrinterTurbo)
VENV_PY="${SRC_DIR}/.venv/bin/python"
WEBUI_PORT="${WEBUI_PORT:-8501}"
API_PORT="${API_PORT:-8080}"
PYTHON_BIN="${PYTHON_BIN:-python3.11}"
UPSTREAM_REPO="https://github.com/harry0703/MoneyPrinterTurbo.git"
WEBUI_SERVICE="moneyprinter-webui"
API_SERVICE="moneyprinter-api"
SERVICE_DIR="/etc/systemd/system"

# --- Fehlerkette: immer VOLL ausgeben, nie nur letzte Zeile -------------------
fail() {
  local code=$?
  echo "==================================================================" >&2
  echo "[FATAL] Container-Setup fehlgeschlagen (Exit-Code: ${code})" >&2
  echo "--- Befehl / Kontext ---" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Zeile  : ${BASH_LINENO[0]:-?} in ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" >&2
  echo "--- Stacktrace (Funktions-Stack) ---" >&2
  local i
  for ((i=0; i<${#FUNCNAME[@]}; i++)); do
    echo "  #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]:-?}" >&2
  done
  echo "--- stderr/stdout-Kontext ---" >&2
  echo "WEBUI_PORT=${WEBUI_PORT} API_PORT=${API_PORT} SRC_DIR=${SRC_DIR}" >&2
  echo "--- Relevante Logs (voll, nicht nur letzte Zeile) ---" >&2
  journalctl -u "${WEBUI_SERVICE}" --no-pager -n 80 2>&1 | tail -n 80 >&2 || true
  journalctl -u "${API_SERVICE}" --no-pager -n 80 2>&1 | tail -n 80 >&2 || true
  echo "Tipp: Re-Run mit Debug-Trace: DEBUG=1 bash -x $0" >&2
  echo "==================================================================" >&2
  exit "${code}"
}
trap fail ERR

if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi

echo "[1/8] Systempakete (Python 3.11, ffmpeg, git, build-tools) ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
# python3.11 ist in Debian 12 (bookworm) enthalten; Fallback auf python3
if apt-cache show "${PYTHON_BIN}-venv" >/dev/null 2>&1; then
  PY_PKG="${PYTHON_BIN}"
else
  PY_PKG="python3"
  PYTHON_BIN="python3"
  echo "  Hinweis: ${PYTHON_BIN} nicht als Paket gefunden, nutze python3 ($(python3 --version 2>&1 || echo unbekannt))."
fi
apt-get install -y --no-install-recommends \
  "${PY_PKG}" "${PY_PKG}-venv" "${PY_PKG}-dev" \
  git curl ca-certificates build-essential ffmpeg

echo "[2/8] uv-Paketmanager sicherstellen ..."
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  ln -sf "$HOME/.local/bin/uv" /usr/local/bin/uv 2>/dev/null || true
fi
uv --version
"${PYTHON_BIN}" --version
ffmpeg -version 2>&1 | head -n 1

echo "[3/8] Upstream MoneyPrinterTurbo klonen/aktualisieren ..."
mkdir -p "${BASE_DIR}"
if [[ -d "${SRC_DIR}/.git" ]]; then
  git -C "${SRC_DIR}" fetch --all --prune
  git -C "${SRC_DIR}" pull --ff-only || git -C "${SRC_DIR}" reset --hard origin/main
else
  rm -rf "${SRC_DIR}"
  git clone --depth 1 "${UPSTREAM_REPO}" "${SRC_DIR}"
fi
git -C "${SRC_DIR}" log --oneline -3 || true

echo "[4/8] Python-Umgebung (uv sync, idempotent) ..."
cd "${SRC_DIR}"
if [[ -f "uv.lock" ]]; then
  uv sync --frozen --python "${PYTHON_BIN}" || uv sync --python "${PYTHON_BIN}"
else
  uv sync --python "${PYTHON_BIN}" || {
    echo "uv sync fehlgeschlagen, Fallback: venv + pip requirements.txt" >&2
    "${PYTHON_BIN}" -m venv .venv
    ./.venv/bin/pip install --upgrade pip wheel
    [[ -f requirements.txt ]] && ./.venv/bin/pip install -r requirements.txt
  }
fi
"${VENV_PY}" -c "import streamlit; print('streamlit OK:', streamlit.__version__)"
"${VENV_PY}" -c "import fastapi; print('fastapi OK:', fastapi.__version__)"
test -f "${SRC_DIR}/webui/Main.py" || { echo "webui/Main.py fehlt im Upstream-Clone!" >&2; exit 1; }
test -f "${SRC_DIR}/main.py" || { echo "main.py (API) fehlt im Upstream-Clone!" >&2; exit 1; }

echo "[5/8] config.toml anlegen (nur falls fehlend, Keys bleiben erhalten) ..."
if [[ ! -f "${SRC_DIR}/config.toml" ]]; then
  cp "${SRC_DIR}/config.example.toml" "${SRC_DIR}/config.toml"
  echo "  config.toml aus config.example.toml erstellt."
else
  echo "  config.toml existiert bereits -> wird NICHT überschrieben (API-Keys bleiben)."
fi
# API-Bindung auf 0.0.0.0 + gewünschten Port patchen (idempotent via python)
WEBUI_PORT="${WEBUI_PORT}" API_PORT="${API_PORT}" "${VENV_PY}" - <<'PY'
import os, re
webui_port = os.environ.get("WEBUI_PORT", "8501")
api_port = os.environ.get("API_PORT", "8080")
path = "/opt/moneyprinterturbo/MoneyPrinterTurbo/config.toml"
with open(path, encoding="utf-8") as f:
    content = f.read()
content = re.sub(r'^listen_host\s*=.*$', 'listen_host = "0.0.0.0"', content, flags=re.M)
content = re.sub(r'^listen_port\s*=.*$', f'listen_port = {api_port}', content, flags=re.M)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print(f"config.toml: listen_host=0.0.0.0 listen_port={api_port} (WebUI-Port env: {webui_port})")
PY

echo "[6/8] systemd-Units installieren (webui :${WEBUI_PORT} + api :${API_PORT}) ..."
for svc in "${WEBUI_SERVICE}" "${API_SERVICE}"; do
  src=""
  if [[ -f "${BASE_DIR}/repo-files/systemd/${svc}.service" ]]; then
    src="${BASE_DIR}/repo-files/systemd/${svc}.service"
  elif [[ -f "./systemd/${svc}.service" ]]; then
    src="./systemd/${svc}.service"
  fi
  if [[ -n "${src}" ]]; then
    echo "  ${svc}: übernehme ${src}"
    cp "${src}" "${SERVICE_DIR}/${svc}.service"
  else
    echo "  ${svc}: keine Vorlage gefunden, vorhandene Unit wird behalten." >&2
  fi
done
# Ports in den Units sicherstellen (neutral gegenüber Template-Abweichungen)
sed -i -E "s/--server\.port=[0-9]+/--server.port=${WEBUI_PORT}/" "${SERVICE_DIR}/${WEBUI_SERVICE}.service"
sed -i -E "s/MPT_WEBUI_PORT=[0-9]+/MPT_WEBUI_PORT=${WEBUI_PORT}/" "${SERVICE_DIR}/${WEBUI_SERVICE}.service"
systemctl daemon-reload
systemctl enable "${WEBUI_SERVICE}"
systemctl enable "${API_SERVICE}"
systemctl restart "${WEBUI_SERVICE}"
systemctl restart "${API_SERVICE}"

echo "[7/8] Verifikation (Service + HTTP, volle Ausgabe bei Fehlern) ..."
sleep 5
echo "  - Service ${WEBUI_SERVICE}: $(systemctl is-active "${WEBUI_SERVICE}")"
echo "  - Service ${API_SERVICE}: $(systemctl is-active "${API_SERVICE}")"
systemctl is-active --quiet "${WEBUI_SERVICE}" || {
  echo "WebUI-Service läuft NICHT. Volles Journal:" >&2
  journalctl -u "${WEBUI_SERVICE}" --no-pager -n 150 >&2
  exit 1
}
systemctl is-active --quiet "${API_SERVICE}" || {
  echo "API-Service läuft NICHT. Volles Journal:" >&2
  journalctl -u "${API_SERVICE}" --no-pager -n 150 >&2
  exit 1
}
echo "  - HTTP-Check WebUI auf localhost:${WEBUI_PORT} ..."
webui_ok=0
for i in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:${WEBUI_PORT}/" -o /dev/null 2>&1; then
    echo "  - Web UI antwortet (Versuch ${i})."
    webui_ok=1
    break
  fi
  sleep 3
done
if [[ "${webui_ok}" != "1" ]]; then
  echo "Web UI antwortet NICHT nach 20 Versuchen. Journal + curl -v:" >&2
  journalctl -u "${WEBUI_SERVICE}" --no-pager -n 150 >&2
  curl -v "http://127.0.0.1:${WEBUI_PORT}/" >&2 || true
  exit 1
fi
echo "  - HTTP-Check API auf localhost:${API_PORT}/docs ..."
api_ok=0
for i in $(seq 1 10); do
  if curl -fsS "http://127.0.0.1:${API_PORT}/docs" -o /dev/null 2>&1 || \
     curl -fsS "http://127.0.0.1:${API_PORT}/openapi.json" -o /dev/null 2>&1; then
    echo "  - API antwortet (Versuch ${i})."
    api_ok=1
    break
  fi
  sleep 3
done
if [[ "${api_ok}" != "1" ]]; then
  echo "API antwortet NICHT nach 10 Versuchen (weiter geht's, WebUI ist Pflicht). Journal:" >&2
  journalctl -u "${API_SERVICE}" --no-pager -n 100 >&2 || true
fi

CT_IP="$(hostname -I | awk '{print $1}')"
echo "[8/8] Fertig."
echo "=================================================================="
echo " MoneyPrinterTurbo Web UI: http://${CT_IP}:${WEBUI_PORT}"
echo " MoneyPrinterTurbo API   : http://${CT_IP}:${API_PORT}/docs"
echo " Services: systemctl status ${WEBUI_SERVICE} ${API_SERVICE}"
echo " Logs    : journalctl -u ${WEBUI_SERVICE} -f  |  journalctl -u ${API_SERVICE} -f"
echo " Config  : ${SRC_DIR}/config.toml (API-Keys in der Web UI unter Basis-Einstellungen eintragen)"
echo " Reboot-Test: pct reboot <CTID> && nach Neustart URLs erneut öffnen."
echo "=================================================================="
