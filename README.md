# MoneyPrinterTurbo — Proxmox LXC Installer + Web UI

Lokale MoneyPrinterTurbo-Installation als **LXC-Container auf Proxmox VE** im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/):
**Einzeiler auf dem Host → Container + App + Web UI + systemd läuft.**

> Upstream: [harry0703/MoneyPrinterTurbo](https://github.com/harry0703/MoneyPrinterTurbo)
> (All-in-One AI-Kurzvideo-Generator, Python: Streamlit-WebUI + FastAPI).
> Upstream hat bereits eine Web UI, in der man **alles einstellen kann**
> (Video-Thema, LLM-Provider + API-Keys, Video-Quellen, TTS/Stimmen, Subtitles,
> BGM, Aspect 9:16/16:9/1:1) — dieses Repo automatisiert nur
> **Installation + systemd + Verifikation** im LXC.

| Feld | Wert |
|---|---|
| App-Name | `moneyprinterturbo` |
| Zweck | KI-Kurzvideos lokal generieren (Skript→Vertonung→Footage→Subtitles→Schnitt), Bedienung per Web UI |
| Tech-Stack | Python 3.11 / Streamlit (WebUI) + FastAPI/Uvicorn (API), `uv`, ffmpeg |
| Upstream-Repo | https://github.com/harry0703/MoneyPrinterTurbo |
| GitHub-Repo (dieser Installer) | `HatchetMan111/MoneyShortVideoPrinter` |
| Web-UI-Port | `8501` (Streamlit, konfigurierbar) |
| API-Port | `8080` (FastAPI `/docs`, konfigurierbar) |
| Default-Ressourcen | 4 vCPU · 8192 MB RAM · 30 GB Disk · Debian 12 LXC, `onboot: 1` |

## 1 · Installation (Einzeiler auf dem Proxmox-Host als root)

> Direkt auf dem Proxmox-Host als root ausführen — keine Anpassung nötig.

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MoneyShortVideoPrinter/main/install/moneyprinterturbo.sh)"
```

Das Script fragt interaktiv ab (mit sinnvollen Defaults):
`CT-ID` (150, **belegt → automatisch nächste freie, kein Abbruch**) · Hostname · vCPU (4) · RAM (8192) · Disk (30G) ·
Storage (`local-lvm`) · Template-Storage (`local`) · Bridge (`vmbr0`, DHCP) ·
WebUI-Port (8501) · API-Port (8080) · Root-Passwort (leer = zufällig).

Danach läuft vollautomatisch:
1. Debian-12-Template sicherstellen (`pveam download` falls nötig)
2. `pct create` + `onboot: 1` + Start (unprivilegiert, `nesting=1`)
3. Wrapper-Dateien per `pct push` in den Container
4. `install/setup-container.sh` im Container: Python 3.11, `uv`, `ffmpeg`,
   Upstream-Clone, `uv sync --frozen`, `config.toml` (nur falls fehlend,
   `listen_host=0.0.0.0`), systemd-Units `moneyprinter-webui.service` +
   `moneyprinter-api.service` (`enable`, `Restart=always`, `After=network-online.target`)
5. Selbst-Verifikation: `systemctl is-active` (beide) + HTTP-Checks
   (`localhost:8501/` + `localhost:8080/docs`)

**Erwartete Ausgabe (Ende):**

```text
[7/8] Verifikation (Service + HTTP, volle Ausgabe bei Fehlern) ...
  - Service moneyprinter-webui: active
  - Service moneyprinter-api: active
  - HTTP-Check WebUI auf localhost:8501 ...
  - Web UI antwortet (Versuch 2).
  - HTTP-Check API auf localhost:8080/docs ...
  - API antwortet (Versuch 1).
[8/8] Fertig.
==================================================================
 MoneyPrinterTurbo Web UI: http://192.168.1.50:8501
 MoneyPrinterTurbo API   : http://192.168.1.50:8080/docs
 ...
==================================================================
 ✅ Fertig! MoneyPrinterTurbo Web UI: http://192.168.1.50:8501
    API (Docs): http://192.168.1.50:8080/docs
    CT-ID 150 (moneyprinterturbo), onboot=1, Services=moneyprinter-webui+moneyprinter-api
==================================================================
```

Web UI öffnen → **Schritt 1**: Basis-Einstellungen → LLM-Provider + API-Key
(z. B. Kimi/Moonshot, OpenAI, Gemini — Edge-TTS braucht keinen Key) →
**Schritt 2**: Video-Thema eingeben → generieren → Vorschau + Download.
Ohne Cloud-Keys geht nur: Edge-TTS + lokale/pexels-Materialien (Pexels braucht
gratis Key unter pexels.com/api).

## 2 · Update

Für ein Update `MPT_UPDATE=1` voranstellen — dann wird die angegebene CT-ID
wiederverwendet (Container bleibt, Upstream-Code + Deps werden aktualisiert,
`config.toml` bleibt erhalten, Services restarten). Idempotent, mehrfach lauffähig.
Ohne `MPT_UPDATE=1` nimmt der Installer bei belegter CT-ID automatisch die
nächste freie (kein Abbruch, keine Rückfrage).

```bash
MPT_UPDATE=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MoneyShortVideoPrinter/main/install/moneyprinterturbo.sh)"
# -> "CT 150 existiert + MPT_UPDATE=1: Update-Modus ..."
```

## 3 · Deinstallation

```bash
pct stop 150 && pct destroy 150
```

## 4 · Reboot-Test (Nachweis Reboot-Sicherheit)

```bash
pct reboot 150
sleep 30
pct exec 150 -- systemctl is-active moneyprinter-webui   # -> active
pct exec 150 -- systemctl is-active moneyprinter-api     # -> active
curl -fsS http://<LXC-IP>:8501/ -o /dev/null && echo "WebUI OK"
curl -fsS http://<LXC-IP>:8080/docs -o /dev/null && echo "API OK"
# Web UI im Browser neu laden -> wieder erreichbar
```

Container startet durch `onboot: 1` nach Host-Reboot automatisch;
Web UI + API durch `systemctl enable` + `Restart=always`.

Protokolliere den Test für die Deliverables, z. B.:

```bash
(pct reboot 150 && sleep 30 && pct exec 150 -- systemctl is-active moneyprinter-webui && curl -fsS http://<LXC-IP>:8501/ -o /dev/null) 2>&1 | tee reboot-test.log
```

## 5 · Debugging (volle Fehlerkette, nie nur letzte Zeile)

- Installer mit Trace: `DEBUG=1 bash -x install/moneyprinterturbo.sh`
- Setup im Container: `DEBUG=1 bash -x /opt/moneyprinterturbo/setup-container.sh`
- Service-Logs (voll): `pct exec 150 -- journalctl -u moneyprinter-webui --no-pager -n 150`
- API-Logs: `pct exec 150 -- journalctl -u moneyprinter-api --no-pager -n 150`
- Beide Skripte nutzen `set -euo pipefail` + `trap ... ERR` mit
  Exit-Code, Befehl, Zeile, Funktions-Stack und relevanten Log-Auszügen.

## 6 · Repo-Struktur

```text
install/moneyprinterturbo.sh      Host-Installer (Einzeiler, Community-Scripts-Stil, Variablen oben)
install/setup-container.sh        Setup IM Container (idempotent, set -euo pipefail)
systemd/moneyprinter-webui.service  systemd-Unit Streamlit :8501 (enable, Restart=always)
systemd/moneyprinter-api.service    systemd-Unit FastAPI :8080 (enable, Restart=always)
README.md                         dieser Einzeiler + Update/Deinstall/Reboot-Nachweis
```

## 7 · Hinweise

- **LXC vs. VM:** Standard ist LXC (leicht, ideal für Cloud-LLMs + Cloud-TTS +
  Online-Footage). Nur wer **GPU** (schnelleres `faster-whisper` / Encoding)
  oder sehr große lokale Modelle will, sollte stattdessen eine **VM mit
  GPU-Passthrough** und mehr RAM nehmen — `setup-container.sh` läuft dort
  unverändert (Debian 12 vorausgesetzt).
- **Ressourcen:** Upstream-Minimum 4 CPU / 4 GB RAM; Whisper `large-v3` (~3 GB)
  + Videocache brauchen Platz — daher Default 4 vCPU / 8 GB / 30 GB.
  Für Batch-Betrieb 8 vCPU / 16 GB erwägen.
- **Erster Whisper-Lauf** lädt das Modell von Hugging Face (~3 GB) — beim
  ersten Transkript-Job Geduld, ggf. `large-v3-turbo` (~1,6 GB) in `config.toml`.
- **ffmpeg:** wird per apt installiert; falls Upstream `IMAGEIO_FFMPEG_EXE`
  verlangt, Pfad via `which ffmpeg` in `config.toml` (`ffmpeg_path`) setzen.
- **Kosten:** Cloud-LLMs/TTS/Footage-APIs sind teils kostenpflichtig —
  Keys und Limits in der Web UI prüfen.
