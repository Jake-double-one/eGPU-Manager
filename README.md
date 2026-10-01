# eGPU-Manager (GPU-Verwaltung)

Hält eine **interne NVIDIA-GPU** und eine **NVIDIA-eGPU** auf derselben Treiberversion, damit beide gleichzeitig laufen.

Eingerichtet für einen Dell Precision 5570 mit **RTX A2000 8GB Laptop GPU** (intern) und einer **GeForce RTX 4070** im Razer Core X Chroma (Thunderbolt).

## Das Problem

Beide Karten nutzen denselben Kerneltreiber `nvlddmkm.sys`. Windows lädt davon nur **eine** Version. Bekommen die Karten unterschiedliche Treiber – z. B. die A2000 einen Dell-/RTX-Treiber über Dell Command Update oder Windows Update, die 4070 einen GeForce-Treiber – startet eine von beiden nicht:

```
NVIDIA RTX A2000 8GB Laptop GPU   Code 31 (CM_PROB_FAILED_ADD), Status 0xC0000182
```

Mit **derselben Version für beide Karten** laufen A2000 und 4070 gleichzeitig. Das GeForce-Paket enthält beide Karten (`nvdmi.inf` für die A2000, `nvmdi.inf` für die 4070).

## Funktionen

- **Status** beider Karten (Treiberversion, Gerätezustand) und der NVIDIA-Pakete im Windows-Treiberspeicher
- **Versionsliste** direkt von der NVIDIA-Treibersuche für beide Karten – zeigt, welche Versionen NVIDIA für **beide** veröffentlicht hat
- **Laden und prüfen**: Download, Authenticode-Signatur (NVIDIA Corporation), Archivtest, beide Hardware-IDs mit gleicher Treiberversion im Paket, signierter Treiberkatalog
- **Wechseln** jetzt, beim nächsten Neustart oder zu einer Uhrzeit (einmalige SYSTEM-Aufgabe, löscht sich danach selbst)
- **Abweichung reparieren**, wenn Dell Command Update oder Windows Update dazwischengefunkt haben
- Aufbewahrung von höchstens zwei Versionen (aktuelle + Rückfall) als Original-Installer; vor jeder Nutzung wird Prüfsumme und Signatur erneut kontrolliert
- Dunkelmodus (Automatisch / Hell / Dunkel)
- **Tool installieren**: kopiert sich nach `C:\Scripts\GpuTool`, sichert den Ordner ab, legt eine Desktop-Verknüpfung an und startet von dort neu

## Voraussetzungen

- Windows 10/11, Windows PowerShell 5.1
- [7-Zip](https://www.7-zip.org/) unter `C:\Program Files\7-Zip\7z.exe` (zum Prüfen und Entpacken der NVIDIA-Pakete)
- Adminrechte (das Werkzeug fordert sie beim Start selbst an)

## Start

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\GpuTool.ps1
```

Im Fenster unten **„Tool installieren“** klicken – danach startet man es über die Desktop-Verknüpfung „GPU-Verwaltung“.

Konsole:

```powershell
.\GpuTool.ps1 -Status            # Zustand anzeigen
.\GpuTool.ps1 -Apply 596.36      # abgelegte Version sofort installieren (Adminrechte)
```

## Andere Karten

Beim ersten Start wird `config.json` angelegt (Vorlage: [`config.example.json`](config.example.json)). Für andere GPUs unter `Devices` anpassen:

| Feld | Bedeutung |
|---|---|
| `HardwareId` | `PCI\VEN_10DE&DEV_xxxx&SUBSYS_xxxxxxxx` aus dem Geräte-Manager (Details → Hardware-IDs) |
| `Psid` / `Pfid` | Produktserie/-ID der NVIDIA-Treibersuche (`https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3`) |
| `DownloadFrom` | `Short` der Karte, deren Paket geladen wird (das GeForce-Paket enthielt bei 596.36 beide Karten) |

## Dateien

```
GpuTool.ps1            Werkzeug (Oberfläche + Konsole)
config.json            persönliche Konfiguration (nicht im Repository)
Pakete\<Version>\      geprüfte NVIDIA-Installer (nicht im Repository)
C:\ProgramData\GpuTool\gpu-tool.log
```

## Tipps

- Dell Command Update: unter *Einstellungen → Update-Filter* die Kategorie **Video** abwählen.
- Windows Update ohne Treiber (Admin-PowerShell):
  ```
  reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f
  ```
