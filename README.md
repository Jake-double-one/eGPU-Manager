# eGPU Manager

Keeps an **internal NVIDIA GPU** and an **NVIDIA eGPU** on the same driver version, so both run side by side.

Built for a Dell Precision 5570 with an **RTX A2000 8GB Laptop GPU** (internal) and a **GeForce RTX 4070** in a Razer Core X Chroma (Thunderbolt).

*Deutsche Kurzfassung: [siehe unten](#deutsch).*

## Screenshot
<img width="1127" height="989" alt="image" src="https://github.com/user-attachments/assets/d2bb114b-5484-4f23-b456-b800ce2d2508" />

## The problem

Both cards use the same kernel driver, `nvlddmkm.sys`, and Windows loads only **one** version of it. If the cards get different drivers – for example the A2000 a Dell/RTX driver through Dell Command Update or Windows Update, and the 4070 a GeForce driver – one of them fails to start:

```
NVIDIA RTX A2000 8GB Laptop GPU   Code 31 (CM_PROB_FAILED_ADD), status 0xC0000182
```

With **the same version for both cards**, the A2000 and the 4070 run at the same time. The GeForce package contains both cards (`nvdmi.inf` for the A2000, `nvmdi.inf` for the 4070).

## Features

- **Status** of both cards (driver version, device state) and of the NVIDIA packages in the Windows driver store
- **Version list** straight from NVIDIA's driver search for both cards – shows which versions NVIDIA released for **both**
- **Download and verify**: download, Authenticode signature (NVIDIA Corporation), archive test, both hardware IDs with the same driver version in the package, signed driver catalog
- **Switch** now, at the next restart, or at a set time (one-time SYSTEM task that deletes itself afterwards)
- **Repair mismatch** when Dell Command Update or Windows Update replaced a driver
- Keeps at most two versions (current + fallback) as the original installer; checksum and signature are verified again before every use
- **Install tool**: copies itself to `C:\Scripts\GpuTool`, secures the folder, creates a desktop shortcut and restarts from there
- **Updater**: checks this repository for a newer version tag and updates itself
- English and German (automatic from the Windows display language), light and dark theme (automatic from Windows)

## Requirements

- Windows 10/11, Windows PowerShell 5.1
- [7-Zip](https://www.7-zip.org/) at `C:\Program Files\7-Zip\7z.exe` (to verify and extract the NVIDIA packages)
- Administrator rights (the tool requests them on start)

## Getting started

1. Download [`GpuTool.ps1`](GpuTool.ps1) (or clone the repository).
2. Run it:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\GpuTool.ps1
   ```
3. Click **Install tool** at the bottom. From then on, start it with the **eGPU Manager** desktop shortcut.

Console:

```powershell
.\GpuTool.ps1 -Status            # show status
.\GpuTool.ps1 -Apply 596.36      # install a stored version now (administrator rights)
```

## Updates

The tool compares its version with the newest version tag (`vX.Y.Z`) in this repository. If a newer one exists, an **Update to X.Y.Z** button appears at the bottom. The new script is downloaded from that tag, syntax-checked and must carry the expected version number; the previous script is kept as `GpuTool.ps1.bak`. Settings and driver packages are kept.

A git checkout (development copy) is not updated by the tool – use `git pull` there.

### Releasing a new version

1. Raise `Version` at the top of `GpuTool.ps1`.
2. Commit, then tag and push:
   ```bash
   git tag v1.2.0
   git push origin main --tags
   ```

## Other cards

On first start, `config.json` is created (template: [`config.example.json`](config.example.json)). Adjust `Devices` for other GPUs:

| Field | Meaning |
|---|---|
| `Name` | Display name in the tool |
| `HardwareId` | `PCI\VEN_10DE&DEV_xxxx&SUBSYS_xxxxxxxx` from Device Manager (Details → Hardware Ids) |
| `Psid` / `Pfid` | Product series / ID in NVIDIA's driver search (`https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3`) |
| `DownloadFrom` | `Short` of the card whose package is downloaded (the GeForce package 596.36 contained both cards) |

## Files

```
GpuTool.ps1            the tool (GUI + console)
config.json            personal configuration (not in the repository)
Packages\<version>\    verified NVIDIA installers (not in the repository)
C:\ProgramData\GpuTool\gpu-tool.log
```

## Tips

- Dell Command Update: under *Settings → Update Filter*, deselect the **Video** category.
- Windows Update without drivers (administrator PowerShell):
  ```
  reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f
  ```

## License

[MIT](LICENSE)

---

## Deutsch

**eGPU Manager** hält eine interne NVIDIA-GPU und eine NVIDIA-eGPU auf derselben Treiberversion. Beide Karten nutzen denselben Kerneltreiber `nvlddmkm.sys`. Bekommen sie unterschiedliche Versionen (z. B. durch Dell Command Update oder Windows Update), startet eine Karte nicht (Code 31). Mit derselben Version laufen beide gleichzeitig.

Das Werkzeug zeigt den Zustand beider Karten, listet die bei NVIDIA für **beide** Karten veröffentlichten Versionen, lädt und prüft Pakete (Signatur, Archiv, Hardware-IDs, Treiberversion), wechselt sofort, beim nächsten Neustart oder zu einer Uhrzeit, repariert Abweichungen und aktualisiert sich selbst über die Versions-Tags dieses Repositorys.

**Start:** `GpuTool.ps1` ausführen und unten **„Tool installieren“** klicken – danach über die Desktop-Verknüpfung **eGPU Manager** starten. Voraussetzungen: Windows PowerShell 5.1, 7-Zip, Adminrechte.

Die Sprache richtet sich nach der Windows-Anzeigesprache (Deutsch oder Englisch) und lässt sich unten im Fenster umstellen.
