#!/usr/bin/env bash
#
# ACE-Step 1.5 Proxmox VM Installer – im Stil der Proxmox VE Community Scripts
#
# App:      ACE-Step 1.5 – Open-Source Music Generation (Text2Music, Cover, Repaint, Gradio WebUI)
# Upstream: https://github.com/ace-step/ACE-Step-1.5
# Stack:    Python 3.11-3.12 + uv + PyTorch + Gradio (:7860), nativ ohne Docker
# Laeuft:   vollstaendig lokal in einer KVM-VM, keine Cloud noetig
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Gast!)
# Modus:    VM-first (leistungshungrig: DiT 2B/XL-4B + LM, 24 GB VRAM empfohlen).
#           Default CPU (funktioniert ueberall, langsam), optional --gpu PCI-ID fuer NVIDIA-Passthrough.
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AceStepMusic/main/install/ace-step.sh)" _ --sshkey ~/.ssh/id_ed25519.pub --ip 192.168.178.50/24 --gateway 192.168.178.1
#   VMID=150 CORES=6 RAM=16384 DISK=60 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AceStepMusic/main/install/ace-step.sh)"
#   bash ace-step.sh --vmid 150 --cores 4 --memory 16384 --disk 60 --bridge vmbr0 --debug
#   bash ace-step.sh --gpu 0000:01:00 --sshkey ~/.ssh/id_rsa.pub   # NVIDIA-Passthrough + Key
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="ace-step"                                  # VM-Name + Service-Name
APP_PORT="7860"                                 # Gradio WebUI
UPSTREAM_REPO="https://github.com/ace-step/ACE-Step-1.5"
INSTALLER_REPO="https://github.com/HatchetMan111/AceStepMusic"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/AceStepMusic/main/systemd/ace-step.service"

DEFAULT_CORES="4"                               # vCPU (ACE-Step braucht 4+, 8 empfohlen)
DEFAULT_RAM="16384"                             # RAM in MB (16 GB Default, 8 GB Minimum)
DEFAULT_DISK="60"                               # Disk in GB (Modelle 5-15 GB + Torch + uv-Cache)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE=""                              # leer = auto (bevorzugt local-lvm)
DEFAULT_CIUSER="ace"
DEBIAN_VERSION="12"
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
IMAGE_DIR="/var/lib/vz/template/qcow"

APP_USER="ace"
APP_DIR="/opt/ace-step"

# Umgebungs-Overrides: VMID=150 CORES=6 RAM=16384 DISK=80 ./ace-step.sh
VMID_ARG="${VMID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Caller, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Aufrufstapel: ${FUNCNAME[*]:-main}"; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox VM Installer (VM-first, CPU-Default + optionaler NVIDIA-Passthrough)

Usage:
  bash ace-step.sh [OPTIONEN]
  VMID=150 bash ace-step.sh
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AceStepMusic/main/install/ace-step.sh)" _ --sshkey ~/.ssh/id_ed25519.pub --ip 192.168.178.50/24 --gateway 192.168.178.1

Optionen:
  --vmid ID            VM-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       Disk-Storage (Default: auto, bevorzugt local-lvm)
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --gpu PCI            NVIDIA-Passthrough, z.B. 0000:01:00 (Default: kein Passthrough = CPU-Modus)
  --sshkey PATH        SSH Public Key (optional: ohne Flag wird ein Host-Key genommen oder erzeugt)
  --ciuser NAME        Cloud-Init-User (Default: ${DEFAULT_CIUSER})
  --ip CIDR/IP          z.B. --ip 192.168.178.50/24 (+ --gateway): statisch per Cloud-Init,
                     als reine IP auch Update-Override (ueberspringt Agent-Wait)
  --gateway IP         Gateway bei statischer IP
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
VMID="$VMID_ARG" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="$DEFAULT_STORAGE" BRIDGE="$DEFAULT_BRIDGE" GPU_PCI="" SSHKEY="" CIUSER="$DEFAULT_CIUSER"
IPCFG="dhcp" GATEWAY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --gpu) GPU_PCI="$2"; shift 2;;
    --sshkey|--ssh-key) SSHKEY="$2"; shift 2;;
    --ciuser) CIUSER="$2"; shift 2;;
    --ip) IPCFG="$2"; shift 2;;
    --gateway|--gw) GATEWAY="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    _) shift;;  # Platzhalter fuer Einzeiler-Trick: ...)" _ --flags
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

MODE="cpu"
[[ -n "$GPU_PCI" ]] && MODE="cuda"

# --ip normalisieren: Proxmox braucht CIDR (mit Maske) bei Erstellung.
IPCFG="${IPCFG#ip=}"
if [[ "$IPCFG" != "dhcp" && "$IPCFG" != */* ]]; then
  if [[ "$IPCFG" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IPCFG="${IPCFG}/24"
    msg_warn "--ip ohne Netzmaske – nutze $IPCFG (Default /24)."
  else
    msg_error "--ip ungültig: '$IPCFG' (erwartet: dhcp, 192.168.178.50 oder 192.168.178.50/24)."
    exit 1
  fi
fi
VMID_EXPLICIT=0
[[ -n "$VMID_ARG" ]] && VMID_EXPLICIT=1

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v qm >/dev/null || { msg_error "qm nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }
command -v pvesm >/dev/null || { msg_error "pvesm nicht gefunden."; exit 1; }

if [[ -z "$VMID" ]]; then
  VMID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie VM-ID: $VMID"
else
  if qm status "$VMID" >/dev/null 2>&1; then
    if [[ "$VMID_EXPLICIT" == "1" ]]; then
      msg_info "VM $VMID existiert – Update-Modus (idempotent)."
    else
      FREE_ID="$(pvesh get /cluster/nextid)"
      msg_warn "VMID $VMID belegt – weiche auf freie ID $FREE_ID aus."
      VMID="$FREE_ID"
    fi
  fi
fi

if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status 2>/dev/null | grep -q '^local-lvm[[:space:]]'; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content images 2>/dev/null | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein Disk-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Bridge: $BRIDGE | Modus: $MODE | VM-Name: $APP"

[[ "$RAM" -ge 8192 ]] || msg_warn "Unter 8192 MB wird ACE-Step kaum starten (gewaehlt: $RAM)."
[[ "$CORES" -ge 4 ]] || msg_warn "Unter 4 vCPU wird Torch sehr langsam (gewaehlt: $CORES)."
[[ "$DISK" -ge 40 ]] || msg_warn "Unter 40 GB wird es mit Modellen + Torch eng (gewaehlt: $DISK)."

HOST_FREE_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 0)"
if [[ "$HOST_FREE_MB" -gt 0 && "$RAM" -gt "$HOST_FREE_MB" ]]; then
  msg_error "Host hat nur ${HOST_FREE_MB} MB frei, VM will ${RAM} MB -> qm start wuerde scheitern."
  msg_error "Mit weniger RAM erneut starten, z.B.: --memory 8192 (Minimum) oder --memory $HOST_FREE_MB"
  exit 1
fi

# SSH-Key: optional – fehlt --sshkey, wird automatisch ein vorhandener
# Host-Key genommen oder einer erzeugt, damit der blosse Einzeiler
# ohne Flags funktioniert (Debian-Cloud-Images brauchen Key-Login).
if [[ -z "${SSHKEY:-}" ]]; then
  for _k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    if [[ -f "$_k" ]]; then SSHKEY="$_k"; break; fi
  done
  if [[ -z "${SSHKEY:-}" ]]; then
    msg_info "Kein SSH-Key auf dem Host – erzeuge ~/.ssh/id_ed25519 (ohne Passphrase) ..."
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -C "ace-step-proxmox" \
      || { msg_error "ssh-keygen scheiterte – bitte manuell erzeugen und --sshkey PATH uebergeben."; exit 1; }
    SSHKEY="$HOME/.ssh/id_ed25519.pub"
  fi
  msg_info "SSH-Key (auto): $SSHKEY"
fi
[[ -f "$SSHKEY" ]] || { msg_error "SSH-Key nicht gefunden: $SSHKEY"; exit 1; }

# ---------------------------------------------------------------------------
# 2. Cloud-Image sicherstellen
# ---------------------------------------------------------------------------
mkdir -p "$IMAGE_DIR"
IMAGE_FILE="$IMAGE_DIR/debian-${DEBIAN_VERSION}-generic-amd64-${APP}.qcow2"
if [[ ! -s "$IMAGE_FILE" ]]; then
  msg_info "Lade Debian $DEBIAN_VERSION Cloud-Image ..."
  if command -v wget >/dev/null; then
    wget -O "${IMAGE_FILE}.part" "$IMAGE_URL"
  else
    curl -fsSL -o "${IMAGE_FILE}.part" "$IMAGE_URL"
  fi
  mv -f "${IMAGE_FILE}.part" "$IMAGE_FILE"
else
  msg_ok "Cloud-Image vorhanden: $IMAGE_FILE"
fi

# ---------------------------------------------------------------------------
# 3. VM erstellen (idempotent: existiert die ID, wird nur Gast provisioniert)
# ---------------------------------------------------------------------------
CIPASS=""
if qm status "$VMID" >/dev/null 2>&1; then
  msg_warn "VM $VMID existiert – ueberspringe Erstellung (Update-Modus)."
else
  CIPASS="$(openssl rand -hex 12)"
  CIPASS="${CIPASS:0:20}"
  IPCONFIG="ip=dhcp"
  [[ "$IPCFG" != "dhcp" ]] && IPCONFIG="ip=$IPCFG"
  [[ -n "$GATEWAY" ]] && IPCONFIG="$IPCONFIG,gw=$GATEWAY"
  msg_info "Erstelle VM $VMID ($APP): $CORES vCPU / $RAM MB / ${DISK}G ..."
  qm create "$VMID" \
    --name "$APP" --ostype l26 \
    --cores "$CORES" --memory "$RAM" --balloon 0 \
    --agent enabled=1 \
    --onboot 1 \
    --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=${BRIDGE}" \
    --ide2 "${STORAGE_ARG}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket --vga serial0 \
    --ciuser "$CIUSER" --cipassword "$CIPASS" \
    --ipconfig0 "$IPCONFIG" \
    --nameserver "1.1.1.1 8.8.8.8"
  if [[ -n "$SSHKEY" ]]; then
    qm set "$VMID" --sshkey "$SSHKEY"
    qm config "$VMID" | grep -qi "sshkeys" \
      || { msg_error "SSH-Key wurde nicht in qm config uebernommen – Abbruch vor Disk-Import."; exit 1; }
    msg_ok "SSH-Key in Cloud-Init-Seed uebernommen."
  fi
  if [[ -n "$GPU_PCI" ]]; then
    msg_info "Aktiviere GPU-Passthrough $GPU_PCI ..."
    qm set "$VMID" --hostpci0 "${GPU_PCI},pcie=1" \
      || msg_warn "hostpci0 fehlgeschlagen – fahre ohne Passthrough fort (CPU-Fallback)."
  fi
  msg_info "Importiere Disk (${DISK}G) ..."
  qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE_ARG"
  UNUSED="$(qm config "$VMID" | grep -oP '^unused0: \K[^,]+' | head -n1)"
  [[ -n "${UNUSED:-}" ]] || { msg_error "unused0 nach importdisk nicht gefunden."; exit 1; }
  qm set "$VMID" --scsi0 "$UNUSED"
  qm resize "$VMID" scsi0 "${DISK}G" || msg_warn "resize uebersprungen (evtl. bereits $DISK G)."
  msg_ok "VM $VMID erstellt (onboot=1, agent=1)."
  qm start "$VMID" \
    || { msg_error "qm start scheiterte (oft RAM/Storage voll). free -m und pvesm status pruefen."; exit 1; }
  qm status "$VMID" | grep -q "status: running" \
    || { msg_error "VM $VMID laeuft nicht nach qm start."; exit 1; }
  msg_ok "VM $VMID laeuft."
fi

if [[ -n "$GPU_PCI" ]]; then
  qm config "$VMID" | grep -q "hostpci0" || qm set "$VMID" --hostpci0 "${GPU_PCI},pcie=1" || true
fi
qm set "$VMID" --sshkey "$SSHKEY" 2>/dev/null || msg_warn "sshkey setzen fehlgeschlagen – weiter."
qm config "$VMID" | grep -qi "sshkeys" && msg_ok "SSH-Key in qm config vorhanden." \
  || msg_warn "Kein sshkeys in qm config – SSH wird evtl. fehlschlagen."
qm start "$VMID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Gast-IP + SSH warten (agent-unabhaengig: Ping + Agent + ARP/DHCP)
# ---------------------------------------------------------------------------
msg_info "Warte auf Gast-IP (max. 10 Min, Agent + ARP/DHCP-Fallback) ..."
VM_IP=""
STATIC_IP="$(printf '%s' "$IPCFG" | grep -oP '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [[ -n "${STATIC_IP:-}" ]]; then
  VM_IP="$STATIC_IP"
  msg_warn "Statische IP per --ip: $VM_IP (Agent-Wait uebersprungen, warte auf Ping/SSH nach Boot)."
fi
AGENT_OK=0
GUEST_MAC="$(qm config "$VMID" 2>/dev/null | grep -oP 'net0:.*?addr(e?ss)?=\K[0-9A-Fa-f:]{17}|net0:.*?\b\K[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}' | head -n1 || true)"
[[ -n "${GUEST_MAC:-}" ]] && msg_info "Gast-MAC: $GUEST_MAC"
if [[ -z "${VM_IP:-}" ]]; then
for i in $(seq 1 60); do
  sleep 10
  if ! qm status "$VMID" 2>/dev/null | grep -q "status: running"; then
    msg_warn "VM nicht running (Versuch $i) – starte ..."; qm start "$VMID" 2>/dev/null || true
  fi
  if qm agent "$VMID" ping >/dev/null 2>&1; then
    [[ "$AGENT_OK" == "0" ]] && msg_ok "Guest-Agent antwortet (Versuch $i/60)."
    AGENT_OK=1
  fi
  VM_IP="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | grep -oP '"ip-address"\s*:\s*"\K(?!127\.|::1|fe80)[0-9a-fA-F:.]+' | grep -v '^fe80' | head -n1 || true)"
  if [[ -z "${VM_IP:-}" ]]; then
    VM_IP="$(qm agent "$VMID" network-get-interfaces 2>/dev/null | grep -oP '"ip-address"\s*:\s*"\K(?!127\.|::1|fe80)[0-9a-fA-F:.]+' | grep -v '^fe80' | head -n1 || true)"
  fi
  if [[ -z "${VM_IP:-}" && "$AGENT_OK" == "1" ]]; then
    VM_IP="$(qm guest exec "$VMID" -- hostname -I 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
  if [[ -z "${VM_IP:-}" && -n "${GUEST_MAC:-}" ]]; then
    VM_IP="$(ip neigh show dev "$BRIDGE" 2>/dev/null | grep -i "$GUEST_MAC" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
  if [[ -z "${VM_IP:-}" && -n "${GUEST_MAC:-}" ]]; then
    VM_IP="$(grep -ih "$GUEST_MAC" /var/lib/misc/dnsmasq.leases /var/lib/dhcp/dhcpd.leases 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
  if [[ -n "${VM_IP:-}" ]]; then
    msg_ok "Gast-IP via Fallback gefunden: $VM_IP"
    break
  fi
  [[ $((i % 6)) == 0 ]] && msg_info "noch keine IP nach $((i * 10))s (Agent: $([[ "$AGENT_OK" == "1" ]] && echo ok || echo wartend), ARP/DHCP: leer) ..."
done
fi
if [[ -z "${VM_IP:-}" ]]; then
  msg_error "Keine Gast-IP nach 10 Min. Diagnose-Dump:"
  msg_error "--- qm status ---"; qm status "$VMID" || true
  msg_error "--- qm agent ping ---"; qm agent "$VMID" ping || true
  msg_error "--- network-get-interfaces (roh) ---"; qm guest cmd "$VMID" network-get-interfaces || true
  msg_error "--- qm config ---"; qm config "$VMID" || true
  msg_error "--- ARP auf $BRIDGE ---"; ip neigh show dev "$BRIDGE" 2>/dev/null || true
  msg_error "Naechste Schritte:"
  msg_error " 1) qm terminal $VMID -> login ace -> ip -4 addr; systemctl status qemu-guest-agent"
  msg_error " 2) Bleibt ip leer: DHCP auf $BRIDGE fehlt -> statische IP setzen und Update-Modus:"
  msg_error "    bash ace-step.sh --vmid $VMID --ip <GEFUNDENE-ODER-GEWUENSCHTE-IP>"
  msg_error " 3) Update-Modus: bash ace-step.sh --vmid $VMID (VM bleibt bestehen, idempotent)."
  exit 1
fi
msg_ok "Gast-IP: $VM_IP"

SSH_BASE=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error -o ConnectTimeout=10)
SSH_TARGET="${CIUSER}@${VM_IP}"
if [[ -n "$SSHKEY" ]]; then
  SSH_KEY_PRIV="${SSHKEY%.pub}"
  if [[ -f "$SSH_KEY_PRIV" ]]; then
    SSH_BASE+=( -i "$SSH_KEY_PRIV" )
  fi
  SSH_CMD=("${SSH_BASE[@]}" "$SSH_TARGET")
else
  if command -v sshpass >/dev/null 2>&1 && [[ -n "${CIPASS:-}" ]]; then
    SSH_CMD=(sshpass -p "$CIPASS" "${SSH_BASE[@]}" "$SSH_TARGET")
  else
    msg_warn "Kein --sshkey und kein sshpass: versuche Standard-SSH."
    SSH_CMD=("${SSH_BASE[@]}" "$SSH_TARGET")
  fi
fi

msg_info "Warte auf SSH ..."
for _ in $(seq 1 30); do
  if "${SSH_CMD[@]}" true >/dev/null 2>&1; then break; fi
  sleep 10
done
"${SSH_CMD[@]}" true || { msg_error "SSH zu $SSH_TARGET fehlgeschlagen. Key pruefen (ssh -vvv)."; exit 1; }
msg_ok "SSH bereit: $SSH_TARGET"

# ---------------------------------------------------------------------------
# 5. ACE-Step im Gast (via SSH, idempotent)
# ---------------------------------------------------------------------------
msg_info "Provisioniere ACE-Step 1.5 im Gast (uv sync, Gradio :7860, Modus $MODE) ..."

"${SSH_CMD[@]}" bash -s -- "$MODE" <<'GUEST_EOF'
set -euo pipefail
MODE="$1"
export DEBIAN_FRONTEND=noninteractive
for _ in $(seq 1 30); do
  sudo fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  echo "warte auf apt-lock (cloud-init package_upgrade laeuft) ..."
  sleep 10
done
sudo apt-get update
sudo apt-get -o DPkg::Lock::Timeout=300 install -y git curl ca-certificates ffmpeg python3-dev build-essential
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
export PATH="$HOME/.local/bin:$PATH"
if [ ! -d /opt/ace-step/.git ]; then
  sudo rm -rf /opt/ace-step
  sudo mkdir -p /opt/ace-step
  sudo chown "$(whoami)":"$(whoami)" /opt/ace-step
  git clone https://github.com/ace-step/ACE-Step-1.5 /opt/ace-step
else
  git -C /opt/ace-step pull --ff-only || true
fi
test -f /opt/ace-step/pyproject.toml
cd /opt/ace-step
# Python 3.12 bevorzugt (Upstream: 3.11-3.12), Fallback 3.11
uv sync --python 3.12 || uv sync --python 3.11 || uv sync
test -x /opt/ace-step/.venv/bin/acestep
# .env aus Beispiel anlegen (bleibt bei Updates erhalten)
if [ ! -f /opt/ace-step/.env ] && [ -f /opt/ace-step/.env.example ]; then
  cp /opt/ace-step/.env.example /opt/ace-step/.env
fi
# Modelle laden beim Erststart automatisch nach (best-effort Vorab-Download nur Warnung)
echo "INFO: Modelle (DiT + LM) laden beim ersten Start automatisch nach – erster Start dauert."
GUEST_EOF

# systemd-Unit aus Installer-Repo uebernehmen (Fallback: Inline-Unit)
if "${SSH_CMD[@]}" "curl -fsSL -o /tmp/ace-step.service '$SERVICE_URL'"; then
  msg_ok "ace-step.service aus Repo uebernommen."
  "${SSH_CMD[@]}" "sudo mv /tmp/ace-step.service /etc/systemd/system/ace-step.service"
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  "${SSH_CMD[@]}" "sudo tee /etc/systemd/system/ace-step.service" <<UNIT
[Unit]
Description=ACE-Step 1.5 WebUI (Gradio :7860)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CIUSER}
WorkingDirectory=${APP_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=GRADIO_SERVER_NAME=0.0.0.0
Environment=GRADIO_SERVER_PORT=${APP_PORT}
Environment=PORT=${APP_PORT}
ExecStart=${APP_DIR}/.venv/bin/acestep
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
fi

"${SSH_CMD[@]}" "sudo systemctl daemon-reload"
"${SSH_CMD[@]}" "sudo systemctl enable --now ace-step"

# ---------------------------------------------------------------------------
# 6. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
"${SSH_CMD[@]}" "systemctl is-active ace-step" || { msg_error "systemd-Service ace-step ist nicht active."; "${SSH_CMD[@]}" "systemctl status ace-step --no-pager" || true; exit 1; }
msg_ok "Service laeuft (systemctl is-active ace-step = active)."

msg_info "Warte auf Web UI (max. 10 Min, erster Start laedt Modelle) ..."
WEB_OK=0
for _ in $(seq 1 60); do
  if "${SSH_CMD[@]}" "curl -fs -m 10 'http://localhost:${APP_PORT}/' >/dev/null 2>&1"; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/."; "${SSH_CMD[@]}" "systemctl status ace-step --no-pager" || true; "${SSH_CMD[@]}" "journalctl -u ace-step --no-pager -n 100" || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/)."

qm config "$VMID" | grep -q "onboot: 1" && msg_ok "onboot=1 gesetzt." || msg_warn "onboot nicht 1 – bitte pruefen."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : ACE-Step 1.5 – Open-Source Music Generation"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Installer    : $INSTALLER_REPO"
echo "  VM           : $VMID (Name: $APP, onboot=1, Modus: $MODE)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${VM_IP}:${APP_PORT}"
echo "  SSH          : ssh ${CIUSER}@${VM_IP}"
echo "  CIPasswort   : ${CIPASS:-<bestehende VM, unveraendert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status ace-step  (im Gast)"
echo "  Modelle      : DiT 2B/XL + LM laden beim Erststart auto nach (HF-Cache im Gast)"
echo "  Update       : Skript erneut laufen lassen (idempotent, git pull + uv sync + restart)"
echo "  Deinstall    : qm stop $VMID && qm destroy $VMID"
echo "  Reboot-Test  : qm reboot $VMID && sleep 120 && curl -fs http://${VM_IP}:${APP_PORT}/"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
