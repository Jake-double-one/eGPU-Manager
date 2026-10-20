<#
  GpuTool.ps1  -  eGPU Manager
  Keeps an internal NVIDIA GPU and an NVIDIA eGPU on the same driver version.
  Built for: RTX A2000 Laptop GPU (internal) + GeForce RTX 4070 (Razer Core X, Thunderbolt)
  https://github.com/Jake-double-one/eGPU-Manager  -  MIT License

  Background:
    Both cards use the same kernel driver nvlddmkm.sys, and Windows loads only one version of it.
    With different driver versions one card fails to start (code 31/43). With the same version
    both cards run side by side.

  Start:    desktop shortcut "eGPU Manager" (requests administrator rights)
  Console:  GpuTool.ps1 -Status            show status
            GpuTool.ps1 -Apply 596.36      install a stored version now (administrator rights)
  Internal: -Apply <version> -FromTask     one-time scheduled switch, the task deletes itself afterwards
            -LoadCore                      load functions only (used by the GUI's background work)

  Files:    config.json, Packages\<version>\*.exe (original NVIDIA installer, verified before every use)
            Archive\<version>\ (every replaced script version with a config.json snapshot)
  Log:      C:\ProgramData\GpuTool\gpu-tool.log (rotated at 1 MB -> gpu-tool.1.log, gpu-tool.2.log)
  Work:     C:\ProgramData\GpuTool\work\download-<version>\ (resumable .part downloads)

  Windows Update: the setting "Windows Update drivers" (Automatic / Block / Allow) controls the policy
            ExcludeWUDriversInQualityUpdate so Windows Update can't put one card on another version.
#>
param(
    [string]$Apply,
    [switch]$FromTask,
    [switch]$Status,
    [switch]$LoadCore,
    [switch]$NoElevate,
    [string]$Snapshot,
    [ValidateSet('', 'Light', 'Dark')][string]$Theme = '',   # empty = use setting
    [ValidateSet('', 'en', 'de')][string]$Lang = ''          # empty = use setting
)

$Global:GT = @{
    Version    = '1.2.0'
    Repo       = 'Jake-double-one/eGPU-Manager'
    AppName    = 'eGPU Manager'
    Self       = $PSCommandPath
    Root       = $PSScriptRoot
    ConfigFile = Join-Path $PSScriptRoot 'config.json'
    PkgDir     = Join-Path $PSScriptRoot 'Packages'
    DataDir    = Join-Path $env:ProgramData 'GpuTool'
    TaskName   = 'eGPU-Manager-DriverSwitch'
    InstallDir = 'C:\Scripts\GpuTool'
    SevenZip   = 'C:\Program Files\7-Zip\7z.exe'
    Api        = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php'
    Lang       = 'en'
}
$GT.RepoUrl    = "https://github.com/$($GT.Repo)"
$GT.LogFile    = Join-Path $GT.DataDir 'gpu-tool.log'
$GT.LogMaxKB   = 1024          # rotate above this size
$GT.LogKeep    = 2             # gpu-tool.1.log, gpu-tool.2.log
$GT.WorkDir    = Join-Path $GT.DataDir 'work'
$GT.ResultFile = Join-Path $GT.DataDir 'last-switch.json'
$GT.WuPolicyKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$GT.WuPolicyName = 'ExcludeWUDriversInQualityUpdate'
$GT.DownloadRetries = 5        # attempts per download (resumed with HTTP Range)
$GT.DownloadRetryWait = 10     # seconds between attempts
New-Item -ItemType Directory -Force -Path $GT.DataDir | Out-Null

# =============================================================================================
#  Strings (English, German)
# =============================================================================================

$Global:GTStrings = @{
    # --- formats ---
    'fmt.date'            = @('yyyy-MM-dd', 'dd.MM.yyyy')
    'fmt.datetime'        = @('yyyy-MM-dd HH:mm', 'dd.MM.yyyy HH:mm')
    'fmt.human'           = @('YYYY-MM-DD HH:MM', 'TT.MM.JJJJ HH:MM')
    'yes'                 = @('yes', 'ja')
    'no'                  = @('no', 'nein')

    # --- status / logs ---
    'log.status'          = @('Status: {0} | NVIDIA: {1} versions, {2} shared, newest shared {3}', 'Status: {0} | NVIDIA: {1} Versionen, {2} gemeinsam, neueste gemeinsame {3}')
    'log.common'          = @('shared version {0}', 'gemeinsame Version {0}')
    'log.mismatch'        = @('MISMATCH ({0})', 'ABWEICHUNG ({0})')
    'log.error'           = @('ERROR: {0}', 'FEHLER: {0}')
    'gpu.absent'          = @('not connected', 'nicht angeschlossen')
    'gpu.code'            = @('{0}, code {1}', '{0}, Code {1}')

    # --- download / verify ---
    'prog.download'       = @('Download {0:N0} of {1:N0} MB', 'Download {0:N0} von {1:N0} MB')
    'prog.download.rate'  = @('Download {0:N0} of {1:N0} MB - {2:N1} MB/s - {3} left', 'Download {0:N0} von {1:N0} MB - {2:N1} MB/s - noch {3}')
    'prog.download.wait'  = @('Connection lost - retrying in {0} s (attempt {1} of {2}) ...', 'Verbindung verloren - neuer Versuch in {0} s (Versuch {1} von {2}) ...')
    'log.resume'          = @('  Resuming download at {0:N0} MB', '  Setze Download bei {0:N0} MB fort')
    'log.retry'           = @('  Download interrupted ({0}) - retrying', '  Download unterbrochen ({0}) - neuer Versuch')
    'err.noresume'        = @('Server does not support resuming - starting over', 'Server unterstützt kein Fortsetzen - beginne von vorn')
    'err.cancelled'       = @('Cancelled by user', 'Vom Benutzer abgebrochen')
    'err.retries'         = @('Download failed after {0} attempts: {1}', 'Download nach {0} Versuchen fehlgeschlagen: {1}')
    'err.incomplete'      = @('Download incomplete ({0} of {1} bytes)', 'Download unvollständig ({0} von {1} Bytes)')
    'log.downloaded'      = @('  Download complete ({0:N0} bytes)', '  Download vollständig ({0:N0} Bytes)')
    'err.badversion'      = @('Invalid version string from NVIDIA: "{0}"', 'Ungültige Versionsangabe von NVIDIA: "{0}"')
    'time.sec'            = @('{0} s', '{0} s')
    'time.min'            = @('{0} min {1} s', '{0} min {1} s')
    'err.7zip'            = @('7-Zip not found ({0})', '7-Zip nicht gefunden ({0})')
    'prog.sig'            = @('Checking signature ...', 'Prüfe Signatur ...')
    'err.sig'             = @('Invalid signature ({0}, {1})', 'Signatur ungültig ({0}, {1})')
    'log.sigok'           = @('  Signature valid (NVIDIA Corporation)', '  Signatur gültig (NVIDIA Corporation)')
    'prog.archive'        = @('Testing archive ...', 'Teste Archiv ...')
    'err.archive'         = @('Archive test failed', 'Archivtest fehlgeschlagen')
    'log.archiveok'       = @('  Archive test passed', '  Archivtest fehlerfrei')
    'prog.infs'           = @('Checking driver files ...', 'Prüfe Treiberdateien ...')
    'err.notinpkg'        = @('{0} is not included in this package', '{0} ist in diesem Paket nicht enthalten')
    'log.devinf'          = @('  {0}: {1}, driver version {2}', '  {0}: {1}, Treiberversion {2}')
    'err.vermix'          = @('Different driver versions in package: {0}', 'Unterschiedliche Treiberversionen im Paket: {0}')
    'err.catalog'         = @('Driver catalog is not validly signed ({0})', 'Treiberkatalog nicht gültig signiert ({0})')
    'log.catok'           = @('  Driver catalog validly signed', '  Treiberkatalog gültig signiert')
    'err.nourl'           = @('No download URL for {0}', 'Keine Download-Adresse für {0}')
    'log.import'          = @('Downloading and verifying {0}', 'Lade und prüfe {0}')
    'log.imported'        = @('Verified and stored: {0} ({1}) - both cards included', 'Geprüft und abgelegt: {0} ({1}) - beide Karten enthalten')
    'log.removedpkg'      = @('Removed old package: {0}', 'Altes Paket entfernt: {0}')
    'log.migrated'        = @('Moved package folder Pakete -> Packages', 'Paketordner verschoben: Pakete -> Packages')

    # --- switch ---
    'err.admin'           = @('Administrator rights are required to switch drivers', 'Für den Treiberwechsel sind Adminrechte nötig')
    'err.notlocal'        = @('Version {0} is not stored locally - download and verify it first', 'Version {0} ist nicht lokal abgelegt - zuerst laden und prüfen')
    'log.switch'          = @('Switching to {0} ({1})', 'Wechsel auf {0} ({1})')
    'prog.pkg'            = @('Checking package ...', 'Prüfe Paket ...')
    'err.pkgmissing'      = @('Package file missing: {0}', 'Paketdatei fehlt: {0}')
    'err.hash'            = @('Checksum mismatch - the package has been modified', 'Prüfsumme stimmt nicht - Paket wurde verändert')
    'err.sigshort'        = @('Invalid signature', 'Signatur ungültig')
    'log.pkgok'           = @('  Package unchanged, signature valid', '  Paket unverändert, Signatur gültig')
    'prog.extract'        = @('Extracting driver ...', 'Entpacke Treiber ...')
    'err.extract'         = @('Extraction failed', 'Entpacken fehlgeschlagen')
    'err.infmissing'      = @('{0} missing in package', '{0} fehlt im Paket')
    'prog.remove'         = @('Removing {0} ...', 'Entferne {0} ...')
    'log.removed'         = @('  removed {0} ({1}, {2}) -> exit {3}', '  entfernt {0} ({1}, {2}) -> Exit {3}')
    'prog.install'        = @('Installing {0} ...', 'Installiere {0} ...')
    'log.installed'       = @('  installed {0} -> exit {1}', '  installiert {0} -> Exit {1}')
    'msg.switchok'        = @('Both cards now use the shared version {0}.', 'Beide Karten nutzen jetzt die gemeinsame Version {0}.')
    'msg.switchreboot'    = @('Driver {0} is installed. Restart the laptop to complete the switch.', 'Treiber {0} ist installiert. Bitte den Laptop neu starten, um den Wechsel abzuschließen.')
    'msg.applyfail'       = @('Switch to {0} failed: {1}', 'Wechsel auf {0} fehlgeschlagen: {1}')
    'err.applyadmin'      = @('Aborted: -Apply requires administrator rights', 'Abbruch: -Apply braucht Adminrechte')

    # --- scheduling / folder ---
    'log.secured'         = @('Folder permissions secured ({0}) -> exit {1}', 'Ordnerrechte abgesichert ({0}) -> Exit {1}')
    'err.notsecure'       = @("Folder {0} isn't secured - click 'Secure folder' first", "Ordner {0} ist nicht abgesichert - zuerst 'Rechte absichern'")
    'when.reboot'         = @('at next restart', 'beim nächsten Neustart')
    'task.desc'           = @('eGPU Manager: one-time switch to NVIDIA {0} ({1}). Deletes itself after running.', 'eGPU Manager: einmaliger Wechsel auf NVIDIA {0} ({1}). Löscht sich nach dem Lauf selbst.')
    'log.scheduled'       = @('Switch to {0} scheduled: {1}', 'Wechsel auf {0} geplant: {1}')
    'log.unscheduled'     = @('Scheduled switch cancelled', 'Geplanter Wechsel abgebrochen')
    'log.rotated'         = @('Log rotated ({0:N0} KB)', 'Log rotiert ({0:N0} KB)')

    # --- Windows Update driver lock ---
    'log.wu.set'          = @('Windows Update driver lock set (ExcludeWUDriversInQualityUpdate=1)', 'Windows-Update-Treibersperre gesetzt (ExcludeWUDriversInQualityUpdate=1)')
    'log.wu.removed'      = @('Windows Update driver lock removed', 'Windows-Update-Treibersperre entfernt')
    'err.wu.gpo'          = @('The Windows Update driver setting is managed by group policy - the tool cannot change it', 'Die Windows-Update-Treibereinstellung wird per Gruppenrichtlinie verwaltet - das Tool kann sie nicht ändern')
    'ui.wu'               = @('Windows Update drivers:', 'Windows-Update-Treiber:')
    'opt.wu.auto'         = @('Automatic', 'Automatisch')
    'opt.wu.block'        = @('Block', 'Sperren')
    'opt.wu.allow'        = @('Allow', 'Zulassen')
    'ban.wu.on'           = @('Windows Update driver lock: active', 'Windows-Update-Treibersperre: aktiv')
    'ban.wu.off'          = @('Windows Update driver lock: off', 'Windows-Update-Treibersperre: aus')
    'ban.wu.gpo'          = @('Windows Update drivers: managed by group policy', 'Windows-Update-Treiber: per Gruppenrichtlinie verwaltet')
    'tip.wu'              = @("Automatic: lock while a version installed by this tool is active, so Windows Update can't replace one card's driver.`nBlock: lock always.`nAllow: never lock (Windows Update may reinstall different versions).", "Automatisch: Sperre, solange eine mit diesem Tool installierte Version aktiv ist, damit Windows Update nicht den Treiber einer Karte ersetzt.`nSperren: Sperre immer.`nZulassen: nie sperren (Windows Update darf abweichende Versionen einspielen).")
    'con.wu'              = @('WU driver lock', 'WU-Treibersperre')
    'con.wu.on'           = @('active ({0})', 'aktiv ({0})')
    'con.wu.off'          = @('off ({0})', 'aus ({0})')

    # --- install / update ---
    'log.install'         = @('Installing to {0}', 'Installiere nach {0}')
    'log.existing'        = @('  existing installation found - settings and packages are kept', '  vorhandene Installation gefunden - Einstellungen und Pakete bleiben erhalten')
    'prog.copypkg'        = @('Copying driver packages ...', 'Kopiere Treiberpakete ...')
    'log.copiedpkg'       = @('  driver packages copied', '  Treiberpakete übernommen')
    'log.shortcut'        = @('Desktop shortcut created: {0}', 'Desktop-Verknüpfung angelegt: {0}')
    'lnk.desc'            = @('Keep the internal NVIDIA GPU and the eGPU on the same driver version', 'Interne NVIDIA-GPU und eGPU auf derselben Treiberversion halten')
    'log.update'          = @('Updating eGPU Manager {0} -> {1}', 'Aktualisiere eGPU Manager {0} -> {1}')
    'log.updated'         = @('Updated to {0} (previous version archived in {1})', 'Aktualisiert auf {0} (vorherige Version archiviert in {1})')
    'log.archived'        = @('Archived script version {0} -> {1}', 'Script-Version {0} archiviert -> {1}')
    'err.devcopy'         = @('This is a development copy (git repository) - update it with git pull', 'Das ist eine Entwicklerkopie (Git-Repository) - bitte mit git pull aktualisieren')
    'err.update.parse'    = @('The downloaded script contains errors - update aborted', 'Das heruntergeladene Script enthält Fehler - Update abgebrochen')
    'err.update.version'  = @('The downloaded script has an unexpected version - update aborted', 'Das heruntergeladene Script hat eine unerwartete Version - Update abgebrochen')

    # --- console ---
    'con.store'           = @('Driver store', 'Treiberspeicher')
    'con.ok'              = @('OK: shared version {0}', 'OK: gemeinsame Version {0}')
    'con.mismatch'        = @('MISMATCH: {0}', 'ABWEICHUNG: {0}')
    'con.pending'         = @('Scheduled: switch to {0} {1}', 'Geplant: Wechsel auf {0} {1}')

    # --- GUI ---
    'ui.loading'          = @('Loading status ...', 'Lade Status ...')
    'ui.versions'         = @('Driver versions (NVIDIA)', 'Treiberversionen (NVIDIA)')
    'col.version'         = @('Version', 'Version')
    'col.for'             = @('for {0}', 'für {0}')
    'col.shared'          = @('Shared', 'Gemeinsam')
    'col.local'           = @('Local', 'Lokal')
    'col.status'          = @('Status', 'Status')
    'ui.showall'          = @('Show all versions', 'Alle Versionen anzeigen')
    'ui.refresh'          = @('Refresh', 'Aktualisieren')
    'ui.download'         = @('Download and verify', 'Laden und prüfen')
    'ui.switchgroup'      = @('Switch to selected version', 'Auf ausgewählte Version wechseln')
    'ui.now'              = @('Now', 'Jetzt')
    'ui.atreboot'         = @('At next restart', 'Beim nächsten Neustart')
    'ui.at'               = @('At', 'Um')
    'ui.switch'           = @('Switch', 'Wechseln')
    'ui.nopending'        = @('No switch scheduled.', 'Kein Wechsel geplant.')
    'ui.pending'          = @('Scheduled: switch to {0} {1}.', 'Geplant: Wechsel auf {0} {1}.')
    'ui.cancelpending'    = @('Cancel scheduled switch', 'Geplanten Wechsel abbrechen')
    'ui.repair'           = @('Repair mismatch', 'Abweichung reparieren')
    'ui.secure'           = @('Secure folder', 'Rechte absichern')
    'ui.openlog'          = @('Open log', 'Log öffnen')
    'ui.cancel'           = @('Cancel', 'Abbrechen')
    'ui.cancelling'       = @('Cancelling ...', 'Breche ab ...')
    'msg.cancelled'       = @('Download cancelled. The partial file is kept and will be resumed next time.', 'Download abgebrochen. Die Teildatei bleibt erhalten und wird beim nächsten Mal fortgesetzt.')
    'ui.theme'            = @('Theme:', 'Darstellung:')
    'ui.lang'             = @('Language:', 'Sprache:')
    'opt.auto'            = @('Automatic', 'Automatisch')
    'opt.light'           = @('Light', 'Hell')
    'opt.dark'            = @('Dark', 'Dunkel')
    'ui.install'          = @('Install tool', 'Tool installieren')
    'ui.reinstall'        = @('Recreate shortcut', 'Verknüpfung erneuern')
    'ui.tooldir'          = @('Open tool folder', 'Tool-Ordner öffnen')
    'ui.update'           = @('Update to {0}', 'Update auf {0}')
    'ui.dev'              = @('dev', 'dev')
    'st.ok'               = @('OK', 'OK')
    'st.disabled'         = @('disabled', 'deaktiviert')
    'st.error'            = @('Error code {0}', 'Fehler Code {0}')
    'card.driver'         = @('Driver {0}  ({1})', 'Treiber {0}  ({1})')
    'ban.store'           = @('Driver store: {0}', 'Treiberspeicher: {0}')
    'ban.ok'              = @('Both cards use the shared version {0}.', 'Beide Karten nutzen die gemeinsame Version {0}.')
    'ban.mismatch'        = @("Driver versions differ ({0}). 'Repair mismatch' restores {1}.", "Treiberversionen weichen ab ({0}). 'Abweichung reparieren' stellt {1} wieder her.")
    'ban.offline'         = @('NVIDIA version list unavailable: {0}', 'NVIDIA-Versionsliste nicht erreichbar: {0}')
    'ls.installed'        = @('installed', 'installiert')
    'ls.ready'            = @('verified, ready to switch', 'geprüft, bereit zum Wechseln')
    'ls.shared'           = @('listed for both cards, not downloaded', 'für beide Karten gelistet, nicht geladen')
    'ls.notfor'           = @('not listed for {0}', 'nicht für {0} gelistet')
    'prog.loading'        = @('Loading status and version list ...', 'Lade Status und Versionsliste ...')
    'prog.downloading'    = @('Downloading {0} ...', 'Lade {0} ...')
    'prog.switching'      = @('Switching to {0} ...', 'Wechsle auf {0} ...')
    'prog.repair'         = @('Repairing ({0}) ...', 'Repariere ({0}) ...')
    'prog.installing'     = @('Installing ...', 'Installiere ...')
    'prog.updating'       = @('Updating ...', 'Aktualisiere ...')
    'msg.select'          = @('Select a version in the list first.', 'Bitte zuerst eine Version in der Liste auswählen.')
    'msg.lastswitch'      = @("Scheduled switch on {0}:`n`n{1}", "Geplanter Wechsel vom {0}:`n`n{1}")
    'msg.switchfail'      = @("Switch failed:`n`n{0}", "Wechsel fehlgeschlagen:`n`n{0}")
    'ask.rebootnow'       = @("{0}`n`nRestart now?", "{0}`n`nJetzt neu starten?")
    'msg.alreadylocal'    = @('{0} is already downloaded and verified.', '{0} ist bereits geladen und geprüft.')
    'msg.nourl'           = @('No download URL is known for {0}.', 'Für {0} ist keine Download-Adresse bekannt.')
    'ask.download'        = @("Download version {0} (approx. 900 MB) and verify it?`n`nChecked: signature, archive, and whether both cards are included with the same driver version. Nothing is installed.", "Version {0} herunterladen (ca. 900 MB) und prüfen?`n`nGeprüft werden Signatur, Archiv und ob beide Karten mit derselben Treiberversion enthalten sind. Installiert wird dabei nichts.")
    'ask.download.resume' = @('A partial download ({0:N0} MB) exists and will be resumed.', 'Ein Teildownload ({0:N0} MB) ist vorhanden und wird fortgesetzt.')
    'ask.download.warn'   = @("Warning: NVIDIA doesn't list {0} for both cards. Only the verification shows whether the package still contains both.`n`n", "Achtung: {0} ist bei NVIDIA nicht für beide Karten gelistet. Ob das Paket trotzdem beide Karten enthält, zeigt erst die Prüfung.`n`n")
    'msg.verifyfail'      = @("Verification failed, nothing was stored:`n`n{0}", "Prüfung nicht bestanden, nichts wurde abgelegt:`n`n{0}")
    'msg.verified'        = @('Verified and stored. You can switch to this version now.', 'Geprüft und abgelegt. Die Version kann jetzt gewechselt werden.')
    'msg.notlocal'        = @("{0} hasn't been downloaded yet. Use 'Download and verify' first.", "{0} ist noch nicht geladen. Bitte zuerst 'Laden und prüfen'.")
    'msg.active'          = @('{0} is already active.', '{0} ist bereits aktiv.')
    'ask.switchnow'       = @("Switch to {0} now?`n`nThis takes a few minutes. Displays on the eGPU may go black briefly.", "Jetzt auf {0} wechseln?`n`nDauer: einige Minuten. Bildschirme an der eGPU können dabei kurz schwarz werden.")
    'msg.badtime'         = @('Enter the time as {0}, e.g. {1}.', 'Bitte den Zeitpunkt im Format {0} eingeben, z. B. {1}.')
    'msg.pasttime'        = @('That time is in the past.', 'Der Zeitpunkt liegt in der Vergangenheit.')
    'ask.secureschedule'  = @("The switch will run later as SYSTEM. For that, only administrators may change the files in {0}.`n`nSecure the folder now?", "Der Wechsel läuft später als SYSTEM. Dafür darf außer Administratoren niemand die Dateien in {0} ändern.`n`nOrdnerrechte jetzt absichern?")
    'msg.securefail'      = @("Securing failed:`n`n{0}", "Absichern fehlgeschlagen:`n`n{0}")
    'msg.schedulefail'    = @("Scheduling failed:`n`n{0}", "Planen fehlgeschlagen:`n`n{0}")
    'ask.rebootscheduled' = @("Switch to {0} is scheduled for the next restart.`n`nRestart now?", "Wechsel auf {0} ist für den nächsten Neustart geplant.`n`nJetzt neu starten?")
    'msg.scheduledat'     = @("Switch to {0} scheduled: {1}.`n`nThe laptop has to be on at that time. If it's off, the switch runs at the next start.", "Wechsel auf {0} geplant: {1}.`n`nDer Laptop muss dann eingeschaltet sein. Ist er aus, wird der Wechsel beim nächsten Start nachgeholt.")
    'ask.repair'          = @('Remove all mismatching NVIDIA drivers and restore the shared version {0}?', 'Alle abweichenden NVIDIA-Treiber entfernen und die gemeinsame Version {0} wiederherstellen?')
    'ask.secure'          = @('Restrict write access to {0} to administrators and SYSTEM? Everyone else can only read and run.', 'Schreibrechte für {0} auf Administratoren und SYSTEM beschränken? Alle anderen dürfen nur noch lesen und ausführen.')
    'msg.secured'         = @('Folder permissions secured.', 'Ordnerrechte abgesichert.')
    'msg.failed'          = @("Failed:`n`n{0}", "Fehlgeschlagen:`n`n{0}")
    'msg.busy'            = @("An operation is still running. Wait until it's finished.", 'Es läuft noch ein Vorgang. Bitte warten, bis er abgeschlossen ist.')
    'msg.shortcut'        = @('Desktop shortcut "eGPU Manager" created.', 'Desktop-Verknüpfung "eGPU Manager" angelegt.')
    'ask.install'         = @("Install the tool to {0}?`n`n- create the folder and protect it against changes by standard users`n- create the desktop shortcut 'eGPU Manager'`n- restart from there", "Werkzeug nach {0} installieren?`n`n- Ordner anlegen und gegen Änderungen durch normale Benutzer absichern`n- Desktop-Verknüpfung 'eGPU Manager' anlegen`n- danach von dort neu starten")
    'ask.install.existing'= @("`n`nThere's already an installation there. Settings and driver packages are kept; only the script is replaced.", "`n`nDort gibt es bereits eine Installation. Einstellungen und Treiberpakete bleiben erhalten, nur das Script wird ersetzt.")
    'msg.installfail'     = @("Installation failed:`n`n{0}", "Installation fehlgeschlagen:`n`n{0}")
    'ask.update'          = @("Update eGPU Manager from {0} to {1}?`n`nThe new version is downloaded from GitHub and checked, then the tool restarts. Settings and driver packages are kept; the current script is archived in Archive\{0}\.", "eGPU Manager von {0} auf {1} aktualisieren?`n`nDie neue Version wird von GitHub geladen und geprüft, danach startet das Werkzeug neu. Einstellungen und Treiberpakete bleiben erhalten; das aktuelle Script wird in Archive\{0}\ archiviert.")
    'msg.updatefail'      = @("Update failed:`n`n{0}", "Update fehlgeschlagen:`n`n{0}")
}

# Translate a key; extra arguments are inserted with -f
function T([string]$Key) {
    $e = $Global:GTStrings[$Key]
    if (-not $e) { return $Key }
    $s = if ($Global:GT.Lang -eq 'de') { $e[1] } else { $e[0] }
    if ($args.Count) { $s -f $args } else { $s }
}

# =============================================================================================
#  Basics
# =============================================================================================

# Log rotation: above LogMaxKB the log is moved to gpu-tool.1.log (and that one to gpu-tool.2.log)
function Invoke-LogRotation {
    try {
        $f = Get-Item $GT.LogFile -ErrorAction Stop
        if ($f.Length -lt ($GT.LogMaxKB * 1KB)) { return }
        $base = [IO.Path]::Combine($f.DirectoryName, [IO.Path]::GetFileNameWithoutExtension($f.Name))
        for ($i = $GT.LogKeep; $i -ge 1; $i--) {
            $src = if ($i -eq 1) { $f.FullName } else { "$base.$($i - 1).log" }
            if (Test-Path $src) { Move-Item $src "$base.$i.log" -Force -ErrorAction Stop }
        }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (T 'log.rotated' ($f.Length / 1KB))
        Set-Content -Path $GT.LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Write-Log([string]$Msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    try {
        if ((Get-Random -Maximum 50) -eq 0) { Invoke-LogRotation }   # size check on roughly every 50th line
        Add-Content -Path $GT.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
    if ($Global:GtSync) { $Global:GtSync.Log.Enqueue($line) } else { Write-Host $line }
}

function Set-Progress([int]$Percent, [string]$Text) {
    if ($Global:GtSync) { $Global:GtSync.Progress = $Percent; $Global:GtSync.ProgressText = $Text }
}

# Cancel flag set by the GUI; long-running work checks it between steps
function Test-Cancelled {
    [bool]($Global:GtSync -and $Global:GtSync.Cancel)
}

# NVIDIA version strings look like 596.36 or 580.88. Everything else is rejected before it reaches a
# path, a command line or a file name.
function Test-NvVersionString([string]$Version) {
    "$Version" -match '^\d{3}\.\d{2,3}$'
}

function Assert-NvVersionString([string]$Version) {
    if (-not (Test-NvVersionString $Version)) { throw (T 'err.badversion' $Version) }
}

# Seconds -> "45 s" / "3 min 12 s"
function Format-Duration([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) { return '?' }
    $s = [int][Math]::Round($Seconds)
    if ($s -lt 60) { T 'time.sec' $s } else { T 'time.min' ([int][Math]::Floor($s / 60)) ($s % 60) }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Config {
    if (-not (Test-Path $GT.ConfigFile)) { Save-Config (New-DefaultConfig) }
    Get-Content $GT.ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Config($Config) {
    $Config | ConvertTo-Json -Depth 6 | Set-Content -Path $GT.ConfigFile -Encoding UTF8
}

# Default configuration, used when only GpuTool.ps1 was copied without config.json
function New-DefaultConfig {
    [pscustomobject]@{
        Current      = ''
        KeepVersions = 2
        DownloadFrom = '4070'
        Settings     = [pscustomobject]@{ Theme = 'Auto'; Language = 'Auto'; WuDrivers = 'Auto' }   # WuDrivers: Auto / Block / Allow
        Devices      = @(
            [pscustomobject]@{ Short = 'A2000'; Name = 'RTX A2000 (internal)'; HardwareId = 'PCI\VEN_10DE&DEV_25BA&SUBSYS_0B1A1028'; Psid = 124; Pfid = 989 },
            [pscustomobject]@{ Short = '4070';  Name = 'RTX 4070 (eGPU)';      HardwareId = 'PCI\VEN_10DE&DEV_2786&SUBSYS_51371462'; Psid = 127; Pfid = 1015 }
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

# Language: setting Auto -> German if Windows display language is German, otherwise English
function Resolve-Language([string]$Setting) {
    if ($Setting -in 'en', 'de') { return $Setting }
    if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de') { 'de' } else { 'en' }
}

# 1.0 stored packages in "Pakete" - move them to "Packages"
function Move-LegacyPackages {
    $old = Join-Path $GT.Root 'Pakete'
    if (-not (Test-Path $old) -or (Test-Path $GT.PkgDir)) { return }
    try { Rename-Item $old 'Packages' -ErrorAction Stop } catch { return }
    $cfg = Get-Config
    foreach ($p in @($cfg.Packages)) { $p.File = $p.File -replace '^Pakete\\', 'Packages\' }
    Save-Config $cfg
    Write-Log (T 'log.migrated')
}

# 32.0.15.9636 -> 596.36 (NVIDIA scheme: last digit of the 3rd field + 4th field)
function ConvertTo-NvVersion([string]$DriverVersion) {
    $p = "$DriverVersion".Split('.')
    if ($p.Count -ne 4) { return $null }
    $d = $p[2].Substring($p[2].Length - 1) + $p[3].PadLeft(4, '0')
    '{0}.{1}' -f $d.Substring(0, 3), $d.Substring(3)
}

# =============================================================================================
#  Windows Update driver lock
#  Policy ExcludeWUDriversInQualityUpdate=1 stops Windows Update from installing drivers, which
#  is the usual way one of the two cards ends up on a different NVIDIA version again.
#  Setting WuDrivers: Auto  = lock while a version installed by this tool is active (Current set)
#                     Block = lock always
#                     Allow = never lock
#  A domain group policy owns the value when its .reg source is GPO; the tool only reports then.
# =============================================================================================

function Get-WuDriverLock {
    $v = $null
    try { $v = (Get-ItemProperty -Path $GT.WuPolicyKey -Name $GT.WuPolicyName -ErrorAction Stop).($GT.WuPolicyName) } catch { }
    [pscustomobject]@{
        Locked = ([int]$v -eq 1)
        Mode   = Get-Setting 'WuDrivers' 'Auto'
        Gpo    = Test-WuPolicyFromGpo
    }
}

# The policy comes from a domain or local GPO when it also shows up in the Group Policy registry cache
function Test-WuPolicyFromGpo {
    $pol = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Registry.pol'
    if (-not (Test-Path $pol)) { return $false }
    try {
        $bytes = [IO.File]::ReadAllBytes($pol)
        $text  = [Text.Encoding]::Unicode.GetString($bytes)
        $text -match [regex]::Escape($GT.WuPolicyName)
    } catch { $false }
}

# Wanted state for the current mode
function Get-WuDriverLockWanted([string]$Mode) {
    switch ($Mode) {
        'Block' { $true }
        'Allow' { $false }
        default { [bool]((Get-Config).Current) }
    }
}

function Set-WuDriverLock([bool]$Lock) {
    if (-not (Test-Admin)) { throw (T 'err.admin') }
    if (Test-WuPolicyFromGpo) { throw (T 'err.wu.gpo') }
    $cur = Get-WuDriverLock
    if ($cur.Locked -eq $Lock) { return $false }
    if ($Lock) {
        New-Item -Path $GT.WuPolicyKey -Force | Out-Null
        New-ItemProperty -Path $GT.WuPolicyKey -Name $GT.WuPolicyName -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Log (T 'log.wu.set')
    } else {
        Remove-ItemProperty -Path $GT.WuPolicyKey -Name $GT.WuPolicyName -ErrorAction SilentlyContinue
        Write-Log (T 'log.wu.removed')
    }
    $true
}

# Brings the registry in line with the setting. Called after refresh, switch and scheduled runs.
# Returns $true when something changed. Never throws (a GPO-managed value is just reported).
function Sync-WuDriverLock {
    if (-not (Test-Admin)) { return $false }
    $mode = Get-Setting 'WuDrivers' 'Auto'
    try { Set-WuDriverLock (Get-WuDriverLockWanted $mode) } catch { Write-Log (T 'log.error' $_.Exception.Message); $false }
}

# =============================================================================================
#  Status
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

# NVIDIA display drivers in the Windows driver store (pnputil XML: fast, language-independent, no admin needed)
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
#  NVIDIA versions
# =============================================================================================

function Get-OnlineList([int]$Psid, [int]$Pfid) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $u = "$($GT.Api)?func=DriverManualLookup&psid=$Psid&pfid=$Pfid&osID=57&languageCode=1033&beta=0&isWHQL=1" +
         '&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=100'
    foreach ($e in (Invoke-RestMethod -UseBasicParsing -Uri $u -TimeoutSec 30).IDS) {
        $i = $e.downloadInfo
        # everything from the API is untrusted input: only well-formed versions and https NVIDIA URLs get through
        if (-not (Test-NvVersionString $i.Version)) { Write-Log (T 'err.badversion' $i.Version); continue }
        $url = "$($i.DownloadURL)"
        if ($url -notmatch '^https://[a-z0-9.-]+\.nvidia\.com/') { $url = $null }
        $date = $null
        try { $date = [datetime]::ParseExact($i.ReleaseDateTime, 'ddd MMM dd, yyyy', [Globalization.CultureInfo]::InvariantCulture) } catch { }
        [pscustomobject]@{ Version = "$($i.Version)"; Date = $date; Url = $url; Name = [uri]::UnescapeDataString("$($i.Name)") }
    }
}

# One row per version: listed for which card, shared, stored locally
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
#  Download, verify, store packages
# =============================================================================================

# Resumable download.
#   - writes to <Path>.part and renames when complete
#   - an existing .part is continued with an HTTP Range request (the server's ETag/Last-Modified
#     is kept in <Path>.part.meta so a changed file on the server starts over)
#   - up to $GT.DownloadRetries attempts; a dropped connection waits $GT.DownloadRetryWait seconds
#   - progress text shows speed (last ~5 s) and remaining time, cancel keeps the .part for next time
function Save-Download([string]$Url, [string]$Path) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $part = "$Path.part"
    $meta = "$Path.part.meta"
    # a completed file that was never verified (interrupted earlier) is treated like a .part
    if ((Test-Path $Path) -and -not (Test-Path $part)) { Move-Item $Path $part -Force }

    $attempt = 0
    $lastErr = $null
    while ($true) {
        if (Test-Cancelled) { throw (T 'err.cancelled') }
        $attempt++
        try {
            if (Invoke-DownloadAttempt $Url $part $meta) { break }
            # $false = the partial file didn't match the server's file any more - start over
            # (counts as an attempt, so a server that keeps rejecting us can't loop forever)
            Remove-Item $part, $meta -Force -ErrorAction SilentlyContinue
            Write-Log (T 'err.noresume')
            if ($attempt -ge $GT.DownloadRetries) { throw (T 'err.retries' $attempt (T 'err.noresume')) }
            continue
        }
        catch {
            $ex = Get-InnerException $_.Exception
            if ($ex -is [OperationCanceledException]) { throw (T 'err.cancelled') }
            $lastErr = $ex.Message
            $status  = Get-WebStatus $ex
            if ($status -and $status -notin 408, 416, 429, 500, 502, 503, 504) {
                throw (T 'err.retries' $attempt $lastErr)   # 403/404 etc. won't get better by retrying
            }
            Write-Log (T 'log.retry' $lastErr)
        }
        if ($attempt -ge $GT.DownloadRetries) { throw (T 'err.retries' $attempt $lastErr) }
        # wait with a countdown; cancel works here too
        for ($s = $GT.DownloadRetryWait; $s -gt 0; $s--) {
            if (Test-Cancelled) { throw (T 'err.cancelled') }
            Set-Progress -1 (T 'prog.download.wait' $s ($attempt + 1) $GT.DownloadRetries)
            Start-Sleep -Seconds 1
        }
    }
    Remove-Item $meta -Force -ErrorAction SilentlyContinue
    Move-Item $part $Path -Force
    $len = (Get-Item $Path).Length
    Set-Progress 100 (T 'prog.download' ($len / 1MB) ($len / 1MB))
    Write-Log (T 'log.downloaded' $len)
}

# PowerShell wraps exceptions from .NET calls (MethodInvocationException); this returns the real one
function Get-InnerException($Exception) {
    $ex = $Exception
    while ($ex -is [Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
    $ex
}

# HTTP status code behind an exception (WebException with a response), or $null
function Get-WebStatus($Exception) {
    $ex = Get-InnerException $Exception
    while ($ex) {
        if ($ex -is [Net.WebException] -and $ex.Response) { return [int]$ex.Response.StatusCode }
        $ex = $ex.InnerException
    }
    $null
}

# One attempt. Returns $true when the file is complete, $false when the partial file must be discarded.
# Throws on network errors (caller retries) and OperationCanceledException when the user cancels.
function Invoke-DownloadAttempt([string]$Url, [string]$Part, [string]$Meta) {
    $done = [int64]0
    if (Test-Path $Part) { $done = (Get-Item $Part).Length }
    $tag = $null
    if ($done -gt 0 -and (Test-Path $Meta)) { $tag = "$(Get-Content $Meta -Raw -ErrorAction SilentlyContinue)".Trim() }
    if ($done -gt 0 -and -not $tag) { return $false }   # partial file of unknown origin

    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 30000; $req.ReadWriteTimeout = 30000
    $req.UserAgent = "eGPU-Manager/$($GT.Version)"
    $req.AllowAutoRedirect = $true
    if ($done -gt 0) { $req.AddRange([int64]$done) }

    $resp = $null
    try { $resp = $req.GetResponse() }
    catch {
        if ((Get-WebStatus $_.Exception) -eq 416) {
            # range not satisfiable: either we already have everything or the file changed
            $head = [Net.HttpWebRequest]::Create($Url); $head.Method = 'HEAD'; $head.Timeout = 30000
            $hr = $head.GetResponse()
            try { $len = $hr.ContentLength; $htag = Get-ServerTag $hr $len } finally { $hr.Close() }
            if ($len -eq $done -and $htag -eq $tag) { Set-Progress 100 (T 'prog.download' ($done / 1MB) ($done / 1MB)); return $true }
            return $false
        }
        throw
    }

    $in = $null; $out = $null
    try {
        $status = [int]$resp.StatusCode
        if ($done -gt 0) {
            if ($status -ne 206) { return $false }     # server ignored the range
            $cr = "$($resp.Headers['Content-Range'])"
            $total = if ($cr -match '/(\d+)\s*$') { [int64]$Matches[1] } else { $done + $resp.ContentLength }
            if ((Get-ServerTag $resp $total) -ne $tag) { return $false }   # file changed on the server
            Write-Log (T 'log.resume' ($done / 1MB))
        } else {
            $total = $resp.ContentLength
            Set-Content -Path $Meta -Value (Get-ServerTag $resp $total) -Encoding ASCII
        }

        $in  = $resp.GetResponseStream()
        $out = New-Object IO.FileStream($Part, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $buf = New-Object byte[] (1MB)
        $sw  = [Diagnostics.Stopwatch]::StartNew()
        $lastText = 0.0
        $window = New-Object Collections.Generic.Queue[object]   # (seconds, bytes) samples for the speed
        $window.Enqueue(@($sw.Elapsed.TotalSeconds, $done))
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n); $done += $n
            if (Test-Cancelled) { throw (New-Object OperationCanceledException) }
            $now = $sw.Elapsed.TotalSeconds
            if ($now - $lastText -ge 0.5) {
                $lastText = $now
                $window.Enqueue(@($now, $done))
                while ($window.Count -gt 1 -and ($now - $window.Peek()[0]) -gt 5) { [void]$window.Dequeue() }
                $first = $window.Peek()
                $rate  = if ($now - $first[0] -gt 0) { ($done - $first[1]) / ($now - $first[0]) } else { 0 }
                $left  = if ($rate -gt 0) { Format-Duration (($total - $done) / $rate) } else { '?' }
                $pct   = [int](100 * $done / [Math]::Max(1, $total))
                Set-Progress $pct (T 'prog.download.rate' ($done / 1MB) ($total / 1MB) ($rate / 1MB) $left)
            }
        }
    } finally {
        if ($out) { $out.Close() }
        if ($in)  { $in.Close() }
        $resp.Close()
    }
    if ($total -lt 0) { $total = $done }   # no Content-Length from the server: accept what arrived
    if ($done -lt $total) { throw (T 'err.incomplete' $done $total) }   # connection closed early -> retry resumes
    if ($done -gt $total) { return $false }
    $true
}

# ETag (preferred), Last-Modified or at least the total size of a response, used to notice a changed file
# between attempts. Written to the .meta file as one line.
function Get-ServerTag($Response, [int64]$Total) {
    $t = "$($Response.Headers['ETag'])".Trim()
    if (-not $t) { $t = "$($Response.Headers['Last-Modified'])".Trim() }
    if (-not $t) { $t = "len:$Total" }
    ($t -replace '[\r\n]', '')
}

# Verifies an NVIDIA package: signature, archive, both cards included, same driver version, signed catalog
function Test-Package([string]$Exe) {
    $cfg = Get-Config
    if (-not (Test-Path $GT.SevenZip)) { throw (T 'err.7zip' $GT.SevenZip) }

    Set-Progress -1 (T 'prog.sig')
    $sig = Get-AuthenticodeSignature $Exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'CN=NVIDIA Corporation') {
        throw (T 'err.sig' $sig.Status $sig.SignerCertificate.Subject)
    }
    Write-Log (T 'log.sigok')

    Set-Progress -1 (T 'prog.archive')
    & $GT.SevenZip t $Exe | Out-Null
    if ($LASTEXITCODE -ne 0) { throw (T 'err.archive') }
    Write-Log (T 'log.archiveok')

    Set-Progress -1 (T 'prog.infs')
    $tmp = Join-Path $GT.WorkDir ('check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    & $GT.SevenZip e $Exe "-o$tmp" 'Display.Driver\*.inf' 'Display.Driver\NV_DISP.CAT' -y | Out-Null
    try {
        $infs = @(); $vers = @()
        foreach ($d in $cfg.Devices) {
            $pattern = [regex]::Escape($d.HardwareId) + '\s*$'
            $hit = Get-ChildItem $tmp -Filter '*.inf' | Where-Object { (Get-Content $_.FullName) -match $pattern } | Select-Object -First 1
            if (-not $hit) { throw (T 'err.notinpkg' $d.Name) }
            $dv = ((@((Get-Content $hit.FullName) -match '^\s*DriverVer'))[0] -replace '.*,\s*', '').Trim()
            Write-Log (T 'log.devinf' $d.Name $hit.Name $dv)
            $infs += $hit.Name; $vers += $dv
        }
        if (@($vers | Select-Object -Unique).Count -ne 1) { throw (T 'err.vermix' ($vers -join ', ')) }
        $cat = Get-AuthenticodeSignature (Join-Path $tmp 'NV_DISP.CAT')
        if ($cat.Status -ne 'Valid') { throw (T 'err.catalog' $cat.Status) }
        Write-Log (T 'log.catok')
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    [pscustomobject]@{ DriverVersion = $vers[0]; Infs = @($infs | Select-Object -Unique) }
}

function Import-Version([string]$Version, [string]$Url) {
    Assert-NvVersionString $Version
    if (-not $Url) { throw (T 'err.nourl' $Version) }
    Write-Log (T 'log.import' $Version)
    $name = [IO.Path]::GetFileName(([uri]$Url).AbsolutePath)
    if ($name -notmatch '^[\w.\-]+\.exe$') { throw (T 'err.nourl' $Version) }
    # the download folder survives failed and cancelled attempts so the .part can be resumed
    $tmp  = Join-Path $GT.WorkDir "download-$Version"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $downloaded = $false
    try {
        $file = Join-Path $tmp $name
        Save-Download $Url $file
        $downloaded = $true
        $info = Test-Package $file

        $dir = Join-Path $GT.PkgDir $Version
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Move-Item $file (Join-Path $dir $name) -Force

        $cfg = Get-Config
        $pkg = [pscustomobject]@{
            Version       = $Version
            File          = "Packages\$Version\$name"
            Sha256        = (Get-FileHash (Join-Path $dir $name)).Hash
            DriverVersion = $info.DriverVersion
            Infs          = $info.Infs
            Url           = $Url
            Added         = (Get-Date -Format 's')
        }
        $cfg.Packages = @(@($cfg.Packages | Where-Object { $_.Version -ne $Version }) + $pkg)
        Save-Config $cfg
        Write-Log (T 'log.imported' $Version $info.DriverVersion)
    } finally {
        # a complete download is either stored or proven bad -> the folder goes; an incomplete one stays
        if ($downloaded) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-OldPackages -Keep $Version
    $true
}

# Partial download waiting in the work folder for this version (bytes), or 0
function Get-PartialDownload([string]$Version) {
    $dir = Join-Path $GT.WorkDir "download-$Version"
    if (-not (Test-Path $dir)) { return [int64]0 }
    $p = Get-ChildItem $dir -Filter '*.part' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { [int64]$p.Length } else { [int64]0 }
}

# Keeps the installed version and at most KeepVersions packages in total
function Remove-OldPackages([string]$Keep) {
    $cfg     = Get-Config
    $keepSet = @(@($cfg.Current, $Keep) | Where-Object { $_ } | Select-Object -Unique)
    $others  = @(@($cfg.Packages) | Where-Object { $_.Version -notin $keepSet } | Sort-Object { [datetime]$_.Added } -Descending)
    $slots   = [Math]::Max(0, [int]$cfg.KeepVersions - $keepSet.Count)
    $remove  = @($others | Select-Object -Skip $slots)
    if (-not $remove) { return }
    foreach ($p in $remove) {
        Remove-Item (Split-Path (Join-Path $GT.Root $p.File)) -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log (T 'log.removedpkg' $p.Version)
    }
    $cfg.Packages = @(@($cfg.Packages) | Where-Object { $_.Version -notin @($remove | ForEach-Object Version) })
    Save-Config $cfg
}

# =============================================================================================
#  Switch
# =============================================================================================

function Install-Version([string]$Version) {
    if (-not (Test-Admin)) { throw (T 'err.admin') }
    Assert-NvVersionString $Version
    $cfg = Get-Config
    $pkg = @($cfg.Packages) | Where-Object Version -eq $Version | Select-Object -First 1
    if (-not $pkg) { throw (T 'err.notlocal' $Version) }
    $exe = Join-Path $GT.Root $pkg.File
    Write-Log (T 'log.switch' $Version $pkg.DriverVersion)

    # package unchanged and genuine?
    Set-Progress -1 (T 'prog.pkg')
    if (-not (Test-Path $exe)) { throw (T 'err.pkgmissing' $exe) }
    if ((Get-FileHash $exe).Hash -ne $pkg.Sha256) { throw (T 'err.hash') }
    $sig = Get-AuthenticodeSignature $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'CN=NVIDIA Corporation') { throw (T 'err.sigshort') }
    Write-Log (T 'log.pkgok')

    # extract the driver part
    Set-Progress -1 (T 'prog.extract')
    $x = Join-Path $GT.WorkDir "install-$Version"
    Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
    & $GT.SevenZip x $exe "-o$x" 'Display.Driver\*' -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw (T 'err.extract') }
    $dd = Join-Path $x 'Display.Driver'

    $reboot = $false
    try {
        foreach ($inf in @($pkg.Infs)) { if (-not (Test-Path (Join-Path $dd $inf))) { throw (T 'err.infmissing' $inf) } }

        # 1. remove all other NVIDIA display drivers
        foreach ($s in @(Get-StorePackages | Where-Object { $_.DriverVersion -ne $pkg.DriverVersion })) {
            Set-Progress -1 (T 'prog.remove' $s.NvVersion)
            $out = & pnputil.exe /delete-driver $s.Driver /uninstall /force 2>&1
            Write-Log (T 'log.removed' $s.Driver $s.Original $s.NvVersion $LASTEXITCODE)
            if ($LASTEXITCODE -eq 3010) { $reboot = $true } elseif ($LASTEXITCODE -ne 0) { Write-Log "    $($out -join ' ')" }
        }
        # 2. install the shared version
        foreach ($inf in @($pkg.Infs)) {
            Set-Progress -1 (T 'prog.install' $inf)
            $out = & pnputil.exe /add-driver (Join-Path $dd $inf) /install 2>&1
            Write-Log (T 'log.installed' $inf $LASTEXITCODE)
            if ($LASTEXITCODE -eq 3010) { $reboot = $true }
            elseif ($LASTEXITCODE -notin 0, 259) { Write-Log "    $($out -join ' ')" }   # 259 = no device updated
        }
    } finally { Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue }

    $cfg = Get-Config
    $cfg.Current = $Version
    Save-Config $cfg
    Remove-OldPackages
    [void](Sync-WuDriverLock)   # in Auto mode the lock becomes active with the first switch

    Start-Sleep -Seconds 5
    $s = Get-Summary
    foreach ($g in $s.Gpus) {
        Write-Log ('  {0}: {1}' -f $g.Name, $(if ($g.Present) { T 'gpu.code' $g.NvVersion $g.Problem } else { T 'gpu.absent' }))
    }
    $ok  = $s.Ok -and -not $reboot
    $msg = if ($ok) { T 'msg.switchok' $Version } else { T 'msg.switchreboot' $Version }
    Write-Log $msg
    [pscustomobject]@{ Ok = $ok; RebootRequired = (-not $ok); Message = $msg }
}

# =============================================================================================
#  Scheduled switch (one-time task that deletes itself after running)
# =============================================================================================

# Is write access limited to administrators and SYSTEM? (The task runs as SYSTEM.)
function Test-FolderSecure {
    $risky = 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4'   # Everyone, Authenticated Users, Users, Interactive
    $write = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    foreach ($a in (Get-Acl $GT.Root).Access) {
        if ($a.AccessControlType -ne 'Allow') { continue }
        try { $sid = $a.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
        $rights  = [int64]$a.FileSystemRights
        $generic = $rights -band 0x50000000   # GENERIC_WRITE / GENERIC_ALL
        if ($sid -in $risky -and (($rights -band [int64]$write) -or $generic)) { return $false }
    }
    $true
}

function Protect-Folder([string]$Path = $GT.Root) {
    $out = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
    Write-Log (T 'log.secured' $Path $LASTEXITCODE)
    if ($LASTEXITCODE -ne 0) { throw ($out -join ' ') }
}

function Register-Switch([string]$Version, $At) {
    Assert-NvVersionString $Version   # the version becomes part of a SYSTEM command line
    if (-not (Test-FolderSecure)) { throw (T 'err.notsecure' $GT.Root) }
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($GT.Self)`" -Apply $Version -FromTask"
    $act = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arg
    if ($At) { $trg = New-ScheduledTaskTrigger -Once -At $At }
    else     { $trg = New-ScheduledTaskTrigger -AtStartup; $trg.Delay = 'PT1M' }
    # WakeToRun: a timed switch also runs when the laptop is asleep at that moment
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -WakeToRun -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $when = if ($At) { ([datetime]$At).ToString((T 'fmt.datetime')) } else { T 'when.reboot' }
    Register-ScheduledTask -TaskName $GT.TaskName -Action $act -Trigger $trg -Settings $set -Principal $prn -Force `
        -Description (T 'task.desc' $Version $when) | Out-Null
    Write-Log (T 'log.scheduled' $Version $when)
}

function Get-PendingSwitch {
    $t = Get-ScheduledTask -TaskName $GT.TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $ver  = if ($t.Actions[0].Arguments -match '-Apply\s+(\S+)') { $Matches[1] } else { '?' }
    $trg  = $t.Triggers[0]
    $when = if ($trg.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger') { T 'when.reboot' }
            else { ([datetime]$trg.StartBoundary).ToString((T 'fmt.datetime')) }
    [pscustomobject]@{ Version = $ver; When = $when }
}

function Unregister-Switch {
    Unregister-ScheduledTask -TaskName $GT.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log (T 'log.unscheduled')
}

function Get-LastResult {
    if (Test-Path $GT.ResultFile) { Get-Content $GT.ResultFile -Raw -Encoding UTF8 | ConvertFrom-Json }
}

function Set-LastResultShown {
    $r = Get-LastResult
    if ($r) { $r.Shown = $true; $r | ConvertTo-Json | Set-Content $GT.ResultFile -Encoding UTF8 }
}

# Waits (as SYSTEM) until someone is signed in, then shows a message
function Send-UserMessage([string]$Text, [int]$WaitMinutes) {
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    while (-not (Get-Process explorer -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 15 }
    if (Get-Process explorer -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 20
        & msg.exe * /TIME:0 "$($GT.AppName)`n`n$Text" 2>$null
    }
}

# =============================================================================================
#  Install and update
# =============================================================================================

function Test-Installed {
    $a = [IO.Path]::GetFullPath($GT.Root).TrimEnd('\')
    $b = [IO.Path]::GetFullPath($GT.InstallDir).TrimEnd('\')
    $a -eq $b
}

# A git checkout is updated with git, not with the built-in updater
function Test-DevCopy { Test-Path (Join-Path $GT.Root '.git') }

function New-DesktopShortcut([string]$Script) {
    $desk = [Environment]::GetFolderPath('Desktop')
    Remove-Item (Join-Path $desk 'GPU-Verwaltung.lnk') -ErrorAction SilentlyContinue   # name used by 1.0
    $lnk = Join-Path $desk 'eGPU Manager.lnk'
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""
    $s.WorkingDirectory = Split-Path $Script
    $s.IconLocation     = "$env:SystemRoot\System32\dxdiag.exe,0"
    $s.WindowStyle      = 7
    $s.Description      = T 'lnk.desc'
    $s.Save()
    Write-Log (T 'log.shortcut' $lnk)
}

# Version string inside a script file ("Version = '1.1.0'"), or $null
function Get-ScriptFileVersion([string]$Path) {
    try {
        $m = [regex]::Match((Get-Content $Path -Raw -Encoding UTF8), "Version\s*=\s*'(\d+\.\d+\.\d+)'")
        if ($m.Success) { $m.Groups[1].Value }
    } catch { $null }
}

# Keeps the script that is about to be replaced: Archive\<version>\GpuTool.ps1 next to it, plus a
# snapshot of config.json from that moment. Nothing is ever overwritten in the archive.
# Returns the archive folder.
function Backup-Script([string]$ScriptPath) {
    $root = Split-Path $ScriptPath
    $ver  = Get-ScriptFileVersion $ScriptPath
    if (-not $ver) { $ver = 'unknown' }
    $dir  = Join-Path (Join-Path $root 'Archive') $ver
    if (Test-Path (Join-Path $dir 'GpuTool.ps1')) {
        # same version archived before -> keep both, with a timestamp
        $dir = Join-Path (Join-Path $root 'Archive') ('{0}_{1}' -f $ver, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item $ScriptPath (Join-Path $dir 'GpuTool.ps1') -Force
    $cfg = Join-Path $root 'config.json'
    if (Test-Path $cfg) { Copy-Item $cfg (Join-Path $dir 'config.json') -Force }
    # a .bak left behind by 1.1 is moved into the archive as well
    $bak = "$ScriptPath.bak"
    if (Test-Path $bak) {
        $bv = Get-ScriptFileVersion $bak
        if (-not $bv) { $bv = 'unknown' }
        $bd = Join-Path (Join-Path $root 'Archive') $bv
        if (-not (Test-Path (Join-Path $bd 'GpuTool.ps1'))) {
            New-Item -ItemType Directory -Force -Path $bd | Out-Null
            Move-Item $bak (Join-Path $bd 'GpuTool.ps1') -Force
        } else { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
    }
    Write-Log (T 'log.archived' $ver $dir)
    $dir
}

# Copies the tool to C:\Scripts\GpuTool, secures the folder and creates the shortcut.
# An existing installation keeps its settings and packages; only the script is replaced
# (the replaced script goes to Archive\<version>\). Returns the path of the installed script.
function Install-Tool {
    $dst    = $GT.InstallDir
    $target = Join-Path $dst 'GpuTool.ps1'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    if (-not (Test-Installed)) {
        Write-Log (T 'log.install' $dst)
        if ((Test-Path $target) -and (Get-FileHash $target).Hash -ne (Get-FileHash $GT.Self).Hash) { Backup-Script $target | Out-Null }
        Copy-Item $GT.Self $target -Force
        if (Test-Path (Join-Path $dst 'config.json')) {
            Write-Log (T 'log.existing')
        } else {
            if (Test-Path $GT.ConfigFile) { Copy-Item $GT.ConfigFile $dst -Force }
            if (Test-Path $GT.PkgDir) {
                Set-Progress -1 (T 'prog.copypkg')
                Copy-Item $GT.PkgDir $dst -Recurse -Force
                Write-Log (T 'log.copiedpkg')
            }
        }
    }
    Protect-Folder $dst
    New-DesktopShortcut $target
    $target
}

# Newest release = highest version tag (vX.Y.Z) in the GitHub repository
function Get-LatestRelease {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tags = Invoke-RestMethod -UseBasicParsing -TimeoutSec 15 -Headers @{ 'User-Agent' = 'eGPU-Manager' } `
        -Uri "https://api.github.com/repos/$($GT.Repo)/tags?per_page=100"
    $best = $null
    foreach ($t in @($tags)) {
        if ($t.name -match '^v?(\d+\.\d+\.\d+)$') {
            $v = [version]$Matches[1]
            if (-not $best -or $v -gt $best.Version) { $best = [pscustomobject]@{ Version = $v; Tag = $t.name } }
        }
    }
    $best
}

# Replaces this script with the version from the given tag. Returns the script path for the restart.
function Update-Script([string]$Tag, [string]$Version) {
    if (Test-DevCopy) { throw (T 'err.devcopy') }
    Write-Log (T 'log.update' $GT.Version $Version)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path $GT.WorkDir | Out-Null
    $tmp = Join-Path $GT.WorkDir "GpuTool-$Version.ps1"
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "https://raw.githubusercontent.com/$($GT.Repo)/$Tag/GpuTool.ps1" -OutFile $tmp

    $err = $null
    [void][Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$err)
    if ($err) { throw (T 'err.update.parse') }
    $bytes = [IO.File]::ReadAllBytes($tmp)
    $text  = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch ("Version\s*=\s*'" + [regex]::Escape($Version) + "'")) { throw (T 'err.update.version') }
    # Windows PowerShell 5.1 needs a BOM to read umlauts correctly
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        $bytes = [byte[]](0xEF, 0xBB, 0xBF) + $bytes
    }
    $backup = Backup-Script $GT.Self
    [IO.File]::WriteAllBytes($GT.Self, $bytes)
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Write-Log (T 'log.updated' $Version $backup)
    $GT.Self
}

# =============================================================================================
#  Console
# =============================================================================================

function Show-Status {
    $s = Get-Summary
    foreach ($g in $s.Gpus) {
        Write-Host ('{0,-22} {1}' -f $g.Name, $(if ($g.Present) { T 'gpu.code' "$($g.NvVersion) ($($g.DriverVersion))" $g.Problem } else { T 'gpu.absent' }))
    }
    foreach ($p in $s.Store) { Write-Host ('{0,-22} {1} {2} {3}' -f (T 'con.store'), $p.Driver, $p.Original, $p.NvVersion) }
    if ($s.Ok) { Write-Host (T 'con.ok' $s.Common) -ForegroundColor Green }
    else       { Write-Host (T 'con.mismatch' ($s.Versions -join ', ')) -ForegroundColor Yellow }
    $p = Get-PendingSwitch
    if ($p) { Write-Host (T 'con.pending' $p.Version $p.When) }
    $wu = Get-WuDriverLock
    $wuText = if ($wu.Gpo) { T 'ban.wu.gpo' } elseif ($wu.Locked) { T 'con.wu.on' $wu.Mode } else { T 'con.wu.off' $wu.Mode }
    Write-Host ('{0,-22} {1}' -f (T 'con.wu'), $wuText)
}

function Invoke-Apply {
    if (-not (Test-Admin)) { Write-Log (T 'err.applyadmin'); exit 1 }
    if (-not (Test-NvVersionString $Apply)) { Write-Log (T 'err.badversion' $Apply); exit 1 }
    Move-LegacyPackages
    try { $r = Install-Version $Apply }
    catch {
        Write-Log (T 'log.error' $_.Exception.Message)
        $r = [pscustomobject]@{ Ok = $false; RebootRequired = $false; Message = (T 'msg.applyfail' $Apply $_.Exception.Message) }
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
#  GUI
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
        Progress = -1; ProgressText = ''; Busy = $false; Done = $false; Result = $null; Error = $null; Cancel = $false
    })
    $Global:GtSync = $sync
    $ui  = @{ State = $null; Job = $null; OnDone = $null; Buttons = @(); FirstLoad = $true; Snapshot = $Snapshot }
    $ui.ThemeMode = if ($Theme) { $Theme } else { Get-Setting 'Theme' 'Auto' }   # Auto / Light / Dark
    $cfg = Get-Config

    # ---------- colors (light / dark) ----------
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
                Header = (rgb 48 48 48); HeaderLine = (rgb 70 70 70); RowMuted = (rgb 135 135 135); Link = (rgb 133 183 235)
                Green = (rgb 192 221 151); GreenBg = (rgb 39 80 10)
                Red   = (rgb 247 193 193); RedBg   = (rgb 121 31 31)
                Amber = (rgb 250 199 117); AmberBg = (rgb 99 56 6)
                Gray  = (rgb 211 209 199); GrayBg  = (rgb 68 68 65)
            }
        } else {
            $p = @{
                Back = [Drawing.SystemColors]::Control; Surface = [Drawing.Color]::White; Fore = [Drawing.SystemColors]::ControlText; Muted = (rgb 95 94 90)
                Button = [Drawing.SystemColors]::Control; ButtonBorder = (rgb 173 173 173); ButtonHover = (rgb 229 241 251)
                Header = [Drawing.Color]::White; HeaderLine = (rgb 229 229 229); RowMuted = [Drawing.Color]::Gray; Link = (rgb 24 95 165)
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

    function New-Button([string]$Text) {
        $b = New-Object Windows.Forms.Button
        $b.Text = $Text; $b.AutoSize = $true; $b.Padding = New-Object Windows.Forms.Padding(6, 2, 6, 2)
        $b.Margin = New-Object Windows.Forms.Padding(0, 3, 8, 3)
        $ui.Buttons += $b
        $b
    }
    function New-Flow {
        $f = New-Object Windows.Forms.FlowLayoutPanel
        $f.AutoSize = $true; $f.Dock = 'Fill'; $f.WrapContents = $true; $f.Margin = New-Object Windows.Forms.Padding(0)
        $f
    }
    function New-Label([string]$Text, [int]$Top = 8) {
        $l = New-Object Windows.Forms.Label
        $l.Text = $Text; $l.AutoSize = $true; $l.Margin = New-Object Windows.Forms.Padding(0, $Top, 8, 3)
        $l
    }
    # Drop-down list drawn by ourselves - Windows ignores BackColor for DropDownList, so it would stay white in dark mode
    function New-Combo([string[]]$Items, [int]$Selected, [int]$Width) {
        $cb = New-Object Windows.Forms.ComboBox
        $cb.DropDownStyle = 'DropDownList'; $cb.Width = $Width; $cb.Margin = New-Object Windows.Forms.Padding(0, 4, 16, 3)
        $cb.DrawMode = 'OwnerDrawFixed'
        $cb.Add_DrawItem({
            param($s, $e)
            if ($e.Index -lt 0) { return }
            $sel = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
            $bg  = if ($sel) { [Drawing.SystemColors]::Highlight } else { $s.BackColor }
            $fg  = if ($sel) { [Drawing.SystemColors]::HighlightText } else { $s.ForeColor }
            $br  = New-Object Drawing.SolidBrush($bg); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
            $r   = New-Object Drawing.Rectangle(($e.Bounds.X + 3), $e.Bounds.Y, ($e.Bounds.Width - 3), $e.Bounds.Height)
            [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $s.Font, $r, $fg,
                [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, SingleLine')
        })
        [void]$cb.Items.AddRange($Items); $cb.SelectedIndex = $Selected
        $cb
    }
    function Ask([string]$Text) {
        [Windows.Forms.MessageBox]::Show($form, $Text, $GT.AppName, 'YesNo', 'Question') -eq 'Yes'
    }
    function Show-Msg([string]$Text, [string]$Icon = 'Information') {
        [void][Windows.Forms.MessageBox]::Show($form, $Text, $GT.AppName, 'OK', $Icon)
    }

    # ---------- window ----------
    $form = New-Object Windows.Forms.Form
    $form.SuspendLayout()
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $form.Font = New-Object Drawing.Font('Segoe UI', 9)
    $form.Text = "$($GT.AppName) $($GT.Version)"
    $form.ClientSize = New-Object Drawing.Size(900, 800)
    $form.MinimumSize = New-Object Drawing.Size(820, 720)
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

    # ---------- cards ----------
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

    # ---------- banner ----------
    $banner = New-Object Windows.Forms.Label
    $banner.AutoSize = $false; $banner.Dock = 'Fill'; $banner.Height = 46; $banner.Padding = New-Object Windows.Forms.Padding(8, 4, 8, 4)
    $banner.TextAlign = 'MiddleLeft'; $banner.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 8)
    $banner.BackColor = $C.GrayBg; $banner.ForeColor = $C.Gray; $banner.Text = T 'ui.loading'; $banner.Tag = 'keep'
    $root.Controls.Add($banner, 0, 1)

    # ---------- version list ----------
    $gbList = New-Object Windows.Forms.GroupBox
    $gbList.Text = T 'ui.versions'; $gbList.Dock = 'Fill'; $gbList.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 6)
    $tlList = New-Object Windows.Forms.TableLayoutPanel
    $tlList.Dock = 'Fill'; $tlList.ColumnCount = 1; $tlList.RowCount = 2
    [void]$tlList.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$tlList.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $lv = New-Object Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false
    [void]$lv.Columns.Add((T 'col.version'), 80)
    foreach ($d in $cfg.Devices) { [void]$lv.Columns.Add((T 'col.for' $d.Short), 110) }
    [void]$lv.Columns.Add((T 'col.shared'), 95)
    [void]$lv.Columns.Add((T 'col.local'), 60)
    [void]$lv.Columns.Add((T 'col.status'), 300)
    # draw column headers ourselves in dark mode (Windows always draws them light)
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
    # last column fills the width; always leave room for the vertical scrollbar, or the width oscillates
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
    $chkAll.Text = T 'ui.showall'; $chkAll.AutoSize = $true; $chkAll.Margin = New-Object Windows.Forms.Padding(0, 7, 16, 3)
    $btnRefresh  = New-Button (T 'ui.refresh')
    $btnDownload = New-Button (T 'ui.download')
    $flList.Controls.AddRange(@($chkAll, $btnRefresh, $btnDownload))
    $tlList.Controls.Add($flList, 0, 1)
    $gbList.Controls.Add($tlList)
    $root.Controls.Add($gbList, 0, 2)

    # ---------- switch ----------
    $gbSwitch = New-Object Windows.Forms.GroupBox
    $gbSwitch.Text = T 'ui.switchgroup'; $gbSwitch.Dock = 'Fill'; $gbSwitch.AutoSize = $true
    $gbSwitch.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 6)
    $tlSwitch = New-Object Windows.Forms.TableLayoutPanel
    $tlSwitch.Dock = 'Fill'; $tlSwitch.AutoSize = $true; $tlSwitch.ColumnCount = 1
    $flWhen = New-Flow
    $rbNow    = New-Object Windows.Forms.RadioButton; $rbNow.Text = T 'ui.now'; $rbNow.Checked = $true
    $rbReboot = New-Object Windows.Forms.RadioButton; $rbReboot.Text = T 'ui.atreboot'
    $rbAt     = New-Object Windows.Forms.RadioButton; $rbAt.Text = T 'ui.at'
    foreach ($rb in $rbNow, $rbReboot, $rbAt) { $rb.AutoSize = $true; $rb.Margin = New-Object Windows.Forms.Padding(0, 7, 12, 3) }
    $txtAt = New-Object Windows.Forms.TextBox
    $txtAt.Width = 130; $txtAt.Margin = New-Object Windows.Forms.Padding(0, 5, 16, 3)
    $d0 = (Get-Date).Date.AddHours(22); if ($d0 -lt (Get-Date)) { $d0 = $d0.AddDays(1) }
    $txtAt.Text = $d0.ToString((T 'fmt.datetime'))
    $txtAt.Add_Enter({ $rbAt.Checked = $true })
    $btnSwitch = New-Button (T 'ui.switch')
    $btnSwitch.Font = $fontBold
    $flWhen.Controls.AddRange(@($rbNow, $rbReboot, $rbAt, $txtAt, $btnSwitch))
    $flPending = New-Flow
    $lblPending = New-Label (T 'ui.nopending')
    $lblPending.Margin = New-Object Windows.Forms.Padding(0, 8, 12, 3); $lblPending.ForeColor = $C.Gray; $lblPending.Tag = 'keep'
    $btnCancel = New-Button (T 'ui.cancelpending')
    $flPending.Controls.AddRange(@($lblPending, $btnCancel))
    $tlSwitch.Controls.Add($flWhen, 0, 0)
    $tlSwitch.Controls.Add($flPending, 0, 1)
    $gbSwitch.Controls.Add($tlSwitch)
    $root.Controls.Add($gbSwitch, 0, 3)

    # ---------- tools ----------
    $flTools = New-Flow
    $btnRepair = New-Button (T 'ui.repair')
    $btnSecure = New-Button (T 'ui.secure')
    $btnLog    = New-Button (T 'ui.openlog')
    $flTools.Controls.AddRange(@($btnRepair, $btnSecure, $btnLog))
    $root.Controls.Add($flTools, 0, 4)

    # ---------- progress ----------
    $flProg = New-Flow
    $flProg.WrapContents = $false
    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Size = New-Object Drawing.Size(260, 16); $progress.MarqueeAnimationSpeed = 30
    $progress.Margin = New-Object Windows.Forms.Padding(0, 6, 8, 6)
    $btnCancelWork = New-Object Windows.Forms.Button   # not in $ui.Buttons: it stays enabled while work runs
    $btnCancelWork.Text = T 'ui.cancel'; $btnCancelWork.AutoSize = $true; $btnCancelWork.Visible = $false
    $btnCancelWork.Padding = New-Object Windows.Forms.Padding(6, 0, 6, 0); $btnCancelWork.Margin = New-Object Windows.Forms.Padding(0, 2, 8, 2)
    $lblProgress = New-Label '' 6
    $flProg.Controls.AddRange(@($progress, $btnCancelWork, $lblProgress))
    $root.Controls.Add($flProg, 0, 5)

    # ---------- log ----------
    $txtLog = New-Object Windows.Forms.TextBox
    $txtLog.Dock = 'Fill'; $txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
    $txtLog.Font = New-Object Drawing.Font('Consolas', 9)
    $txtLog.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
    $root.Controls.Add($txtLog, 0, 6)

    # ---------- settings bar (bottom) ----------
    # two rows: settings (left) above, version / GitHub / install buttons (right-aligned) below
    $tlSettings = New-Object Windows.Forms.TableLayoutPanel
    $tlSettings.Dock = 'Fill'; $tlSettings.AutoSize = $true; $tlSettings.ColumnCount = 1; $tlSettings.RowCount = 2
    $tlSettings.Margin = New-Object Windows.Forms.Padding(0, 8, 8, 0)
    [void]$tlSettings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$tlSettings.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$tlSettings.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))

    $themeModes = @('Auto', 'Light', 'Dark')
    $langModes  = @('Auto', 'en', 'de')
    $langSet    = Get-Setting 'Language' 'Auto'
    $flLeft = New-Flow
    $flLeft.WrapContents = $false
    $cbTheme = New-Combo @((T 'opt.auto'), (T 'opt.light'), (T 'opt.dark')) ([Math]::Max(0, [array]::IndexOf($themeModes, $ui.ThemeMode))) 110
    $cbLang  = New-Combo @((T 'opt.auto'), 'English', 'Deutsch') ([Math]::Max(0, [array]::IndexOf($langModes, $langSet))) 110
    $wuModes = @('Auto', 'Block', 'Allow')
    $wuSet   = Get-Setting 'WuDrivers' 'Auto'
    $cbWu    = New-Combo @((T 'opt.wu.auto'), (T 'opt.wu.block'), (T 'opt.wu.allow')) ([Math]::Max(0, [array]::IndexOf($wuModes, $wuSet))) 110
    $lblWu   = New-Label (T 'ui.wu')
    $tip = New-Object Windows.Forms.ToolTip
    $tip.AutoPopDelay = 20000
    $tip.SetToolTip($cbWu, (T 'tip.wu')); $tip.SetToolTip($lblWu, (T 'tip.wu'))
    $flLeft.Controls.AddRange(@((New-Label (T 'ui.theme')), $cbTheme, (New-Label (T 'ui.lang')), $cbLang, $lblWu, $cbWu))

    $flRight = New-Flow
    $flRight.WrapContents = $false; $flRight.Dock = 'None'; $flRight.Anchor = 'Right'
    $lblVersion = New-Label ("v$($GT.Version)" + $(if (Test-DevCopy) { " ($(T 'ui.dev'))" } else { '' }))
    $lnkRepo = New-Object Windows.Forms.LinkLabel
    $lnkRepo.Text = 'GitHub'; $lnkRepo.AutoSize = $true; $lnkRepo.Margin = New-Object Windows.Forms.Padding(0, 8, 12, 3)
    $btnUpdate  = New-Button ''
    $btnUpdate.Visible = $false; $btnUpdate.Font = $fontBold
    $btnInstall = New-Button $(if (Test-Installed) { T 'ui.reinstall' } else { T 'ui.install' })
    $btnToolDir = New-Button (T 'ui.tooldir')
    $btnToolDir.Margin = New-Object Windows.Forms.Padding(0, 3, 0, 3)
    $flRight.Controls.AddRange(@($lblVersion, $lnkRepo, $btnUpdate, $btnInstall, $btnToolDir))

    $tlSettings.Controls.Add($flLeft, 0, 0)
    $tlSettings.Controls.Add($flRight, 0, 1)
    $root.Controls.Add($tlSettings, 0, 7)

    $form.ResumeLayout($false)
    $form.PerformLayout()

    # ---------- background work ----------
    function Set-Busy([bool]$Busy, [bool]$Cancellable = $false) {
        foreach ($b in $ui.Buttons) { $b.Enabled = -not $Busy }
        $chkAll.Enabled = -not $Busy; $cbLang.Enabled = -not $Busy; $cbWu.Enabled = -not $Busy
        $btnCancelWork.Visible = ($Busy -and $Cancellable); $btnCancelWork.Enabled = $true; $btnCancelWork.Text = T 'ui.cancel'
        if ($Busy) { $progress.Style = 'Marquee' }
        else { $progress.Style = 'Continuous'; $progress.Value = 0; $lblProgress.Text = '' }
    }

    # $Cancellable: the work checks Test-Cancelled (downloads do); the Cancel button appears next to the progress bar
    function Start-Work([string]$Title, [scriptblock]$Work, [object[]]$Arguments, [scriptblock]$OnDone, [bool]$Cancellable = $false) {
        if ($sync.Busy) { return }
        $sync.Busy = $true; $sync.Done = $false; $sync.Result = $null; $sync.Error = $null; $sync.Cancel = $false
        $sync.Progress = -1; $sync.ProgressText = $Title
        Set-Busy $true $Cancellable
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.Open()
        $rs.SessionStateProxy.SetVariable('GtSync', $sync)
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($Self, $WorkText, $WorkArgs, $Language)
            . $Self -LoadCore -Lang $Language
            try { $GtSync.Result = & ([scriptblock]::Create($WorkText)) @WorkArgs }
            catch { $GtSync.Error = $_.Exception.Message; Write-Log (T 'log.error' $_.Exception.Message) }
            finally { $GtSync.Done = $true }
        }).AddArgument($GT.Self).AddArgument($Work.ToString()).AddArgument(@($Arguments)).AddArgument($GT.Lang)
        $ui.Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
        $ui.OnDone = $OnDone
    }

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 200
    $ui.Ticks = 0
    $timer.Add_Tick({
        # check the Windows color mode every 2 seconds
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

    # ---------- display ----------
    function Format-Date($d) { if ($d) { ([datetime]$d).ToString((T 'fmt.date')) } else { '–' } }

    function Update-View {
        $st = $ui.State
        if (-not $st) { return }
        $sum = $st.Summary
        $cfgNow = Get-Config

        foreach ($g in $sum.Gpus) {
            $card = $ui.Cards[$g.Short]
            if (-not $g.Present)       { $t = T 'gpu.absent';             $fg = $C.Gray;  $bg = $C.GrayBg }
            elseif ($g.Problem -eq 0)  { $t = T 'st.ok';                  $fg = $C.Green; $bg = $C.GreenBg }
            elseif ($g.Problem -eq 22) { $t = T 'st.disabled';            $fg = $C.Amber; $bg = $C.AmberBg }
            else                       { $t = T 'st.error' $g.Problem;    $fg = $C.Red;   $bg = $C.RedBg }
            $card.Status.Text = $t; $card.Status.ForeColor = $fg; $card.Status.BackColor = $bg
            $card.Version.Text = if ($g.Present) { T 'card.driver' $g.NvVersion $g.DriverVersion } else { '' }
        }

        $storeText = T 'ban.store' ((@($sum.Store) | ForEach-Object { "$($_.Original) $($_.NvVersion)" }) -join ', ')
        if ($st.Wu) {
            $wuText = if ($st.Wu.Gpo) { T 'ban.wu.gpo' } elseif ($st.Wu.Locked) { T 'ban.wu.on' } else { T 'ban.wu.off' }
            $storeText += '   |   ' + $wuText
        }
        if ($sum.Ok -and $sum.Common) {
            $banner.Text = (T 'ban.ok' $sum.Common) + "`r`n" + $storeText
            $banner.BackColor = $C.GreenBg; $banner.ForeColor = $C.Green
        } else {
            $banner.Text = (T 'ban.mismatch' ($sum.Versions -join ', ') $cfgNow.Current) + "`r`n" + $storeText
            $banner.BackColor = $C.AmberBg; $banner.ForeColor = $C.Amber
        }
        if ($st.Table.Error) { $banner.Text += "`r`n" + (T 'ban.offline' $st.Table.Error) }

        if ($st.Pending) {
            $lblPending.Text = T 'ui.pending' $st.Pending.Version $st.Pending.When
            $lblPending.ForeColor = $C.Amber; $btnCancel.Visible = $true
        } else {
            $lblPending.Text = T 'ui.nopending'; $lblPending.ForeColor = $C.Gray; $btnCancel.Visible = $false
        }
        $btnSecure.Visible = -not $st.Secure
        $btnRepair.Visible = -not $sum.Ok

        $latest = $st.Latest
        if ($latest -and $latest.Version -gt [version]$GT.Version -and -not (Test-DevCopy)) {
            $btnUpdate.Text = T 'ui.update' $latest.Version; $btnUpdate.Visible = $true
        } else { $btnUpdate.Visible = $false }
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
            [void]$it.SubItems.Add($(if ($r.Common) { T 'yes' } else { T 'no' }))
            [void]$it.SubItems.Add($(if ($r.Local) { T 'yes' } else { '' }))
            $text = if ($isInst) { T 'ls.installed' }
                    elseif ($r.Local) { T 'ls.ready' }
                    elseif ($r.Common) { T 'ls.shared' }
                    else {
                        $missing = @($cfg.Devices | Where-Object { -not $r.Dates.ContainsKey($_.Short) } | ForEach-Object Short)
                        T 'ls.notfor' ($missing -join ', ')
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

    # ---------- apply light / dark ----------
    function Set-NativeTheme($Ctl) {
        try { [void][GpuTool.Native]::SetWindowTheme($Ctl.Handle, $(if ($ui.Dark) { 'DarkMode_Explorer' } else { 'Explorer' }), $null) } catch { }
    }
    function Set-ControlTheme($Parent) {
        # Careful: PowerShell variables are case-insensitive - use $ctl, not $c (that would overwrite $C)
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
                elseif ($ctl -is [Windows.Forms.ComboBox]) {
                    $ctl.FlatStyle = $(if ($ui.Dark) { 'Flat' } else { 'Standard' })
                    $ctl.BackColor = $(if ($ui.Dark) { $C.Button } else { [Drawing.SystemColors]::Window })
                    $ctl.ForeColor = $C.Fore
                }
                elseif ($ctl -is [Windows.Forms.ListView] -or $ctl -is [Windows.Forms.TextBox]) {
                    $ctl.BackColor = $C.Surface; $ctl.ForeColor = $C.Fore; Set-NativeTheme $ctl
                }
                elseif ($ctl -is [Windows.Forms.LinkLabel]) {
                    $ctl.BackColor = $C.Back; $ctl.LinkColor = $C.Link; $ctl.ActiveLinkColor = $C.Link; $ctl.VisitedLinkColor = $C.Link
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
        $lblProgress.ForeColor = $C.Muted; $lblVersion.ForeColor = $C.Muted
        try { $v = [int]$Dark; [void][GpuTool.Native]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch { }
        if ($ui.State) { Update-View } else { $banner.BackColor = $C.GrayBg; $banner.ForeColor = $C.Gray; $lblPending.ForeColor = $C.Gray }
        $form.Refresh()
    }

    function Get-SelectedRow {
        if ($lv.SelectedItems.Count) { return $lv.SelectedItems[0].Tag }
        Show-Msg (T 'msg.select')
        $null
    }

    function Restart-Tool([string]$Path = $GT.Self) {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Path`""
        $form.Close()
    }

    function Invoke-Refresh {
        Start-Work (T 'prog.loading') {
            Invoke-LogRotation
            [void](Sync-WuDriverLock)   # registry follows the setting (Auto: lock once a tool-installed version is active)
            $r = [pscustomobject]@{
                Summary    = Get-Summary
                Table      = Get-VersionTable
                Pending    = Get-PendingSwitch
                Secure     = Test-FolderSecure
                Wu         = Get-WuDriverLock
                LastResult = Get-LastResult
                Latest     = $(try { Get-LatestRelease } catch { $null })
            }
            $common = @($r.Table.Rows | Where-Object Common)
            Write-Log (T 'log.status' $(if ($r.Summary.Ok) { T 'log.common' $r.Summary.Common } else { T 'log.mismatch' ($r.Summary.Versions -join ', ') }) `
                $r.Table.Rows.Count $common.Count $(if ($common) { $common[0].Version } else { '-' }))
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
                    Show-Msg (T 'msg.lastswitch' ([datetime]$lr.Time).ToString((T 'fmt.datetime')) $lr.Message) $(if ($lr.Ok) { 'Information' } else { 'Warning' })
                    Set-LastResultShown
                }
            }
        }
    }

    function Complete-Install($res, $err) {
        if ($err) { Show-Msg (T 'msg.switchfail' $err) 'Error' }
        elseif ($res.RebootRequired) {
            if (Ask (T 'ask.rebootnow' $res.Message)) { Restart-Computer -Force; return }
        }
        else { Show-Msg $res.Message }
        Invoke-Refresh
    }

    # ---------- events ----------
    $chkAll.Add_CheckedChanged({ Update-List })
    $btnRefresh.Add_Click({ Invoke-Refresh })
    $lv.Add_DoubleClick({ $btnSwitch.PerformClick() })

    $btnDownload.Add_Click({
        $r = Get-SelectedRow; if (-not $r) { return }
        if ($r.Local) { Show-Msg (T 'msg.alreadylocal' $r.Version); return }
        if (-not $r.Url) { Show-Msg (T 'msg.nourl' $r.Version) 'Warning'; return }
        $text = T 'ask.download' $r.Version
        if (-not $r.Common) { $text = (T 'ask.download.warn' $r.Version) + $text }
        $partial = Get-PartialDownload $r.Version
        if ($partial -gt 0) { $text += "`n`n" + (T 'ask.download.resume' ($partial / 1MB)) }
        if (-not (Ask $text)) { return }
        Start-Work (T 'prog.downloading' $r.Version) { param($v, $u) Import-Version $v $u } @($r.Version, $r.Url) {
            param($res, $err)
            if ($err -eq (T 'err.cancelled')) { Show-Msg (T 'msg.cancelled') }
            elseif ($err) { Show-Msg (T 'msg.verifyfail' $err) 'Warning' }
            else { Show-Msg (T 'msg.verified') }
            Invoke-Refresh
        } -Cancellable $true
    })

    $btnCancelWork.Add_Click({
        if (-not $sync.Busy) { return }
        $sync.Cancel = $true
        $btnCancelWork.Enabled = $false; $btnCancelWork.Text = T 'ui.cancelling'
    })

    $cbWu.Add_SelectedIndexChanged({
        $new = $wuModes[$cbWu.SelectedIndex]
        try { Set-Setting 'WuDrivers' $new } catch { }
        try { [void](Set-WuDriverLock (Get-WuDriverLockWanted $new)) }
        catch { Show-Msg (T 'msg.failed' $_.Exception.Message) 'Warning' }
        if ($ui.State) { $ui.State.Wu = Get-WuDriverLock; Update-View }
    })

    $btnSwitch.Add_Click({
        $r = Get-SelectedRow; if (-not $r) { return }
        if (-not $r.Local) { Show-Msg (T 'msg.notlocal' $r.Version); return }
        $sum = $ui.State.Summary
        if ($sum.Ok -and $sum.Common -eq $r.Version) { Show-Msg (T 'msg.active' $r.Version); return }

        if ($rbNow.Checked) {
            if (-not (Ask (T 'ask.switchnow' $r.Version))) { return }
            Start-Work (T 'prog.switching' $r.Version) { param($v) Install-Version $v } @($r.Version) { param($res, $err) Complete-Install $res $err }
            return
        }
        $at = $null
        if ($rbAt.Checked) {
            try { $at = [datetime]::ParseExact($txtAt.Text.Trim(), (T 'fmt.datetime'), [Globalization.CultureInfo]::InvariantCulture) }
            catch {
                Show-Msg (T 'msg.badtime' (T 'fmt.human') ((Get-Date).Date.AddHours(22).ToString((T 'fmt.datetime')))) 'Warning'
                [void]$txtAt.Focus(); return
            }
            if ($at -lt (Get-Date).AddMinutes(1)) { Show-Msg (T 'msg.pasttime') 'Warning'; return }
        }
        if (-not (Test-FolderSecure)) {
            if (-not (Ask (T 'ask.secureschedule' $GT.Root))) { return }
            try { Protect-Folder } catch { Show-Msg (T 'msg.securefail' $_.Exception.Message) 'Error'; return }
        }
        try { Register-Switch $r.Version $at } catch { Show-Msg (T 'msg.schedulefail' $_.Exception.Message) 'Error'; return }
        $p = Get-PendingSwitch
        if ($rbReboot.Checked -and (Ask (T 'ask.rebootscheduled' $r.Version))) { Restart-Computer -Force; return }
        if ($rbAt.Checked) { Show-Msg (T 'msg.scheduledat' $r.Version $p.When) }
        Invoke-Refresh
    })

    $btnCancel.Add_Click({ Unregister-Switch; Invoke-Refresh })

    $btnRepair.Add_Click({
        $cur = (Get-Config).Current
        if (-not $cur) { $cur = $ui.State.Summary.Common }
        if (-not (Ask (T 'ask.repair' $cur))) { return }
        Start-Work (T 'prog.repair' $cur) { param($v) Install-Version $v } @($cur) { param($res, $err) Complete-Install $res $err }
    })

    $btnSecure.Add_Click({
        if (-not (Ask (T 'ask.secure' $GT.Root))) { return }
        try { Protect-Folder; Show-Msg (T 'msg.secured') } catch { Show-Msg (T 'msg.failed' $_.Exception.Message) 'Error' }
        Invoke-Refresh
    })
    $btnLog.Add_Click({ Start-Process notepad.exe $GT.LogFile })
    $btnToolDir.Add_Click({ Start-Process explorer.exe $GT.Root })
    $lnkRepo.Add_LinkClicked({ Start-Process $GT.RepoUrl })

    $cbTheme.Add_SelectedIndexChanged({
        $ui.ThemeMode = $themeModes[$cbTheme.SelectedIndex]
        try { Set-Setting 'Theme' $ui.ThemeMode } catch { }
        Set-Theme (Get-SystemDark)
    })
    # a language change rebuilds the window: save the setting and restart
    $cbLang.Add_SelectedIndexChanged({
        $new = $langModes[$cbLang.SelectedIndex]
        try { Set-Setting 'Language' $new } catch { }
        if ((Resolve-Language $new) -ne $GT.Lang -and -not $sync.Busy) { Restart-Tool }
    })

    $btnInstall.Add_Click({
        if (Test-Installed) {
            try {
                New-DesktopShortcut $GT.Self
                if (-not (Test-FolderSecure)) { Protect-Folder }
                Show-Msg (T 'msg.shortcut')
            } catch { Show-Msg (T 'msg.failed' $_.Exception.Message) 'Error' }
            Invoke-Refresh
            return
        }
        $text = T 'ask.install' $GT.InstallDir
        if (Test-Path (Join-Path $GT.InstallDir 'config.json')) { $text += T 'ask.install.existing' }
        if (-not (Ask $text)) { return }
        Start-Work (T 'prog.installing') { Install-Tool } @() {
            param($res, $err)
            if ($err) { Show-Msg (T 'msg.installfail' $err) 'Error'; return }
            Restart-Tool $res   # administrator rights are inherited
        }
    })

    $btnUpdate.Add_Click({
        $latest = $ui.State.Latest
        if (-not (Ask (T 'ask.update' $GT.Version $latest.Version))) { return }
        Start-Work (T 'prog.updating') { param($t, $v) Update-Script $t $v } @($latest.Tag, "$($latest.Version)") {
            param($res, $err)
            if ($err) { Show-Msg (T 'msg.updatefail' $err) 'Error'; return }
            Restart-Tool $res
        }
    })

    $form.Add_Shown({ $timer.Start(); Invoke-Refresh })
    $form.Add_FormClosing({
        param($s, $e)
        if ($sync.Busy -and -not $ui.Snapshot) {
            Show-Msg (T 'msg.busy') 'Warning'
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

$GT.Lang = if ($Lang) { $Lang } else { Resolve-Language (Get-Setting 'Language' 'Auto') }

if ($LoadCore) { return }
if ($Status)   { Show-Status; return }
if ($Apply)    { Invoke-Apply; return }

if (-not (Test-Admin) -and -not $NoElevate) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($GT.Self)`""
    return
}
if (Test-Admin) { Move-LegacyPackages }
Show-Gui
