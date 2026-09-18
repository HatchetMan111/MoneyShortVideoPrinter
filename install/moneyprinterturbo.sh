#!/usr/bin/env bash
# =============================================================================
# MoneyPrinterTurbo — Proxmox LXC Installer (Community-Scripts-Stil)
#
# Einzeiler (auf dem Proxmox-HOST als root ausführen):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MoneyShortVideoPrinter/main/install/moneyprinterturbo.sh)"
#
# Was passiert:
#   1. Fragt CT-ID, Hostname, CPU/RAM/Disk, Storage, Netzwerk, Ports ab
#      (Defaults: 4 vCPU / 8192 MB / 30 GB, WebUI 8501, API 8080)
#   2. Erstellt einen Debian-12-LXC (onboot=1), startet ihn
#   3. Schiebt Wrapper-Dateien (systemd/, setup) per pct push in den Container
#   4. Installiert dort Upstream MoneyPrinterTurbo + Web UI + API als
#      systemd-Services (enable, Restart=always, After=network-online.target)
#   5. Verifiziert Services + HTTP und gibt die finalen URLs aus
#
# Idempotent: belegte CT-ID -> automatisch nächste freie (kein Abbruch, keine Rückfrage).
# Update: MPT_UPDATE=1 voranstellen, dann wird die angegebene CT-ID wiederverwendet.
# Debugging:  DEBUG=1 bash -x install/moneyprinterturbo.sh   (volles Trace-Log)
# Upstream:   https://github.com/harry0703/MoneyPrinterTurbo (Python/Streamlit+FastAPI)
# =============================================================================
set -euo pipefail

# ============================ VARIABLEN (oben) ================================
APP="moneyprinterturbo"
GITHUB_USER="${GITHUB_USER:-HatchetMan111}"
GITHUB_REPO="${GITHUB_REPO:-MoneyShortVideoPrinter}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
TARBALL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"

DEFAULT_CTID="${DEFAULT_CTID:-150}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-moneyprinterturbo}"
DEFAULT_CORES="${DEFAULT_CORES:-4}"
DEFAULT_MEMORY="${DEFAULT_MEMORY:-8192}"   # MB (Whisper + Encoding brauchen RAM)
DEFAULT_DISK="${DEFAULT_DISK:-30}"         # GB (Whisper-Modelle ~3GB + Cache)
DEFAULT_STORAGE="${DEFAULT_STORAGE:-local-lvm}"
DEFAULT_TEMPLATE_STORAGE="${DEFAULT_TEMPLATE_STORAGE:-local}"
DEFAULT_BRIDGE="${DEFAULT_BRIDGE:-vmbr0}"
DEFAULT_WEBUI_PORT="${DEFAULT_WEBUI_PORT:-8501}"
DEFAULT_API_PORT="${DEFAULT_API_PORT:-8080}"
DEBIAN_TEMPLATE_PATTERN="debian-12-standard.*amd64.tar.zst"

# ========================= FEHLERKETTE (voll, nie 1 Zeile) =====================
fail() {
  local code=$?
  echo "==================================================================" >&2
  echo "[FATAL] Installation fehlgeschlagen (Exit-Code: ${code})" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Zeile  : ${BASH_LINENO[0]:-?}" >&2
  echo "--- Funktions-Stack ---" >&2
  local i
  for ((i=0; i<${#FUNCNAME[@]}; i++)); do
    echo "  #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]:-?}" >&2
  done
  echo "--- stdout/stderr-Kontext ---" >&2
  echo "CTID=${CTID:-?} HOSTNAME=${HOSTNAME:-?} WEBUI_PORT=${WEBUI_PORT:-?} API_PORT=${API_PORT:-?}" >&2
  echo "--- Letzte pct-Auszüge (falls vorhanden) ---" >&2
  pct status "${CTID:-?}" 2>&1 | tail -n 20 >&2 || true
  echo "Tipp: Re-Run mit Trace: DEBUG=1 bash -x $0" >&2
  echo "==================================================================" >&2
  exit "${code}"
}
trap fail ERR
[[ "${DEBUG:-0}" == "1" ]] && set -x

# ================================ CHECKS ======================================
[[ "$(id -u)" == "0" ]] || { echo "Bitte als root auf dem Proxmox-Host ausführen." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct nicht gefunden — kein Proxmox-Host?" >&2; exit 1; }
command -v pveam >/dev/null || { echo "pveam nicht gefunden — kein Proxmox-Host?" >&2; exit 1; }

ask() { # ask VAR "Prompt" "Default"
  local __var=$1 prompt=$2 def=$3 val
  if command -v whiptail >/dev/null; then
    val=$(whiptail --inputbox "${prompt}" 8 70 "${def}" 3>&1 1>&2 2>&3) || val="${def}"
  else
    read -rp "${prompt} [${def}]: " val; val="${val:-$def}"
  fi
  printf -v "${__var}" '%s' "${val}"
}

echo "=== ${APP} LXC-Installer (Proxmox VE Community-Scripts-Stil) ==="
echo "Upstream: harry0703/MoneyPrinterTurbo — AI-Kurzvideo-Generator mit Web UI."
ask CTID        "Container-ID (CT-ID)"               "${DEFAULT_CTID}"
ask HOSTNAME    "Hostname"                           "${DEFAULT_HOSTNAME}"
ask CORES       "vCPU-Kerne (min. 4 empfohlen)"      "${DEFAULT_CORES}"
ask MEMORY      "RAM in MB (min. 4096, empf. 8192)" "${DEFAULT_MEMORY}"
ask DISK        "Disk in GB (min. 20, empf. 30)"    "${DEFAULT_DISK}"
ask STORAGE     "Storage für Disk (z. B. local-lvm)" "${DEFAULT_STORAGE}"
ask TPL_STORAGE "Storage für Templates"              "${DEFAULT_TEMPLATE_STORAGE}"
ask BRIDGE      "Netzwerk-Bridge"                    "${DEFAULT_BRIDGE}"
ask WEBUI_PORT  "Web-UI-Port (Streamlit)"            "${DEFAULT_WEBUI_PORT}"
ask API_PORT    "API-Port (FastAPI /docs)"           "${DEFAULT_API_PORT}"
if command -v whiptail >/dev/null; then
  PASSWORD=$(whiptail --passwordbox "Root-Passwort für den Container (leer = zufällig, wird angezeigt)" 8 70 3>&1 1>&2 2>&3) || PASSWORD=""
else
  read -rsp "Root-Passwort für den Container (leer = zufällig): " PASSWORD; echo
fi
if [[ -z "${PASSWORD:-}" ]]; then
  PASSWORD="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
  echo "-> Zufälliges Root-Passwort generiert (wird am Ende angezeigt)."
  GENERATED_PW=1
else
  GENERATED_PW=0
fi

# --- CT-ID belegt? -> automatisch nächste freie nehmen (kein Abbruch) ---------
# Update eines bestehenden Containers geht gezielt via:  MPT_UPDATE=1 <einzeiler>
ct_taken() { # ct_taken ID -> Exit 0 wenn belegt
  pct status "$1" >/dev/null 2>&1 || [[ -f "/etc/pve/lxc/$1.conf" ]]
}
[[ "${CTID}" =~ ^[0-9]+$ ]] || { echo "CT-ID muss numerisch sein (hast: '${CTID}')." >&2; exit 1; }
if ct_taken "${CTID}"; then
  if [[ "${MPT_UPDATE:-0}" == "1" ]]; then
    echo "-> CT ${CTID} existiert + MPT_UPDATE=1: Update-Modus, Container wird wiederverwendet."
    REUSE="update"
  else
    ORIG_CTID="${CTID}"
    while ct_taken "${CTID}"; do
      CTID=$((CTID + 1))
      [[ "${CTID}" -le 999999999 ]] || { echo "Keine freie CT-ID mehr verfügbar." >&2; exit 1; }
    done
    echo "-> CT ${ORIG_CTID} belegt, nehme nächste freie CT-ID ${CTID}."
    REUSE="create"
  fi
else
  REUSE="create"
fi

# --- Template sicherstellen ----------------------------------------------------
echo "-> Suche Debian-12-Template in ${TPL_STORAGE} ..."
TEMPLATE="$(pveam list "${TPL_STORAGE}" 2>/dev/null | grep -oE "${DEBIAN_TEMPLATE_PATTERN}" | sort -V | tail -n 1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  echo "-> Kein Template gefunden, lade aktuelles (pveam update + download) ..."
  pveam update
  TEMPLATE="$(pveam available 2>/dev/null | grep -oE "${DEBIAN_TEMPLATE_PATTERN}" | sort -V | tail -n 1)"
  [[ -n "${TEMPLATE}" ]] || { echo "Kein Debian-12-Template verfügbar." >&2; exit 1; }
  pveam download "${TPL_STORAGE}" "${TEMPLATE}"
fi
echo "-> Template: ${TEMPLATE}"

# --- Container erstellen (nur wenn neu) ----------------------------------------
if [[ "${REUSE}" == "create" ]]; then
  echo "-> Erstelle LXC ${CTID} (${CORES} CPU / ${MEMORY} MB / ${DISK} GB) ..."
  pct create "${CTID}" "${TPL_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --cores "${CORES}" --memory "${MEMORY}" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --password "${PASSWORD}" \
    --onboot 1 --start 1 \
    --unprivileged 1 \
    --features nesting=1
  # onboot doppelt absichern (Config-Key)
  grep -q "^onboot:" "/etc/pve/lxc/${CTID}.conf" \
    || echo "onboot: 1" >> "/etc/pve/lxc/${CTID}.conf"
  echo "-> Warte auf Container-Boot ..."
  sleep 8
else
  pct start "${CTID}" 2>/dev/null || true
  sleep 5
fi

pct exec "${CTID}" -- bash -c "echo Container erreichbar: \$(hostname) \$(hostname -I | awk '{print \$1}')"

# --- Wrapper-Dateien in den Container schieben ----------------------------------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap 'cleanup; fail' ERR
echo "-> Lade Wrapper-Repo (${GITHUB_USER}/${GITHUB_REPO}@${GITHUB_BRANCH}) ..."
if command -v git >/dev/null; then
  git clone --depth 1 --branch "${GITHUB_BRANCH}" \
    "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "${WORKDIR}/repo"
else
  cd "${WORKDIR}" && wget -qO repo.tar.gz "${TARBALL}" && tar xzf repo.tar.gz
  mv "${WORKDIR}/${GITHUB_REPO}-${GITHUB_BRANCH}" "${WORKDIR}/repo"
fi

echo "-> Push nach CT:${CTID} ..."
pct exec "${CTID}" -- mkdir -p /opt/moneyprinterturbo/repo-files/systemd
pct push "${CTID}" "${WORKDIR}/repo/systemd/moneyprinter-webui.service" \
  /opt/moneyprinterturbo/repo-files/systemd/moneyprinter-webui.service
pct push "${CTID}" "${WORKDIR}/repo/systemd/moneyprinter-api.service" \
  /opt/moneyprinterturbo/repo-files/systemd/moneyprinter-api.service
pct push "${CTID}" "${WORKDIR}/repo/install/setup-container.sh" \
  /opt/moneyprinterturbo/setup-container.sh
pct exec "${CTID}" -- chmod +x /opt/moneyprinterturbo/setup-container.sh

# --- Setup IM Container ausführen ------------------------------------------------
echo "-> Führe Setup im Container aus (dauert einige Minuten: uv sync + ffmpeg) ..."
pct exec "${CTID}" -- env WEBUI_PORT="${WEBUI_PORT}" API_PORT="${API_PORT}" DEBUG="${DEBUG:-0}" \
  bash /opt/moneyprinterturbo/setup-container.sh

# --- Verifikation vom Host -------------------------------------------------------
echo "-> Verifikation ..."
pct exec "${CTID}" -- systemctl is-active --quiet moneyprinter-webui \
  || { echo "WebUI-Service läuft NICHT. Log:" >&2
       pct exec "${CTID}" -- journalctl -u moneyprinter-webui --no-pager -n 100 >&2
       exit 1; }
pct exec "${CTID}" -- systemctl is-active --quiet moneyprinter-api \
  || { echo "API-Service läuft NICHT (Warnung). Log:" >&2
       pct exec "${CTID}" -- journalctl -u moneyprinter-api --no-pager -n 100 >&2 || true; }
CT_IP="$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')"
echo "-> HTTP-Check http://${CT_IP}:${WEBUI_PORT}/ ..."
curl -fsS "http://${CT_IP}:${WEBUI_PORT}/" -o /dev/null || {
  echo "HTTP-Check fehlgeschlagen (Container-lokal lief er — evtl. Firewall/Netz)." >&2
  pct exec "${CTID}" -- journalctl -u moneyprinter-webui --no-pager -n 100 >&2
  exit 1
}
cleanup
trap fail ERR

echo "=================================================================="
echo " ✅ Fertig! MoneyPrinterTurbo Web UI: http://${CT_IP}:${WEBUI_PORT}"
echo "    API (Docs): http://${CT_IP}:${API_PORT}/docs"
echo "    CT-ID ${CTID} (${HOSTNAME}), onboot=1, Services=moneyprinter-webui+moneyprinter-api"
if [[ "${GENERATED_PW}" == "1" ]]; then
  echo "    Root-Passwort (zufällig): ${PASSWORD}"
fi
echo "    Update : Einzeiler erneut laufen lassen (Update-Modus)"
echo "    Logs   : pct exec ${CTID} -- journalctl -u moneyprinter-webui -f"
echo "    API-Log: pct exec ${CTID} -- journalctl -u moneyprinter-api -f"
echo "    Löschen: pct stop ${CTID} && pct destroy ${CTID}"
echo "=================================================================="
