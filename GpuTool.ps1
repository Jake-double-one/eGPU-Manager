<#
  GpuTool.ps1  -  GPU-Verwaltung
  Gemeinsame NVIDIA-Treiberversion für RTX A2000 (intern) und RTX 4070 (eGPU im Razer Core X)

  Hintergrund:
    Beide Karten nutzen denselben Kerneltreiber nvlddmkm.sys. Mit unterschiedlichen Treiberversionen
    startet eine der Karten nicht (Code 31/43). Mit derselben Version laufen beide gleichzeitig.

  Start:    Desktop-Verknüpfung "GPU-Verwaltung" (fordert Adminrechte an)
  Konsole:  GpuTool.ps1 -Status            Zustand anzeigen
            GpuTool.ps1 -Apply 596.36      abgelegte Version sofort installieren (Adminrechte)
  Intern:   -Apply <Version> -FromTask     einmaliger geplanter Wechsel, die Aufgabe löscht sich danach selbst
            -LoadCore                      nur Funktionen laden (für Hintergrundarbeiten der Oberfläche)

  Dateien:  config.json, Pakete\<Version>\*.exe (Original-Installer von NVIDIA, wird vor jeder Nutzung geprüft)
  Log:      C:\ProgramData\GpuTool\gpu-tool.log
#>
param(
    [string]$Apply,
    [switch]$FromTask,
    [switch]$Status,
    [switch]$LoadCore,
    [switch]$NoElevate,
    [string]$Snapshot,
    [ValidateSet('', 'Light', 'Dark')][string]$Theme = ''   # leer = Windows-Einstellung folgen
)

$Global:GT = @{
    Self       = $PSCommandPath
    Root       = $PSScriptRoot
    ConfigFile = Join-Path $PSScriptRoot 'config.json'
    PkgDir     = Join-Path $PSScriptRoot 'Pakete'
    DataDir    = Join-Path $env:ProgramData 'GpuTool'
    TaskName   = 'GpuTool-Treiberwechsel'
    InstallDir = 'C:\Scripts\GpuTool'
    SevenZip   = 'C:\Program Files\7-Zip\7z.exe'
    Api        = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php'
}
$GT.LogFile    = Join-Path $GT.DataDir 'gpu-tool.log'
$GT.WorkDir    = Join-Path $GT.DataDir 'work'
$GT.ResultFile = Join-Path $GT.DataDir 'letzter-wechsel.json'
New-Item -ItemType Directory -Force -Path $GT.DataDir | Out-Null

# =============================================================================================
#  Grundfunktionen
# =============================================================================================

function Write-Log([string]$Msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    try { Add-Content -Path $GT.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    if ($Global:GtSync) { $Global:GtSync.Log.Enqueue($line) } else { Write-Host $line }
}

function Set-Progress([int]$Percent, [string]$Text) {
    if ($Global:GtSync) { $Global:GtSync.Progress = $Percent; $Global:GtSync.ProgressText = $Text }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Config {
    if (-not (Test-Path $GT.ConfigFile)) { Save-Config (New-DefaultConfig) }
    Get-Content $GT.ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

# Grundkonfiguration, falls nur GpuTool.ps1 ohne config.json kopiert wurde
function New-DefaultConfig {
    [pscustomobject]@{
        Current      = ''
        KeepVersions = 2
        DownloadFrom = '4070'
        Settings     = [pscustomobject]@{ Theme = 'Auto' }
        Devices      = @(
            [pscustomobject]@{ Short = 'A2000'; Name = 'RTX A2000 (intern)'; HardwareId = 'PCI\VEN_10DE&DEV_25BA&SUBSYS_0B1A1028'; Psid = 124; Pfid = 989 },
            [pscustomobject]@{ Short = '4070';  Name = 'RTX 4070 (eGPU)';    HardwareId = 'PCI\VEN_10DE&DEV_2786&SUBSYS_51371462'; Psid = 127; Pfid = 1015 }
        )
        Packages     = @()
    }
}

function Get-Setting([string]$Name, $Default) {
    $cfg = Get-Config
    if ($cfg.PSObject.Properties['Settings'] -and $cfg.Settings.PSObject.Properties[$Name]) { $cfg.Settings.$Name } else { $Default }
}

function Set-Setting([string]$Name, $Value) {
    $cfg = Get-Config
    if (-not $cfg.PSObject.Properties['Settings']) { $cfg | Add-Member -NotePropertyName Settings -NotePropertyValue ([pscustomobject]@{}) }
    if ($cfg.Settings.PSObject.Properties[$Name]) { $cfg.Settings.$Name = $Value }
    else { $cfg.Settings | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    Save-Config $cfg
}

function Save-Config($Config) {
    $Config | ConvertTo-Json -Depth 6 | Set-Content -Path $GT.ConfigFile -Encoding UTF8
}

# 32.0.15.9636 -> 596.36 (NVIDIA-Schema: letzte Ziffer des 3. Felds + 4. Feld)
function ConvertTo-NvVersion([string]$DriverVersion) {
    $p = "$DriverVersion".Split('.')
    if ($p.Count -ne 4) { return $null }
    $d = $p[2].Substring($p[2].Length - 1) + $p[3].PadLeft(4, '0')
    '{0}.{1}' -f $d.Substring(0, 3), $d.Substring(3)
}

# =============================================================================================
#  Zustand
# =============================================================================================

function Get-GpuState {
    $cfg  = Get-Config
    $devs = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue)
    foreach ($d in $cfg.Devices) {
        $dev = $devs | Where-Object { $_.InstanceId -like "$($d.HardwareId)*" } | Select-Object -First 1
        $o = [pscustomobject]@{ Short = $d.Short; Name = $d.Name; Present = $false; DriverVersion = $null; NvVersion = $null; Problem = $null }
        if ($dev) {
            $p = Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName DEVPKEY_Device_DriverVersion, DEVPKEY_Device_ProblemCode
            $o.Present       = $true
            $o.DriverVersion = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_DriverVersion').Data
            $o.NvVersion     = ConvertTo-NvVersion $o.DriverVersion
            $o.Problem       = [int](($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data)
        }
        $o
    }
}

# NVIDIA-Anzeigetreiber im Windows-Treiberspeicher (pnputil XML: schnell, sprachunabhängig, ohne Adminrechte)
function Get-StorePackages {
    [xml]$x = (& pnputil.exe /enum-drivers /class Display /format xml) -join "`n"
    foreach ($d in $x.PnpUtil.Driver) {
        if ($d.ProviderName -ne 'NVIDIA') { continue }
        $v = ("$($d.DriverVersion)" -split ' ')[-1]
        [pscustomobject]@{ Driver = $d.DriverName; Original = $d.OriginalName; DriverVersion = $v; NvVersion = (ConvertTo-NvVersion $v) }
    }
}

function Get-Summary {
    $gpus     = @(Get-GpuState)
    $store    = @(Get-StorePackages)
    $present  = @($gpus | Where-Object Present)
    $versions = @(@($present | ForEach-Object DriverVersion) + @($store | ForEach-Object DriverVersion) | Where-Object { $_ } | Select-Object -Unique)
    $problems = @($present | Where-Object { $_.Problem -notin 0, 22 })
    $common   = $null
    if ($versions.Count -eq 1) { $common = ConvertTo-NvVersion $versions[0] }
    [pscustomobject]@{
        Gpus     = $gpus
        Store    = $store
        Versions = @($versions | ForEach-Object { ConvertTo-NvVersion $_ })
        Common   = $common
        Ok       = ($versions.Count -le 1 -and $problems.Count -eq 0)
    }
}

# =============================================================================================
#  Versionen bei NVIDIA
# =============================================================================================

function Get-OnlineList([int]$Psid, [int]$Pfid) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $u = "$($GT.Api)?func=DriverManualLookup&psid=$Psid&pfid=$Pfid&osID=57&languageCode=1033&beta=0&isWHQL=1" +
         '&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=100'
    foreach ($e in (Invoke-RestMethod -UseBasicParsing -Uri $u -TimeoutSec 30).IDS) {
        $i = $e.downloadInfo
        $date = $null
        try { $date = [datetime]::ParseExact($i.ReleaseDateTime, 'ddd MMM dd, yyyy', [Globalization.CultureInfo]::InvariantCulture) } catch { }
        [pscustomobject]@{ Version = $i.Version; Date = $date; Url = $i.DownloadURL; Name = [uri]::UnescapeDataString($i.Name) }
    }
}

# Eine Zeile pro Version: für welche Karte gelistet, gemeinsam, lokal abgelegt
function Get-VersionTable {
    $cfg  = Get-Config
    $rows = @{}
    $err  = $null
    foreach ($d in $cfg.Devices) {
        $list = @()
        try { $list = @(Get-OnlineList $d.Psid $d.Pfid) } catch { $err = $_.Exception.Message }
        foreach ($e in $list) {
            if (-not $rows.ContainsKey($e.Version)) {
                $rows[$e.Version] = [pscustomobject]@{ Version = $e.Version; Dates = @{}; Urls = @{}; Common = $false; Local = $false; Url = $null }
            }
            $rows[$e.Version].Dates[$d.Short] = $e.Date
            $rows[$e.Version].Urls[$d.Short]  = $e.Url
        }
    }
    foreach ($p in @($cfg.Packages)) {
        if (-not $rows.ContainsKey($p.Version)) {
            $rows[$p.Version] = [pscustomobject]@{ Version = $p.Version; Dates = @{}; Urls = @{}; Common = $false; Local = $false; Url = $p.Url }
        }
        $rows[$p.Version].Local = $true
    }
    $shorts = @($cfg.Devices | ForEach-Object Short)
    foreach ($r in $rows.Values) {
        $r.Common = (@($shorts | Where-Object { $r.Dates.ContainsKey($_) }).Count -eq $shorts.Count)
        if ($r.Urls.ContainsKey($cfg.DownloadFrom)) { $r.Url = $r.Urls[$cfg.DownloadFrom] }
        elseif (-not $r.Url -and $r.Urls.Count) { $r.Url = @($r.Urls.Values)[0] }
    }
    [pscustomobject]@{ Rows = @($rows.Values | Sort-Object { [version]$_.Version } -Descending); Error = $err }
}

# =============================================================================================
#  Pakete laden, prüfen, ablegen
# =============================================================================================

function Save-Download([string]$Url, [string]$Path) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $resp  = ([Net.HttpWebRequest]::Create($Url)).GetResponse()
    $total = $resp.ContentLength
    $in    = $resp.GetResponseStream()
    $out   = [IO.File]::Create($Path)
    $buf   = New-Object byte[] (4MB)
    $done  = [int64]0; $last = -1
    try {
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n); $done += $n
            $pct = [int](100 * $done / [Math]::Max(1, $total))
            if ($pct -ne $last) { Set-Progress $pct ('Download {0:N0} von {1:N0} MB' -f ($done / 1MB), ($total / 1MB)); $last = $pct }
        }
    } finally { $out.Close(); $in.Close(); $resp.Close() }
    if ($done -ne $total) { throw "Download unvollständig ($done von $total Bytes)" }
    Write-Log ('  Download vollständig ({0:N0} Bytes)' -f $done)
}

# Prüft ein NVIDIA-Paket: Signatur, Archiv, beide Karten enthalten, gleiche Treiberversion, Katalog signiert
function Test-Package([string]$Exe) {
    $cfg = Get-Config
    if (-not (Test-Path $GT.SevenZip)) { throw "7-Zip nicht gefunden ($($GT.SevenZip))" }

    Set-Progress -1 'Prüfe Signatur ...'
    $sig = Get-AuthenticodeSignature $Exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'CN=NVIDIA Corporation') {
        throw "Signatur ungültig ($($sig.Status), $($sig.SignerCertificate.Subject))"
    }
    Write-Log '  Signatur gültig (NVIDIA Corporation)'

    Set-Progress -1 'Teste Archiv ...'
    & $GT.SevenZip t $Exe | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Archivtest fehlgeschlagen' }
    Write-Log '  Archivtest fehlerfrei'

    Set-Progress -1 'Prüfe Treiberdateien ...'
    $tmp = Join-Path $GT.WorkDir ('check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    & $GT.SevenZip e $Exe "-o$tmp" 'Display.Driver\*.inf' 'Display.Driver\NV_DISP.CAT' -y | Out-Null
    try {
        $infs = @(); $vers = @()
        foreach ($d in $cfg.Devices) {
            $pattern = [regex]::Escape($d.HardwareId) + '\s*$'
            $hit = Get-ChildItem $tmp -Filter '*.inf' | Where-Object { (Get-Content $_.FullName) -match $pattern } | Select-Object -First 1
            if (-not $hit) { throw "$($d.Name) ist in diesem Paket nicht enthalten" }
            $dv = ((@((Get-Content $hit.FullName) -match '^\s*DriverVer'))[0] -replace '.*,\s*', '').Trim()
            Write-Log "  $($d.Name): $($hit.Name), Treiberversion $dv"
            $infs += $hit.Name; $vers += $dv
        }
        if (@($vers | Select-Object -Unique).Count -ne 1) { throw "Unterschiedliche Treiberversionen im Paket: $($vers -join ', ')" }
        $cat = Get-AuthenticodeSignature (Join-Path $tmp 'NV_DISP.CAT')
        if ($cat.Status -ne 'Valid') { throw "Treiberkatalog nicht gültig signiert ($($cat.Status))" }
        Write-Log '  Treiberkatalog gültig signiert'
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    [pscustomobject]@{ DriverVersion = $vers[0]; Infs = @($infs | Select-Object -Unique) }
}

function Import-Version([string]$Version, [string]$Url) {
    if (-not $Url) { throw "Keine Download-Adresse für $Version" }
    Write-Log "Lade und prüfe $Version"
    $name = [IO.Path]::GetFileName(([uri]$Url).AbsolutePath)
    $tmp  = Join-Path $GT.WorkDir "download-$Version"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $file = Join-Path $tmp $name
        Save-Download $Url $file
        $info = Test-Package $file

        $dir = Join-Path $GT.PkgDir $Version
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Move-Item $file (Join-Path $dir $name) -Force

        $cfg = Get-Config
        $pkg = [pscustomobject]@{
            Version       = $Version
            File          = "Pakete\$Version\$name"
            Sha256        = (Get-FileHash (Join-Path $dir $name)).Hash
            DriverVersion = $info.DriverVersion
            Infs          = $info.Infs
            Url           = $Url
            Added         = (Get-Date -Format 's')
        }
        $cfg.Packages = @(@($cfg.Packages | Where-Object { $_.Version -ne $Version }) + $pkg)
        Save-Config $cfg
        Write-Log "Geprüft und abgelegt: $Version ($($info.DriverVersion)) - beide Karten enthalten"
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-OldPackages -Keep $Version
    $true
}

# Behält die installierte Version und insgesamt höchstens KeepVersions Pakete
function Remove-OldPackages([string]$Keep) {
    $cfg     = Get-Config
    $keepSet = @(@($cfg.Current, $Keep) | Where-Object { $_ } | Select-Object -Unique)
    $others  = @(@($cfg.Packages) | Where-Object { $_.Version -notin $keepSet } | Sort-Object { [datetime]$_.Added } -Descending)
    $slots   = [Math]::Max(0, [int]$cfg.KeepVersions - $keepSet.Count)
    $remove  = @($others | Select-Object -Skip $slots)
    if (-not $remove) { return }
    foreach ($p in $remove) {
        Remove-Item (Join-Path $GT.PkgDir $p.Version) -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Altes Paket entfernt: $($p.Version)"
    }
    $cfg.Packages = @(@($cfg.Packages) | Where-Object { $_.Version -notin @($remove | ForEach-Object Version) })
    Save-Config $cfg
}

# =============================================================================================
#  Wechseln
# =============================================================================================

function Install-Version([string]$Version) {
    if (-not (Test-Admin)) { throw 'Für den Treiberwechsel sind Adminrechte nötig' }
    $cfg = Get-Config
    $pkg = @($cfg.Packages) | Where-Object Version -eq $Version | Select-Object -First 1
    if (-not $pkg) { throw "Version $Version ist nicht lokal abgelegt - zuerst laden und prüfen" }
    $exe = Join-Path $GT.Root $pkg.File
    Write-Log "Wechsel auf $Version ($($pkg.DriverVersion))"

    # Paket unverändert und echt?
    Set-Progress -1 'Prüfe Paket ...'
    if (-not (Test-Path $exe)) { throw "Paketdatei fehlt: $exe" }
    if ((Get-FileHash $exe).Hash -ne $pkg.Sha256) { throw 'Prüfsumme stimmt nicht - Paket wurde verändert' }
    $sig = Get-AuthenticodeSignature $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'CN=NVIDIA Corporation') { throw 'Signatur ungültig' }
    Write-Log '  Paket unverändert, Signatur gültig'

    # Treiberteil entpacken
    Set-Progress -1 'Entpacke Treiber ...'
    $x = Join-Path $GT.WorkDir "install-$Version"
    Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
    & $GT.SevenZip x $exe "-o$x" 'Display.Driver\*' -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Entpacken fehlgeschlagen' }
    $dd = Join-Path $x 'Display.Driver'

    $reboot = $false
    try {
        foreach ($inf in @($pkg.Infs)) { if (-not (Test-Path (Join-Path $dd $inf))) { throw "$inf fehlt im Paket" } }

        # 1. alle anderen NVIDIA-Anzeigetreiber entfernen
        foreach ($s in @(Get-StorePackages | Where-Object { $_.DriverVersion -ne $pkg.DriverVersion })) {
            Set-Progress -1 "Entferne $($s.NvVersion) ..."
            $out = & pnputil.exe /delete-driver $s.Driver /uninstall /force 2>&1
            Write-Log ('  entfernt {0} ({1}, {2}) -> Exit {3}' -f $s.Driver, $s.Original, $s.NvVersion, $LASTEXITCODE)
            if ($LASTEXITCODE -eq 3010) { $reboot = $true } elseif ($LASTEXITCODE -ne 0) { Write-Log "    $($out -join ' ')" }
        }
        # 2. gemeinsame Version installieren
        foreach ($inf in @($pkg.Infs)) {
            Set-Progress -1 "Installiere $inf ..."
            $out = & pnputil.exe /add-driver (Join-Path $dd $inf) /install 2>&1
            Write-Log ('  installiert {0} -> Exit {1}' -f $inf, $LASTEXITCODE)
            if ($LASTEXITCODE -eq 3010) { $reboot = $true }
            elseif ($LASTEXITCODE -notin 0, 259) { Write-Log "    $($out -join ' ')" }   # 259 = kein Gerät aktualisiert
        }
    } finally { Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue }

    $cfg = Get-Config
    $cfg.Current = $Version
    Save-Config $cfg
    Remove-OldPackages

    Start-Sleep -Seconds 5
    $s = Get-Summary
    foreach ($g in $s.Gpus) {
        Write-Log ('  {0}: {1}' -f $g.Name, $(if ($g.Present) { "$($g.NvVersion), Code $($g.Problem)" } else { 'nicht angeschlossen' }))
    }
    $ok = $s.Ok -and -not $reboot
    $msg = if ($ok) { "Beide Karten nutzen jetzt die gemeinsame Version $Version." }
           else { "Treiber $Version ist installiert. Bitte den Laptop neu starten, um den Wechsel abzuschließen." }
    Write-Log $msg
    [pscustomobject]@{ Ok = $ok; RebootRequired = (-not $ok); Message = $msg }
}

# =============================================================================================
#  Geplanter Wechsel (einmalige Aufgabe, löscht sich nach dem Lauf selbst)
# =============================================================================================

# Darf außer Administratoren und SYSTEM niemand in den Ordner schreiben? (Die Aufgabe läuft als SYSTEM.)
function Test-FolderSecure {
    $risky = 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4'   # Jeder, Authentifizierte Benutzer, Benutzer, Interaktiv
    $write = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    foreach ($a in (Get-Acl $GT.Root).Access) {
        if ($a.AccessControlType -ne 'Allow') { continue }
        try { $sid = $a.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
        $rights = [int64]$a.FileSystemRights
        $generic = $rights -band 0x50000000   # GENERIC_WRITE / GENERIC_ALL
        if ($sid -in $risky -and (($rights -band [int64]$write) -or $generic)) { return $false }
    }
    $true
}

function Protect-Folder([string]$Path = $GT.Root) {
    $out = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
    Write-Log "Ordnerrechte abgesichert ($Path) -> Exit $LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) { throw ($out -join ' ') }
}

# =============================================================================================
#  Installation
# =============================================================================================

function Test-Installed {
    $a = [IO.Path]::GetFullPath($GT.Root).TrimEnd('\')
    $b = [IO.Path]::GetFullPath($GT.InstallDir).TrimEnd('\')
    $a -eq $b
}

function New-DesktopShortcut([string]$Script) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'GPU-Verwaltung.lnk'
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""
    $s.WorkingDirectory = Split-Path $Script
    $s.IconLocation     = "$env:SystemRoot\System32\dxdiag.exe,0"
    $s.WindowStyle      = 7
    $s.Description      = 'Gemeinsame NVIDIA-Treiberversion für RTX A2000 und RTX 4070 verwalten'
    $s.Save()
    Write-Log "Desktop-Verknüpfung angelegt: $lnk"
}

# Kopiert das Werkzeug nach C:\Scripts\GpuTool, sichert den Ordner ab und legt die Verknüpfung an.
# Eine vorhandene Installation behält ihre Einstellungen und Pakete, nur das Script wird ersetzt.
# Gibt den Pfad des installierten Scripts zurück.
function Install-Tool {
    $dst    = $GT.InstallDir
    $target = Join-Path $dst 'GpuTool.ps1'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    if (-not (Test-Installed)) {
        Write-Log "Installiere nach $dst"
        Copy-Item $GT.Self $target -Force
        if (Test-Path (Join-Path $dst 'config.json')) {
            Write-Log '  vorhandene Installation gefunden - Einstellungen und Pakete bleiben erhalten'
        } else {
            if (Test-Path $GT.ConfigFile) { Copy-Item $GT.ConfigFile $dst -Force }
            if (Test-Path $GT.PkgDir) {
                Set-Progress -1 'Kopiere Treiberpakete ...'
                Copy-Item $GT.PkgDir $dst -Recurse -Force
                Write-Log '  Treiberpakete übernommen'
            }
        }
    }
    Protect-Folder $dst
    New-DesktopShortcut $target
    $target
}

function Register-Switch([string]$Version, $At) {
    if (-not (Test-FolderSecure)) { throw "Ordner $($GT.Root) ist nicht abgesichert - zuerst 'Rechte absichern'" }
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($GT.Self)`" -Apply $Version -FromTask"
    $act = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arg
    if ($At) { $trg = New-ScheduledTaskTrigger -Once -At $At }
    else     { $trg = New-ScheduledTaskTrigger -AtStartup; $trg.Delay = 'PT1M' }
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $when = if ($At) { ([datetime]$At).ToString('dd.MM.yyyy HH:mm') } else { 'beim nächsten Neustart' }
    Register-ScheduledTask -TaskName $GT.TaskName -Action $act -Trigger $trg -Settings $set -Principal $prn -Force `
        -Description "GPU-Verwaltung: einmaliger Wechsel auf NVIDIA $Version ($when). Löscht sich nach dem Lauf selbst." | Out-Null
    Write-Log "Wechsel auf $Version geplant: $when"
}

function Get-PendingSwitch {
    $t = Get-ScheduledTask -TaskName $GT.TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $ver  = if ($t.Actions[0].Arguments -match '-Apply\s+(\S+)') { $Matches[1] } else { '?' }
    $trg  = $t.Triggers[0]
    $when = if ($trg.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger') { 'beim nächsten Neustart' }
            else { ([datetime]$trg.StartBoundary).ToString('dd.MM.yyyy HH:mm') }
    [pscustomobject]@{ Version = $ver; When = $when }
}

function Unregister-Switch {
    Unregister-ScheduledTask -TaskName $GT.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log 'Geplanter Wechsel abgebrochen'
}

function Get-LastResult {
    if (Test-Path $GT.ResultFile) { Get-Content $GT.ResultFile -Raw -Encoding UTF8 | ConvertFrom-Json }
}

function Set-LastResultShown {
    $r = Get-LastResult
    if ($r) { $r.Shown = $true; $r | ConvertTo-Json | Set-Content $GT.ResultFile -Encoding UTF8 }
}

# Wartet (als SYSTEM) bis jemand angemeldet ist und zeigt dann eine Meldung
function Send-UserMessage([string]$Text, [int]$WaitMinutes) {
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    while (-not (Get-Process explorer -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 15 }
    if (Get-Process explorer -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 20
        & msg.exe * /TIME:0 "GPU-Verwaltung`n`n$Text" 2>$null
    }
}

# =============================================================================================
#  Konsole
# =============================================================================================

function Show-Status {
    $s = Get-Summary
    foreach ($g in $s.Gpus) {
        Write-Host ('{0,-22} {1}' -f $g.Name, $(if ($g.Present) { "$($g.NvVersion) ($($g.DriverVersion)), Code $($g.Problem)" } else { 'nicht angeschlossen' }))
    }
    foreach ($p in $s.Store) { Write-Host ('Treiberspeicher        {0} {1} {2}' -f $p.Driver, $p.Original, $p.NvVersion) }
    if ($s.Ok) { Write-Host "OK: gemeinsame Version $($s.Common)" -ForegroundColor Green }
    else       { Write-Host "ABWEICHUNG: $($s.Versions -join ', ')" -ForegroundColor Yellow }
    $p = Get-PendingSwitch
    if ($p) { Write-Host "Geplant: Wechsel auf $($p.Version) $($p.When)" }
}

function Invoke-Apply {
    if (-not (Test-Admin)) { Write-Log 'Abbruch: -Apply braucht Adminrechte'; exit 1 }
    try { $r = Install-Version $Apply }
    catch {
        Write-Log "FEHLER: $($_.Exception.Message)"
        $r = [pscustomobject]@{ Ok = $false; RebootRequired = $false; Message = "Wechsel auf $Apply fehlgeschlagen: $($_.Exception.Message)" }
    }
    if ($FromTask) {
        Unregister-ScheduledTask -TaskName $GT.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        [pscustomobject]@{ Version = $Apply; Time = (Get-Date -Format 's'); Ok = $r.Ok; RebootRequired = $r.RebootRequired; Message = $r.Message; Shown = $false } |
            ConvertTo-Json | Set-Content $GT.ResultFile -Encoding UTF8
        Send-UserMessage $r.Message -WaitMinutes 30
    }
    if ($r.Ok) { exit 0 } else { exit 1 }
}

# =============================================================================================
#  Oberfläche
# =============================================================================================

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    try {
        Add-Type -Namespace GpuTool -Name Native -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[System.Runtime.InteropServices.DllImport("uxtheme.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
'@
    } catch { }
    try { [void][GpuTool.Native]::SetProcessDPIAware() } catch { }
    [Windows.Forms.Application]::EnableVisualStyles()

    $sync = [hashtable]::Synchronized(@{
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Progress = -1; ProgressText = ''; Busy = $false; Done = $false; Result = $null; Error = $null
    })
    $Global:GtSync = $sync
    $ui  = @{ State = $null; Job = $null; OnDone = $null; Buttons = @(); FirstLoad = $true; Snapshot = $Snapshot }
    $ui.ThemeMode = if ($Theme) { $Theme } else { Get-Setting 'Theme' 'Auto' }   # Auto / Light / Dark
    $cfg = Get-Config

    # ---------- Farben (hell / dunkel) ----------
    function Get-SystemDark {
        if ($ui.ThemeMode -eq 'Dark')  { return $true }
        if ($ui.ThemeMode -eq 'Light') { return $false }
        try { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0 }
        catch { $false }
    }
    function rgb([int]$r, [int]$g, [int]$b) { [Drawing.Color]::FromArgb($r, $g, $b) }
    $C = @{}
    function Set-Palette([bool]$Dark) {
        if ($Dark) {
            $p = @{
                Back = (rgb 32 32 32); Surface = (rgb 40 40 40); Fore = (rgb 232 232 232); Muted = (rgb 165 165 160)
                Button = (rgb 52 52 52); ButtonBorder = (rgb 90 90 90); ButtonHover = (rgb 66 66 66)
                Header = (rgb 48 48 48); HeaderLine = (rgb 70 70 70); RowMuted = (rgb 135 135 135)
                Green = (rgb 192 221 151); GreenBg = (rgb 39 80 10)
                Red   = (rgb 247 193 193); RedBg   = (rgb 121 31 31)
                Amber = (rgb 250 199 117); AmberBg = (rgb 99 56 6)
                Gray  = (rgb 211 209 199); GrayBg  = (rgb 68 68 65)
            }
        } else {
            $p = @{
                Back = [Drawing.SystemColors]::Control; Surface = [Drawing.Color]::White; Fore = [Drawing.SystemColors]::ControlText; Muted = (rgb 95 94 90)
                Button = [Drawing.SystemColors]::Control; ButtonBorder = (rgb 173 173 173); ButtonHover = (rgb 229 241 251)
                Header = [Drawing.Color]::White; HeaderLine = (rgb 229 229 229); RowMuted = [Drawing.Color]::Gray
                Green = (rgb 39 80 10);   GreenBg = (rgb 234 243 222)
                Red   = (rgb 163 45 45);  RedBg   = (rgb 252 235 235)
                Amber = (rgb 133 79 11);  AmberBg = (rgb 250 238 218)
                Gray  = (rgb 95 94 90);   GrayBg  = (rgb 241 239 232)
            }
        }
        foreach ($k in @($p.Keys)) { $C[$k] = $p[$k] }
        $ui.Dark = $Dark
    }
    Set-Palette (Get-SystemDark)
    $fontBold = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)

    function New-Button([string]$Text, [int]$Width = 0) {
        $b = New-Object Windows.Forms.Button
        $b.Text = $Text; $b.AutoSize = $true; $b.Padding = New-Object Windows.Forms.Padding(6, 2, 6, 2)
        $b.Margin = New-Object Windows.Forms.Padding(0, 3, 8, 3)
        if ($Width) { $b.MinimumSize = New-Object Drawing.Size($Width, 0) }
        $ui.Buttons += $b
        $b
    }
    function New-Flow {
        $f = New-Object Windows.Forms.FlowLayoutPanel
        $f.AutoSize = $true; $f.Dock = 'Fill'; $f.WrapContents = $true; $f.Margin = New-Object Windows.Forms.Padding(0)
        $f
    }
    function Ask([string]$Text) {
        [Windows.Forms.MessageBox]::Show($form, $Text, 'GPU-Verwaltung', 'YesNo', 'Question') -eq 'Yes'
    }
    function Show-Msg([string]$Text, [string]$Icon = 'Information') {
        [void][Windows.Forms.MessageBox]::Show($form, $Text, 'GPU-Verwaltung', 'OK', $Icon)
    }

    # ---------- Fenster ----------
    $form = New-Object Windows.Forms.Form
    $form.SuspendLayout()
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $form.Font = New-Object Drawing.Font('Segoe UI', 9)
    $form.Text = 'GPU-Verwaltung'
    $form.ClientSize = New-Object Drawing.Size(880, 760)
    $form.MinimumSize = New-Object Drawing.Size(780, 680)
    $form.StartPosition = 'CenterScreen'
    try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\dxdiag.exe") } catch { }

    $root = New-Object Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.Padding = New-Object Windows.Forms.Padding(10); $root.ColumnCount = 1
    [void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    foreach ($st in @('AutoSize', 'AutoSize', 'Percent', 'AutoSize', 'AutoSize', 'AutoSize', 'Absolute', 'AutoSize')) {
        $rs = New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]$st)
        if ($st -eq 'Percent') { $rs.Height = 100 }
        if ($st -eq 'Absolute') { $rs.Height = 130 }
        [void]$root.RowStyles.Add($rs)
    }
    $root.RowCount = 8
    $form.Controls.Add($root)

    # ---------- Karten ----------
    $cards = New-Object Windows.Forms.TableLayoutPanel
    $cards.Dock = 'Fill'; $cards.AutoSize = $true; $cards.ColumnCount = $cfg.Devices.Count; $cards.Margin = New-Object Windows.Forms.Padding(0)
    $ui.Cards = @{}
    foreach ($d in $cfg.Devices) {
        [void]$cards.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, (100 / $cfg.Devices.Count))))
        $gb = New-Object Windows.Forms.GroupBox
        $gb.Text = $d.Name; $gb.Dock = 'Top'; $gb.Height = 58; $gb.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 6)
        $st = New-Object Windows.Forms.Label
        $st.AutoSize = $false; $st.Location = New-Object Drawing.Point(12, 24); $st.Size = New-Object Drawing.Size(150, 24)
        $st.TextAlign = 'MiddleCenter'; $st.Font = $fontBold; $st.Text = '...'; $st.Tag = 'keep'
        $ver = New-Object Windows.Forms.Label
        $ver.AutoSize = $true; $ver.Location = New-Object Drawing.Point(172, 28); $ver.Text = ''
        $gb.Controls.AddRange(@($st, $ver))
        $cards.Controls.Add($gb)
        $ui.Cards[$d.Short] = @{ Status = $st; Version = $ver }
    }
    $root.Controls.Add($cards, 0, 0)

    # ---------- Banner ----------
    $banner = New-Object Windows.Forms.Label
    $banner.AutoSize = $false; $banner.Dock = 'Fill'; $banner.Height = 46; $banner.Padding = New-Object Windows.Forms.Padding(8, 4, 8, 4)
    $banner.TextAlign = 'MiddleLeft'; $banner.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 8)
    $banner.BackColor = $C.GrayBg; $banner.ForeColor = $C.Gray; $banner.Text = 'Lade Status ...'; $banner.Tag = 'keep'
    $root.Controls.Add($banner, 0, 1)

    # ---------- Versionsliste ----------
    $gbList = New-Object Windows.Forms.GroupBox
    $gbList.Text = 'Treiberversionen (NVIDIA)'; $gbList.Dock = 'Fill'; $gbList.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 6)
    $tlList = New-Object Windows.Forms.TableLayoutPanel
    $tlList.Dock = 'Fill'; $tlList.ColumnCount = 1; $tlList.RowCount = 2
    [void]$tlList.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$tlList.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $lv = New-Object Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false
    [void]$lv.Columns.Add('Version', 80)
    foreach ($d in $cfg.Devices) { [void]$lv.Columns.Add("für $($d.Short)", 110) }
    [void]$lv.Columns.Add('Gemeinsam', 95)
    [void]$lv.Columns.Add('Lokal', 60)
    [void]$lv.Columns.Add('Status', 300)
    # Spaltenköpfe im Dunkelmodus selbst zeichnen (Windows zeichnet sie sonst immer hell)
    $lv.OwnerDraw = $true
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        if (-not $ui.Dark) { $e.DrawDefault = $true; return }
        $br = New-Object Drawing.SolidBrush($C.Header); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
        $pen = New-Object Drawing.Pen($C.HeaderLine)
        $e.Graphics.DrawLine($pen, $e.Bounds.Right - 1, $e.Bounds.Top + 4, $e.Bounds.Right - 1, $e.Bounds.Bottom - 5)
        $e.Graphics.DrawLine($pen, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1)
        $pen.Dispose()
        $r = New-Object Drawing.Rectangle(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 8), $e.Bounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $lv.Font, $r, $C.Fore,
            [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine')
    })
    $lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
    # letzte Spalte füllt die Breite, damit rechts kein heller Kopfbereich bleibt
    # Platz für die senkrechte Bildlaufleiste immer freihalten, sonst schaukelt sich die Breite auf
    function Set-LastColumnWidth {
        $w = $lv.Width - 4 - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        for ($i = 0; $i -lt $lv.Columns.Count - 1; $i++) { $w -= $lv.Columns[$i].Width }
        $w = [Math]::Max(120, $w)
        if ($lv.Columns[$lv.Columns.Count - 1].Width -ne $w) { $lv.Columns[$lv.Columns.Count - 1].Width = $w }
    }
    $lv.Add_Resize({ Set-LastColumnWidth })
    $tlList.Controls.Add($lv, 0, 0)
    $flList = New-Flow
    $chkAll = New-Object Windows.Forms.CheckBox
    $chkAll.Text = 'Alle Versionen anzeigen'; $chkAll.AutoSize = $true; $chkAll.Margin = New-Object Windows.Forms.Padding(0, 7, 16, 3)
    $btnRefresh  = New-Button 'Aktualisieren'
    $btnDownload = New-Button 'Laden und prüfen'
    $flList.Controls.AddRange(@($chkAll, $btnRefresh, $btnDownload))
    $tlList.Controls.Add($flList, 0, 1)
    $gbList.Controls.Add($tlList)
    $root.Controls.Add($gbList, 0, 2)

    # ---------- Wechseln ----------
    $gbSwitch = New-Object Windows.Forms.GroupBox
    $gbSwitch.Text = 'Auf ausgewählte Version wechseln'; $gbSwitch.Dock = 'Fill'; $gbSwitch.AutoSize = $true
    $gbSwitch.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 6)
    $tlSwitch = New-Object Windows.Forms.TableLayoutPanel
    $tlSwitch.Dock = 'Fill'; $tlSwitch.AutoSize = $true; $tlSwitch.ColumnCount = 1
    $flWhen = New-Flow
    $rbNow    = New-Object Windows.Forms.RadioButton; $rbNow.Text = 'Jetzt'; $rbNow.AutoSize = $true; $rbNow.Checked = $true
    $rbReboot = New-Object Windows.Forms.RadioButton; $rbReboot.Text = 'Beim nächsten Neustart'; $rbReboot.AutoSize = $true
    $rbAt     = New-Object Windows.Forms.RadioButton; $rbAt.Text = 'Um'; $rbAt.AutoSize = $true
    foreach ($rb in $rbNow, $rbReboot, $rbAt) { $rb.Margin = New-Object Windows.Forms.Padding(0, 7, 12, 3) }
    $txtAt = New-Object Windows.Forms.TextBox
    $txtAt.Width = 130; $txtAt.Margin = New-Object Windows.Forms.Padding(0, 5, 16, 3)
    $d0 = (Get-Date).Date.AddHours(22); if ($d0 -lt (Get-Date)) { $d0 = $d0.AddDays(1) }
    $txtAt.Text = $d0.ToString('dd.MM.yyyy HH:mm')
    $txtAt.Add_Enter({ $rbAt.Checked = $true })
    $btnSwitch = New-Button 'Wechseln'
    $btnSwitch.Font = $fontBold
    $flWhen.Controls.AddRange(@($rbNow, $rbReboot, $rbAt, $txtAt, $btnSwitch))
    $flPending = New-Flow
    $lblPending = New-Object Windows.Forms.Label
    $lblPending.AutoSize = $true; $lblPending.Margin = New-Object Windows.Forms.Padding(0, 8, 12, 3); $lblPending.Text = 'Kein Wechsel geplant.'
    $lblPending.ForeColor = $C.Gray; $lblPending.Tag = 'keep'
    $btnCancel = New-Button 'Geplanten Wechsel abbrechen'
    $flPending.Controls.AddRange(@($lblPending, $btnCancel))
    $tlSwitch.Controls.Add($flWhen, 0, 0)
    $tlSwitch.Controls.Add($flPending, 0, 1)
    $gbSwitch.Controls.Add($tlSwitch)
    $root.Controls.Add($gbSwitch, 0, 3)

    # ---------- Werkzeuge ----------
    $flTools = New-Flow
    $btnRepair = New-Button 'Abweichung reparieren'
    $btnSecure = New-Button 'Rechte absichern'
    $btnLog    = New-Button 'Log öffnen'
    $flTools.Controls.AddRange(@($btnRepair, $btnSecure, $btnLog))
    $root.Controls.Add($flTools, 0, 4)

    # ---------- Fortschritt ----------
    $flProg = New-Flow
    $flProg.WrapContents = $false
    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Size = New-Object Drawing.Size(260, 16); $progress.MarqueeAnimationSpeed = 30
    $progress.Margin = New-Object Windows.Forms.Padding(0, 6, 8, 6)
    $lblProgress = New-Object Windows.Forms.Label
    $lblProgress.AutoSize = $true; $lblProgress.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 0); $lblProgress.ForeColor = $C.Gray
    $flProg.Controls.AddRange(@($progress, $lblProgress))
    $root.Controls.Add($flProg, 0, 5)

    # ---------- Protokoll ----------
    $txtLog = New-Object Windows.Forms.TextBox
    $txtLog.Dock = 'Fill'; $txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
    $txtLog.Font = New-Object Drawing.Font('Consolas', 9); $txtLog.BackColor = [Drawing.Color]::White
    $txtLog.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
    $root.Controls.Add($txtLog, 0, 6)

    # ---------- Einstellungen (unten) ----------
    $tlSettings = New-Object Windows.Forms.TableLayoutPanel
    $tlSettings.Dock = 'Fill'; $tlSettings.AutoSize = $true; $tlSettings.ColumnCount = 2
    $tlSettings.Margin = New-Object Windows.Forms.Padding(0, 8, 8, 0)
    [void]$tlSettings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$tlSettings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    $flTheme = New-Flow
    $flTheme.WrapContents = $false
    $lblTheme = New-Object Windows.Forms.Label
    $lblTheme.Text = 'Darstellung:'; $lblTheme.AutoSize = $true; $lblTheme.Margin = New-Object Windows.Forms.Padding(0, 8, 8, 3)
    $rbAuto  = New-Object Windows.Forms.RadioButton; $rbAuto.Text  = 'Automatisch'; $rbAuto.Tag  = 'Auto'
    $rbLight = New-Object Windows.Forms.RadioButton; $rbLight.Text = 'Hell';        $rbLight.Tag = 'Light'
    $rbDark  = New-Object Windows.Forms.RadioButton; $rbDark.Text  = 'Dunkel';      $rbDark.Tag  = 'Dark'
    $flTheme.Controls.Add($lblTheme)
    foreach ($rb in $rbAuto, $rbLight, $rbDark) {
        $rb.AutoSize = $true; $rb.Margin = New-Object Windows.Forms.Padding(0, 7, 12, 3)
        $rb.Checked = ($rb.Tag -eq $ui.ThemeMode)
        $flTheme.Controls.Add($rb)
    }
    $flSetBtns = New-Flow
    $flSetBtns.WrapContents = $false
    $btnInstall = New-Button $(if (Test-Installed) { 'Verknüpfung erneuern' } else { 'Tool installieren' })
    $btnToolDir = New-Button 'Tool-Ordner öffnen'
    $btnToolDir.Margin = New-Object Windows.Forms.Padding(0, 3, 0, 3)
    $flSetBtns.Controls.AddRange(@($btnInstall, $btnToolDir))
    $tlSettings.Controls.Add($flTheme, 0, 0)
    $tlSettings.Controls.Add($flSetBtns, 1, 0)
    $root.Controls.Add($tlSettings, 0, 7)

    $form.ResumeLayout($false)
    $form.PerformLayout()

    # ---------- Hintergrundarbeit ----------
    function Set-Busy([bool]$Busy) {
        foreach ($b in $ui.Buttons) { $b.Enabled = -not $Busy }
        $chkAll.Enabled = -not $Busy
        if ($Busy) { $progress.Style = 'Marquee' }
        else { $progress.Style = 'Continuous'; $progress.Value = 0; $lblProgress.Text = '' }
    }

    function Start-Work([string]$Title, [scriptblock]$Work, [object[]]$Arguments, [scriptblock]$OnDone) {
        if ($sync.Busy) { return }
        $sync.Busy = $true; $sync.Done = $false; $sync.Result = $null; $sync.Error = $null
        $sync.Progress = -1; $sync.ProgressText = $Title
        Set-Busy $true
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.Open()
        $rs.SessionStateProxy.SetVariable('GtSync', $sync)
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($Self, $WorkText, $WorkArgs)
            . $Self -LoadCore
            try { $GtSync.Result = & ([scriptblock]::Create($WorkText)) @WorkArgs }
            catch { $GtSync.Error = $_.Exception.Message; Write-Log "FEHLER: $($_.Exception.Message)" }
            finally { $GtSync.Done = $true }
        }).AddArgument($GT.Self).AddArgument($Work.ToString()).AddArgument(@($Arguments))
        $ui.Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
        $ui.OnDone = $OnDone
    }

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 200
    $ui.Ticks = 0
    $timer.Add_Tick({
        # Windows-Farbmodus alle 2 Sekunden prüfen
        $ui.Ticks++
        if (($ui.Ticks % 10) -eq 0) { $dark = Get-SystemDark; if ($dark -ne $ui.Dark) { Set-Theme $dark } }
        $line = $null
        while ($sync.Log.TryDequeue([ref]$line)) { $txtLog.AppendText($line + "`r`n") }
        if ($sync.Busy) {
            if ($sync.Progress -ge 0) { $progress.Style = 'Continuous'; $progress.Value = [Math]::Min(100, [Math]::Max(0, $sync.Progress)) }
            else { $progress.Style = 'Marquee' }
            $lblProgress.Text = $sync.ProgressText
        }
        if ($sync.Busy -and $sync.Done) {
            try { [void]$ui.Job.PS.EndInvoke($ui.Job.Handle) } catch { }
            $ui.Job.PS.Dispose(); $ui.Job.RS.Close()
            $sync.Busy = $false
            Set-Busy $false
            $cb = $ui.OnDone; $ui.OnDone = $null
            if ($cb) { & $cb $sync.Result $sync.Error }
        }
    })

    # ---------- Anzeige ----------
    function Format-Date($d) { if ($d) { ([datetime]$d).ToString('dd.MM.yyyy') } else { '–' } }

    function Update-View {
        $st = $ui.State
        if (-not $st) { return }
        $sum = $st.Summary
        $cfgNow = Get-Config

        foreach ($g in $sum.Gpus) {
            $card = $ui.Cards[$g.Short]
            if (-not $g.Present)      { $t = 'nicht angeschlossen'; $fg = $C.Gray;  $bg = $C.GrayBg }
            elseif ($g.Problem -eq 0) { $t = 'OK';                  $fg = $C.Green; $bg = $C.GreenBg }
            elseif ($g.Problem -eq 22){ $t = 'deaktiviert';         $fg = $C.Amber; $bg = $C.AmberBg }
            else                      { $t = "Fehler Code $($g.Problem)"; $fg = $C.Red; $bg = $C.RedBg }
            $card.Status.Text = $t; $card.Status.ForeColor = $fg; $card.Status.BackColor = $bg
            $card.Version.Text = if ($g.Present) { "Treiber $($g.NvVersion)  ($($g.DriverVersion))" } else { '' }
        }

        $storeText = 'Treiberspeicher: ' + ((@($sum.Store) | ForEach-Object { "$($_.Original) $($_.NvVersion)" }) -join ', ')
        if ($sum.Ok -and $sum.Common) {
            $banner.Text = "Beide Karten nutzen die gemeinsame Version $($sum.Common).`r`n$storeText"
            $banner.BackColor = $C.GreenBg; $banner.ForeColor = $C.Green
        } else {
            $banner.Text = "Treiberversionen weichen ab ($($sum.Versions -join ', ')). 'Abweichung reparieren' stellt $($cfgNow.Current) wieder her.`r`n$storeText"
            $banner.BackColor = $C.AmberBg; $banner.ForeColor = $C.Amber
        }
        if ($st.Table.Error) { $banner.Text += "`r`nNVIDIA-Versionsliste nicht erreichbar: $($st.Table.Error)" }

        if ($st.Pending) {
            $lblPending.Text = "Geplant: Wechsel auf $($st.Pending.Version) $($st.Pending.When)."
            $lblPending.ForeColor = $C.Amber; $btnCancel.Visible = $true
        } else {
            $lblPending.Text = 'Kein Wechsel geplant.'; $lblPending.ForeColor = $C.Gray; $btnCancel.Visible = $false
        }
        $btnSecure.Visible = -not $st.Secure
        $btnRepair.Visible = -not $sum.Ok
        Update-List
    }

    function Update-List {
        $st = $ui.State
        if (-not $st) { return }
        $installed = $st.Summary.Common
        $selected  = if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Text } else { $null }
        $lv.BeginUpdate(); $lv.Items.Clear()
        foreach ($r in $st.Table.Rows) {
            $isInst = ($r.Version -eq $installed)
            if (-not $chkAll.Checked -and -not ($r.Common -or $r.Local -or $isInst)) { continue }
            $it = New-Object Windows.Forms.ListViewItem($r.Version)
            foreach ($d in $cfg.Devices) { [void]$it.SubItems.Add((Format-Date $r.Dates[$d.Short])) }
            [void]$it.SubItems.Add($(if ($r.Common) { 'ja' } else { 'nein' }))
            [void]$it.SubItems.Add($(if ($r.Local) { 'ja' } else { '' }))
            $text = if ($isInst) { 'installiert' }
                    elseif ($r.Local) { 'geprüft, bereit zum Wechseln' }
                    elseif ($r.Common) { 'für beide Karten gelistet, nicht geladen' }
                    else {
                        $missing = @($cfg.Devices | Where-Object { -not $r.Dates.ContainsKey($_.Short) } | ForEach-Object Short)
                        "nicht für $($missing -join ', ') gelistet"
                    }
            [void]$it.SubItems.Add($text)
            if ($isInst) { $it.Font = $fontBold; $it.ForeColor = $C.Green }
            elseif (-not $r.Common -and -not $r.Local) { $it.ForeColor = $C.RowMuted }
            $it.Tag = $r
            [void]$lv.Items.Add($it)
            if ($r.Version -eq $selected) { $it.Selected = $true }
        }
        $lv.EndUpdate()
        Set-LastColumnWidth
    }

    # ---------- Hell / Dunkel anwenden ----------
    function Set-NativeTheme($Ctl) {
        try { [void][GpuTool.Native]::SetWindowTheme($Ctl.Handle, $(if ($ui.Dark) { 'DarkMode_Explorer' } else { 'Explorer' }), $null) } catch { }
    }
    function Set-ControlTheme($Parent) {
        # Achtung: PowerShell unterscheidet keine Groß-/Kleinschreibung - $ctl, nicht $c (sonst überschreibt es $C)
        foreach ($ctl in $Parent.Controls) {
            if ($ctl.Tag -ne 'keep') {
                if ($ctl -is [Windows.Forms.Button]) {
                    if ($ui.Dark) {
                        $ctl.FlatStyle = 'Flat'; $ctl.BackColor = $C.Button; $ctl.ForeColor = $C.Fore
                        $ctl.FlatAppearance.BorderColor = $C.ButtonBorder
                        $ctl.FlatAppearance.MouseOverBackColor = $C.ButtonHover
                        $ctl.FlatAppearance.MouseDownBackColor = $C.ButtonBorder
                    } else {
                        $ctl.FlatStyle = 'Standard'; $ctl.BackColor = [Drawing.SystemColors]::Control
                        $ctl.ForeColor = [Drawing.SystemColors]::ControlText; $ctl.UseVisualStyleBackColor = $true
                    }
                }
                elseif ($ctl -is [Windows.Forms.ListView] -or $ctl -is [Windows.Forms.TextBox]) {
                    $ctl.BackColor = $C.Surface; $ctl.ForeColor = $C.Fore; Set-NativeTheme $ctl
                }
                else { $ctl.BackColor = $C.Back; $ctl.ForeColor = $C.Fore }
            }
            if ($ctl.Controls.Count) { Set-ControlTheme $ctl }
        }
    }
    function Set-Theme([bool]$Dark) {
        Set-Palette $Dark
        $form.BackColor = $C.Back; $form.ForeColor = $C.Fore
        Set-ControlTheme $form
        $lblProgress.ForeColor = $C.Muted
        try { $v = [int]$Dark; [void][GpuTool.Native]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch { }
        if ($ui.State) { Update-View } else { $banner.BackColor = $C.GrayBg; $banner.ForeColor = $C.Gray; $lblPending.ForeColor = $C.Gray }
        $form.Refresh()
    }

    function Get-SelectedRow {
        if ($lv.SelectedItems.Count) { return $lv.SelectedItems[0].Tag }
        Show-Msg 'Bitte zuerst eine Version in der Liste auswählen.'
        $null
    }

    function Invoke-Refresh {
        Start-Work 'Lade Status und Versionsliste ...' {
            $r = [pscustomobject]@{
                Summary    = Get-Summary
                Table      = Get-VersionTable
                Pending    = Get-PendingSwitch
                Secure     = Test-FolderSecure
                LastResult = Get-LastResult
            }
            $common = @($r.Table.Rows | Where-Object Common)
            Write-Log ('Status: {0} | NVIDIA: {1} Versionen, {2} gemeinsam, neueste gemeinsame {3}' -f
                $(if ($r.Summary.Ok) { "gemeinsame Version $($r.Summary.Common)" } else { "ABWEICHUNG ($($r.Summary.Versions -join ', '))" }),
                $r.Table.Rows.Count, $common.Count, $(if ($common) { $common[0].Version } else { '-' }))
            $r
        } @() {
            param($res, $err)
            if ($res) { $ui.State = $res; Update-View }
            if ($ui.FirstLoad) {
                $ui.FirstLoad = $false
                if ($ui.Snapshot) {
                    $form.Refresh()
                    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
                    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                    $bmp.Save($ui.Snapshot); $bmp.Dispose()
                    $form.Close(); return
                }
                $lr = $res.LastResult
                if ($lr -and -not $lr.Shown) {
                    Show-Msg ("Geplanter Wechsel vom {0}:`n`n{1}" -f ([datetime]$lr.Time).ToString('dd.MM.yyyy HH:mm'), $lr.Message) $(if ($lr.Ok) { 'Information' } else { 'Warning' })
                    Set-LastResultShown
                }
            }
        }
    }

    function Complete-Install($res, $err) {
        if ($err) { Show-Msg "Wechsel fehlgeschlagen:`n`n$err" 'Error' }
        elseif ($res.RebootRequired) {
            if (Ask "$($res.Message)`n`nJetzt neu starten?") { Restart-Computer -Force; return }
        }
        else { Show-Msg $res.Message }
        Invoke-Refresh
    }

    # ---------- Ereignisse ----------
    $chkAll.Add_CheckedChanged({ Update-List })
    $btnRefresh.Add_Click({ Invoke-Refresh })
    $lv.Add_DoubleClick({ $btnSwitch.PerformClick() })

    $btnDownload.Add_Click({
        $r = Get-SelectedRow; if (-not $r) { return }
        if ($r.Local) { Show-Msg "$($r.Version) ist bereits geladen und geprüft."; return }
        if (-not $r.Url) { Show-Msg "Für $($r.Version) ist keine Download-Adresse bekannt." 'Warning'; return }
        $text = "Version $($r.Version) herunterladen (ca. 900 MB) und prüfen?`n`nGeprüft werden Signatur, Archiv und ob beide Karten mit derselben Treiberversion enthalten sind. Installiert wird dabei nichts."
        if (-not $r.Common) {
            $text = "Achtung: $($r.Version) ist bei NVIDIA nicht für beide Karten gelistet. Ob das Paket trotzdem beide Karten enthält, zeigt erst die Prüfung.`n`n" + $text
        }
        if (-not (Ask $text)) { return }
        Start-Work "Lade $($r.Version) ..." { param($v, $u) Import-Version $v $u } @($r.Version, $r.Url) {
            param($res, $err)
            if ($err) { Show-Msg "Prüfung nicht bestanden, nichts wurde abgelegt:`n`n$err" 'Warning' }
            else { Show-Msg 'Geprüft und abgelegt. Die Version kann jetzt gewechselt werden.' }
            Invoke-Refresh
        }
    })

    $btnSwitch.Add_Click({
        $r = Get-SelectedRow; if (-not $r) { return }
        if (-not $r.Local) { Show-Msg "$($r.Version) ist noch nicht geladen. Bitte zuerst 'Laden und prüfen'."; return }
        $sum = $ui.State.Summary
        if ($sum.Ok -and $sum.Common -eq $r.Version) { Show-Msg "$($r.Version) ist bereits aktiv."; return }

        if ($rbNow.Checked) {
            if (-not (Ask "Jetzt auf $($r.Version) wechseln?`n`nDauer: einige Minuten. Bildschirme an der eGPU können dabei kurz schwarz werden.")) { return }
            Start-Work "Wechsle auf $($r.Version) ..." { param($v) Install-Version $v } @($r.Version) { param($res, $err) Complete-Install $res $err }
            return
        }
        $at = $null
        if ($rbAt.Checked) {
            try { $at = [datetime]::ParseExact($txtAt.Text.Trim(), 'dd.MM.yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
            catch { Show-Msg 'Bitte den Zeitpunkt im Format TT.MM.JJJJ HH:MM eingeben, z. B. 01.10.2026 22:00.' 'Warning'; $txtAt.Focus(); return }
            if ($at -lt (Get-Date).AddMinutes(1)) { Show-Msg 'Der Zeitpunkt liegt in der Vergangenheit.' 'Warning'; return }
        }
        if (-not (Test-FolderSecure)) {
            if (-not (Ask "Der Wechsel läuft später als SYSTEM. Dafür darf außer Administratoren niemand die Dateien in $($GT.Root) ändern.`n`nOrdnerrechte jetzt absichern?")) { return }
            try { Protect-Folder } catch { Show-Msg "Absichern fehlgeschlagen:`n`n$($_.Exception.Message)" 'Error'; return }
        }
        try { Register-Switch $r.Version $at } catch { Show-Msg "Planen fehlgeschlagen:`n`n$($_.Exception.Message)" 'Error'; return }
        $p = Get-PendingSwitch
        if ($rbReboot.Checked -and (Ask "Wechsel auf $($r.Version) ist für den nächsten Neustart geplant.`n`nJetzt neu starten?")) { Restart-Computer -Force; return }
        if ($rbAt.Checked) { Show-Msg "Wechsel auf $($r.Version) geplant: $($p.When).`n`nDer Laptop muss dann eingeschaltet sein. Ist er aus, wird der Wechsel beim nächsten Start nachgeholt." }
        Invoke-Refresh
    })

    $btnCancel.Add_Click({ Unregister-Switch; Invoke-Refresh })

    $btnRepair.Add_Click({
        $cur = (Get-Config).Current
        if (-not (Ask "Alle abweichenden NVIDIA-Treiber entfernen und die gemeinsame Version $cur wiederherstellen?")) { return }
        Start-Work "Repariere ($cur) ..." { param($v) Install-Version $v } @($cur) { param($res, $err) Complete-Install $res $err }
    })

    $btnSecure.Add_Click({
        if (-not (Ask "Schreibrechte für $($GT.Root) auf Administratoren und SYSTEM beschränken? Alle anderen dürfen nur noch lesen und ausführen.")) { return }
        try { Protect-Folder; Show-Msg 'Ordnerrechte abgesichert.' } catch { Show-Msg "Fehlgeschlagen:`n`n$($_.Exception.Message)" 'Error' }
        Invoke-Refresh
    })
    $btnLog.Add_Click({ Start-Process notepad.exe $GT.LogFile })
    $btnToolDir.Add_Click({ Start-Process explorer.exe $GT.Root })

    foreach ($rb in $rbAuto, $rbLight, $rbDark) {
        $rb.Add_CheckedChanged({
            param($s, $e)
            if (-not $s.Checked) { return }
            $ui.ThemeMode = $s.Tag
            try { Set-Setting 'Theme' $s.Tag } catch { Write-Log "Darstellung nicht gespeichert: $($_.Exception.Message)" }
            Set-Theme (Get-SystemDark)
        })
    }

    $btnInstall.Add_Click({
        if (Test-Installed) {
            try {
                New-DesktopShortcut $GT.Self
                if (-not (Test-FolderSecure)) { Protect-Folder }
                Show-Msg 'Desktop-Verknüpfung "GPU-Verwaltung" angelegt.'
            } catch { Show-Msg "Fehlgeschlagen:`n`n$($_.Exception.Message)" 'Error' }
            Invoke-Refresh
            return
        }
        $text = "Werkzeug nach $($GT.InstallDir) installieren?`n`n" +
                "- Ordner anlegen und gegen Änderungen durch normale Benutzer absichern`n" +
                "- Desktop-Verknüpfung 'GPU-Verwaltung' anlegen`n" +
                "- danach von dort neu starten"
        if (Test-Path (Join-Path $GT.InstallDir 'config.json')) {
            $text += "`n`nDort gibt es bereits eine Installation. Einstellungen und Treiberpakete bleiben erhalten, nur das Script wird aktualisiert."
        }
        if (-not (Ask $text)) { return }
        Start-Work 'Installiere ...' { Install-Tool } @() {
            param($res, $err)
            if ($err) { Show-Msg "Installation fehlgeschlagen:`n`n$err" 'Error'; return }
            # vom neuen Pfad neu starten (Adminrechte werden vererbt)
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$res`""
            $form.Close()
        }
    })

    $form.Add_Shown({ $timer.Start(); Invoke-Refresh })
    $form.Add_FormClosing({
        param($s, $e)
        if ($sync.Busy -and -not $ui.Snapshot) {
            Show-Msg 'Es läuft noch ein Vorgang. Bitte warten, bis er abgeschlossen ist.' 'Warning'
            $e.Cancel = $true
        }
    })

    Set-Theme $ui.Dark
    [void]$form.ShowDialog()
    $timer.Stop()
    $Global:GtSync = $null
}

# =============================================================================================
#  Start
# =============================================================================================

if ($LoadCore) { return }
if ($Status)   { Show-Status; return }
if ($Apply)    { Invoke-Apply; return }

if (-not (Test-Admin) -and -not $NoElevate) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($GT.Self)`""
    return
}
Show-Gui
