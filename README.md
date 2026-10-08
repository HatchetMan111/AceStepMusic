# ACE-Step 1.5 auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil, VM-first)

> Upstream-App (kein Teil dieses Repos): `https://github.com/ace-step/ACE-Step-1.5`
> (Open-Source Music Generation, DiT 2B / XL-4B + LM 0.6B/1.7B/4B, Text2Music, Cover, Repaint, Gradio WebUI)
> Dieses Repo enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft nativ (Python 3.12 + uv + PyTorch, ohne Docker) – vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AceStepMusic/main/install/ace-step.sh)"
```

Das war's: SSH-Key wird automatisch genommen oder erzeugt, IP per DHCP,
VM-ID ist immer die nächste freie. Alles darunter ist optional.

<details>
<summary>Optional: mit Flags (statische IP, GPU, eigene Ressourcen)</summary>

```bash
# Mit statischer IP (empfohlen wenn DHCP klemmt, z.B. FritzBox-Netz).
# Das `_` nach dem schließenden `"` ist Absicht – ohne es kommen
# die Flags bei `bash -c` nicht an:
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AceStepMusic/main/install/ace-step.sh)" _ --ip 192.168.178.50/24 --gateway 192.168.178.1
```

```bash
VMID=150 CORES=8 RAM=16384 DISK=60 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AceStepMusic/main/install/ace-step.sh)"
bash ace-step.sh --vmid 150 --cores 4 --memory 16384 --disk 60 --bridge vmbr0 --storage local-lvm
bash ace-step.sh --gpu 0000:01:00   # NVIDIA-Passthrough (sonst CPU-Modus)
bash ace-step.sh --sshkey ~/.ssh/id_rsa.pub   # eigener Key statt Auto-Key
bash ace-step.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/ace-step-install-*.log
```

</details>

| Eigenschaft | Wert |
|---|---|
| App-Name / VM-Name | `ace-step` |
| Zweck | Open-Source Music Generation – Text2Music, Cover, Repaint, Vocal2BGM, Gradio WebUI |
| Tech-Stack | Python 3.12 + `uv sync` + PyTorch + Gradio `:7860`, venv `/opt/ace-step/.venv` (`acestep` CLI) |
| GitHub-Repo (Upstream) | `https://github.com/ace-step/ACE-Step-1.5` |
| Web UI | `http://<VM-IP>:7860` (Gradio, `GRADIO_SERVER_NAME=0.0.0.0`) |
| Standard-Ressourcen | 4 vCPU / 16384 MB RAM / 60 GB Disk (Minimum 4 / 8192 / 40; GPU-Empfehlung 24 GB VRAM) |
| VM-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--vmid` gesetzt (Kollision → ausweichen) |
| Template | Debian-12 Cloud-Image (`cloud.debian.org`, `generic-amd64.qcow2` nach `/var/lib/vz/template/qcow`) |
| VM-Features | QEMU-Guest-Agent, `onboot: 1`, `--hostpci0 …,pcie=1` nur bei `--gpu` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie VM-ID, erkennt Disk-Storage
   (bevorzugt `local-lvm`), lädt das Debian-12-Cloud-Image falls nötig,
2. erstellt die VM `ace-step` (`onboot: 1`, Cloud-Init-User `ace`, SSH-Key optional),
   optional GPU-Passthrough, `qm importdisk + resize + start`,
3. wartet auf Guest-Agent-IP + SSH, installiert im Gast Systemdeps
   (`ffmpeg git curl python3-dev build-essential`), `uv`, klont/pullt `ace-step/ACE-Step-1.5`
   nach `/opt/ace-step`, `uv sync --python 3.12`, legt `.env` an, schreibt `ace-step.service`,
   `systemctl enable --now ace-step` (Modelle laden beim Erststart automatisch nach),
4. verifiziert `systemctl is-active ace-step` + HTTP auf `localhost:7860/`
   (Poll bis 10 Min – erster Start lädt DiT/LM-Modelle) und gibt die finale URL + VM-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active ace-step = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:7860/).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : ACE-Step 1.5 – Open-Source Music Generation
  VM           : 100 (Name: ace-step, onboot=1, Modus: cpu)
  Ressourcen   : 4 vCPU / 16384 MB RAM / 60 GB Disk
  Web UI       : http://192.168.1.100:7860
  ...
  Log          : /tmp/ace-step-install-2026-....log
══════════════════════════════════════════════════════════
```

## Reboot-Test (Reboot-sicher belegen)

```bash
VM=100
qm reboot $VM
sleep 120
qm guest exec $VM -- systemctl is-active ace-step
curl -fs http://<VM-IP>:7860/ >/dev/null && echo WEB_UI_OK
```

## Update / Deinstall

```bash
bash ace-step.sh --vmid 100            # Update: idempotent (git pull + uv sync + restart)
qm stop 100 && qm destroy 100             # Deinstall
```

GPU nachträglich: `bash ace-step.sh --vmid 100 --gpu 0000:01:00` (stellt auf Passthrough um, danach Reboot).

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code + Aufrufstapel aus, Voll-Log unter `/tmp/ace-step-install-*.log`.
- `bash ace-step.sh --debug` für `bash -x`-Trace.
- Im Gast: `systemctl status ace-step --no-pager`, `journalctl -u ace-step -n 100`.

## Troubleshooting: Keine Gast-IP (Guest-Agent)

Symptom: `Keine Gast-IP (Guest-Agent)` nach 10 Min, `qm config` zeigt `agent: enabled=1`.

1. Agent-Status prüfen:
```bash
qm agent 100 ping
qm guest cmd 100 network-get-interfaces
qm status 100
```
2. Häufigste Ursachen: Cloud-Init Erstboot dauert, DHCP auf `vmbr0` antwortet nicht,
   oder `qemu-guest-agent` im Gast läuft noch nicht.
3. Konsole öffnen und im Gast prüfen:
```bash
qm terminal 100
# im Gast:
systemctl status qemu-guest-agent --no-pager
ip -4 addr show
```
4. Schnellweg ohne Warten: bekannte/statische IP direkt übergeben –
   überspringt den Agent-Wait komplett:
```bash
bash ace-step.sh --vmid 100 --ip 192.168.1.50
```
5. Danach Update-Modus erneut laufen lassen (idempotent, VM bleibt bestehen):
```bash
bash ace-step.sh --vmid 100
```

## Dateien

- `install/ace-step.sh` – Proxmox-Einzeiler (Host, root, `qm` + SSH-Provision).
- `systemd/ace-step.service` – Gradio-Unit (`:7860`, `After=network-online.target`, `Restart=always`).
