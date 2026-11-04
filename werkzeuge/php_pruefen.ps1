# php_pruefen.ps1 - neue PHP-Versionen erkennen, pruefen und in manifest.json festlegen.
#
# Laeuft taeglich im GitHub-Lauf ".github/workflows/php-pruefen.yml" (Windows-Runner),
# laesst sich aber auch lokal starten (Windows PowerShell 5.1 oder PowerShell 7).
#
# Ablauf je PHP-Reihe aus manifest.json (nur gleiche Reihe, nie 8.3 -> 8.4):
#   1. Neueste Version aus https://downloads.php.net/~windows/releases/releases.json
#      (NTS x64, dort steht auch die SHA-256 des Anbieters).
#   2. Ist sie neuer: ZIP laden, SHA-256 vergleichen.
#   3. Probeinstallation: php.ini wie install_production.ps1 (gleiche Erweiterungen,
#      OPcache), php -m pruefen, dann Apache + mod_fcgid aus manifest.json starten
#      und eine Testseite ueber php-cgi abrufen.
#   4. Nur wenn alles klappt: Eintrag in manifest.json anpassen.
#
# Ergebnis im -ErgebnisOrdner:
#   zusammenfassung.json  {geaendert, versionen[], fehler[], titel, zweig, sicherheit}
#   bericht.md            lesbarer Bericht (Text fuer Pull Request / Issue)
#
# -NurProbe: keine neuen Versionen suchen, sondern die festgelegten Versionen der
#            Probeinstallation unterziehen (prueft den Lauf selbst, aendert nichts).
#
# Exit-Code 0 auch bei Fehlschlag einer Probe (steht in zusammenfassung.json);
# != 0 nur, wenn das Skript selbst nicht durchlaeuft.

param(
    [string]$ManifestPfad   = (Join-Path $PSScriptRoot "..\manifest.json"),
    [string]$ArbeitsOrdner  = (Join-Path $env:TEMP "interlake-stack-pruefen"),
    [string]$ErgebnisOrdner = (Join-Path $env:TEMP "interlake-stack-ergebnis"),
    [int]$ProbePort         = 18080,
    [switch]$NurProbe,
    [switch]$VcRedistInstallieren
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest ist sonst in 5.1 sehr langsam
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ReleasesUrl    = "https://downloads.php.net/~windows/releases/releases.json"
$PhpNetJsonUrl  = "https://www.php.net/releases/index.php?json&version={0}&max=1"
$PhpDownloadUrl = "https://downloads.php.net/~windows/releases/{0}"
$PhpArchivUrl   = "https://downloads.php.net/~windows/releases/archives/{0}"

# Gleiche Liste wie install_production.ps1 (Phase 3) - bei Aenderung dort hier nachziehen.
$Erweiterungen = @("pdo_mysql", "mysqli", "mbstring", "openssl", "curl", "fileinfo", "gd", "intl", "zip")

function Log([string]$Text) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text) }

# ------------------------------------------------------------------
# JSON im Stil von manifest.json schreiben (4 Leerzeichen, nur ASCII).
# Eigene Ausgabe, weil ConvertTo-Json in 5.1 und 7 verschieden formatiert.
# ------------------------------------------------------------------
function JsonText([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($c in $s.ToCharArray()) {
        $n = [int]$c
        if     ($c -eq '"')  { [void]$sb.Append('\"') }
        elseif ($c -eq '\')  { [void]$sb.Append('\\') }
        elseif ($n -eq 10)   { [void]$sb.Append('\n') }
        elseif ($n -eq 13)   { [void]$sb.Append('\r') }
        elseif ($n -eq 9)    { [void]$sb.Append('\t') }
        elseif ($n -lt 32 -or $n -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $n)) }
        else                 { [void]$sb.Append($c) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function JsonWert($Wert, [int]$Ebene) {
    $ein  = '    ' * ($Ebene + 1)
    $aus  = '    ' * $Ebene
    if ($null -eq $Wert) { return 'null' }
    if ($Wert -is [bool]) { if ($Wert) { return 'true' } else { return 'false' } }
    if ($Wert -is [string]) { return (JsonText $Wert) }
    if ($Wert -is [int] -or $Wert -is [long] -or $Wert -is [double] -or $Wert -is [decimal]) {
        return ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Wert))
    }
    if ($Wert -is [System.Collections.IList]) {
        if ($Wert.Count -eq 0) { return '[]' }
        $teile = @(foreach ($e in $Wert) { $ein + (JsonWert $e ($Ebene + 1)) })
        return "[`n" + ($teile -join ",`n") + "`n$aus]"
    }
    $props = @($Wert.PSObject.Properties)
    if ($props.Count -eq 0) { return '{}' }
    $teile = @(foreach ($p in $props) { $ein + (JsonText $p.Name) + ': ' + (JsonWert $p.Value ($Ebene + 1)) })
    return "{`n" + ($teile -join ",`n") + "`n$aus}"
}

function Schreibe-Utf8OhneBom([string]$Pfad, [string]$Inhalt) {
    [IO.File]::WriteAllText($Pfad, $Inhalt, (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------
# Download mit Pruefsumme
# ------------------------------------------------------------------
function Hole-Datei([string[]]$Urls, [string]$Ziel, [string]$Sha256) {
    if ((Test-Path $Ziel) -and ((Get-FileHash $Ziel -Algorithm SHA256).Hash -eq $Sha256.ToUpper())) { return }
    $letzterFehler = $null
    foreach ($u in $Urls) {
        for ($i = 1; $i -le 3; $i++) {
            try {
                Invoke-WebRequest -Uri $u -OutFile $Ziel -UseBasicParsing -TimeoutSec 300
                $ist = (Get-FileHash $Ziel -Algorithm SHA256).Hash
                if ($ist -ne $Sha256.ToUpper()) {
                    Remove-Item $Ziel -Force
                    throw "Pruefsumme stimmt nicht ($u): erwartet $Sha256, erhalten $ist"
                }
                return
            } catch {
                $letzterFehler = $_.Exception.Message
                if ($letzterFehler -like "Pruefsumme*") { throw $letzterFehler }  # nicht wiederholen
                Start-Sleep -Seconds (5 * $i)
            }
        }
    }
    throw "Download fehlgeschlagen ($($Urls -join ', ')): $letzterFehler"
}

# Natives Programm ausfuehren, Ausgabe + Exit-Code zurueck (STDERR ohne Abbruch).
function Starte-Nativ([string]$Exe, [string[]]$Argumente) {
    $alt = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $ausgabe = & $Exe @Argumente 2>&1 | ForEach-Object { "$_" }
        return @{ code = $LASTEXITCODE; text = ($ausgabe -join "`n") }
    } finally { $ErrorActionPreference = $alt }
}

# ------------------------------------------------------------------
# Probeinstallation PHP (+ Apache/mod_fcgid)
# ------------------------------------------------------------------
function Erstelle-PhpIni([string]$PhpDir) {
    $ini = Get-Content (Join-Path $PhpDir "php.ini-production")
    foreach ($ext in $Erweiterungen) { $ini = $ini -replace "^;extension=$ext$", "extension=$ext" }
    $ini = $ini -replace "^;date.timezone =.*$", "date.timezone = Europe/Zurich"
    $ini = $ini -replace "^;extension_dir = .*$", "extension_dir = `"ext`""
    $ini = $ini -replace "^;zend_extension=opcache$", "zend_extension=opcache"
    $ini = $ini -replace "^;opcache.enable=1$", "opcache.enable=1"
    $ini = $ini -replace "^expose_php = On$", "expose_php = Off"
    Schreibe-Utf8OhneBom (Join-Path $PhpDir "php.ini") (($ini -join "`r`n") + "`r`n")
}

function Pruefe-Php([string]$PhpDir, [string]$Version) {
    $php = Join-Path $PhpDir "php.exe"
    if (-not (Test-Path $php))                          { throw "php.exe fehlt im Archiv (kein NTS-Build?)" }
    if (-not (Test-Path (Join-Path $PhpDir "php-cgi.exe"))) { throw "php-cgi.exe fehlt im Archiv" }
    Erstelle-PhpIni $PhpDir

    # Aus einem fremden Arbeitsordner starten wie spaeter der Dienst (extension_dir ist relativ).
    Push-Location $ArbeitsOrdner
    try {
        $v = Starte-Nativ $php @("-v")
        if ($v.code -ne 0) { throw "php -v Exit-Code $($v.code): $($v.text)" }
        if ($v.text -notmatch [regex]::Escape("PHP $Version")) { throw "php -v meldet nicht $Version`: $($v.text)" }
        if ($v.text -match "Warning|Unable to load") { throw "php -v meldet Ladefehler: $($v.text)" }
        $m = Starte-Nativ $php @("-m")
        $fehlend = @(foreach ($e in ($Erweiterungen + "Zend OPcache")) { if ($m.text -notmatch "(?m)^$([regex]::Escape($e))\s*$") { $e } })
        if ($fehlend.Count -gt 0) { throw "Erweiterungen nicht geladen: $($fehlend -join ', ')" }
    } finally { Pop-Location }
}

$script:ApacheDir = $null
function Bereite-Apache($Manifest) {
    if ($script:ApacheDir) { return $script:ApacheDir }
    $a = $Manifest.komponenten.apache
    $f = $Manifest.komponenten.mod_fcgid
    $zipA = Join-Path $ArbeitsOrdner $a.datei
    $zipF = Join-Path $ArbeitsOrdner $f.datei
    Log "Apache $($a.version) + mod_fcgid $($f.version) laden (festgelegte Versionen)..."
    Hole-Datei @($a.urls) $zipA $a.sha256
    Hole-Datei @($f.urls) $zipF $f.sha256
    $ziel = Join-Path $ArbeitsOrdner "apache"
    if (Test-Path $ziel) { Remove-Item $ziel -Recurse -Force }
    Expand-Archive $zipA $ziel -Force
    $httpd = Get-ChildItem $ziel -Recurse -Filter "httpd.exe" | Select-Object -First 1
    if (-not $httpd) { throw "httpd.exe nicht im Apache-Archiv" }
    $root = Split-Path (Split-Path $httpd.FullName)
    $tmpF = Join-Path $ArbeitsOrdner "fcgid"
    if (Test-Path $tmpF) { Remove-Item $tmpF -Recurse -Force }
    Expand-Archive $zipF $tmpF -Force
    $so = Get-ChildItem $tmpF -Recurse -Filter "mod_fcgid.so" | Select-Object -First 1
    if (-not $so) { throw "mod_fcgid.so nicht im Archiv" }
    Copy-Item $so.FullName (Join-Path $root "modules\mod_fcgid.so") -Force
    $script:ApacheDir = $root
    return $root
}

function Pruefe-PhpUeberApache($Manifest, [string]$PhpDir, [string]$Version) {
    $root = Bereite-Apache $Manifest
    $r = $root -replace '\\', '/'
    $web = Join-Path $ArbeitsOrdner "web"
    New-Item -ItemType Directory -Force $web | Out-Null
    $liste = ($Erweiterungen | ForEach-Object { "'$_'" }) -join ", "
    $probe = @"
<?php
`$fehlt = [];
foreach ([$liste, 'Zend OPcache'] as `$e) { if (!extension_loaded(`$e)) { `$fehlt[] = `$e; } }
`$pdo = in_array('mysql', PDO::getAvailableDrivers(), true);
echo (`$fehlt === [] && `$pdo) ? 'INTERLAKE-PROBE-OK ' . PHP_VERSION : 'INTERLAKE-PROBE-FEHLER ' . implode(',', `$fehlt) . (`$pdo ? '' : ' pdo_mysql-Treiber');
"@
    Schreibe-Utf8OhneBom (Join-Path $web "probe.php") $probe
    $w = $web -replace '\\', '/'
    $cgi = (Join-Path $PhpDir "php-cgi.exe") -replace '\\', '/'
    $conf = Join-Path $ArbeitsOrdner "probe-httpd.conf"
    # Minimal-Konfiguration mit denselben fcgid-Einstellungen wie install_production.ps1 (Phase 12).
    $inhalt = @"
ServerRoot "$r"
Listen 127.0.0.1:$ProbePort
ServerName localhost
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule dir_module modules/mod_dir.so
LoadModule mime_module modules/mod_mime.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule fcgid_module modules/mod_fcgid.so
FcgidIOTimeout 600
FcgidBusyTimeout 600
ErrorLog "$((Join-Path $ArbeitsOrdner 'probe-error.log') -replace '\\','/')"
PidFile "$((Join-Path $ArbeitsOrdner 'probe-httpd.pid') -replace '\\','/')"
DocumentRoot "$w"
<Directory "$w">
    Require all granted
    Options -Indexes +ExecCGI
</Directory>
<FilesMatch \.php$>
    SetHandler fcgid-script
    FcgidWrapper "$cgi" .php
</FilesMatch>
"@
    Schreibe-Utf8OhneBom $conf $inhalt
    $httpd = Join-Path $root "bin\httpd.exe"
    $t = Starte-Nativ $httpd @("-t", "-f", $conf)
    if ($t.code -ne 0) { throw "httpd -t Exit-Code $($t.code): $($t.text)" }

    $proz = Start-Process -FilePath $httpd -ArgumentList @("-f", "`"$conf`"") -PassThru -WindowStyle Hidden
    try {
        $antwort = $null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            try { $antwort = (Invoke-WebRequest "http://127.0.0.1:$ProbePort/probe.php" -UseBasicParsing -TimeoutSec 30).Content; break } catch { }
        }
        if ($null -eq $antwort) {
            $logPfad = Join-Path $ArbeitsOrdner 'probe-error.log'
            $log = if (Test-Path $logPfad) { (@(Get-Content $logPfad -Tail 2) -join ' | ') } else { "" }
            # php-cgi direkt aufrufen - nennt die Ursache meist klarer als Apache
            Push-Location $ArbeitsOrdner
            try { $direkt = Starte-Nativ (Join-Path $PhpDir "php-cgi.exe") @("-f", (Join-Path $web "probe.php")) } finally { Pop-Location }
            throw "Testseite ueber Apache nicht erreichbar. php-cgi direkt (Exit $($direkt.code)): $($direkt.text.Trim()) -- Apache error.log: $log"
        }
        if ($antwort -ne "INTERLAKE-PROBE-OK $Version") { throw "Testseite ueber Apache meldet: $antwort" }
    } finally {
        # httpd startet einen Kindprozess, beide beenden
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proz.Id)" -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $proz.Id -Force -ErrorAction SilentlyContinue
        Get-Process php-cgi -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$PhpDir*" } | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

function Installiere-VcRedist($Manifest) {
    $min = [version]$Manifest.vc_redist.mindestversion
    $key = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
    $ist = $null
    if (Test-Path $key) { $ist = [version]((Get-ItemProperty $key).Version -replace '^v', '') }
    if ($ist -and $ist -ge $min) { Log "Visual C++ Runtime $ist vorhanden."; return }
    Log "Visual C++ Runtime $ist < $min - installiere..."
    $exe = Join-Path $ArbeitsOrdner "vc_redist.x64.exe"
    Invoke-WebRequest $Manifest.vc_redist.url -OutFile $exe -UseBasicParsing
    $p = Start-Process $exe -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
    if ($p.ExitCode -notin 0, 1638, 3010) { throw "vc_redist Exit-Code $($p.ExitCode)" }
}

# ------------------------------------------------------------------
# Hauptteil
# ------------------------------------------------------------------
New-Item -ItemType Directory -Force $ArbeitsOrdner, $ErgebnisOrdner | Out-Null
$ManifestPfad = (Resolve-Path $ManifestPfad).Path
$Manifest = Get-Content $ManifestPfad -Raw | ConvertFrom-Json
if ($VcRedistInstallieren) { Installiere-VcRedist $Manifest }

Log "Lade $ReleasesUrl"
$Releases = Invoke-RestMethod $ReleasesUrl -UseBasicParsing

# Windows-Neubauten derselben PHP-Version heissen "8.3.36-1" (Datei php-8.3.36-1-nts-...).
# PHP selbst meldet nur "8.3.36" - darum steht in manifest.json unter "version" immer die
# Basisversion (sonst zeigt Interlake jede Installation als veraltet) und unter "build" der Neubau.
function Php-Build([string]$Text) {
    if ($Text -match '(\d+\.\d+\.\d+)(?:-(\d+))?') {
        $nr = 0; if ($Matches[2]) { $nr = [int]$Matches[2] }
        $basis = $Matches[1]
        $name = $basis; if ($nr -gt 0) { $name = "$basis-$nr" }
        return [pscustomobject]@{ basis = $basis; nr = $nr; name = $name }
    }
    throw "Keine PHP-Version erkennbar in '$Text'"
}

$Kandidaten = @()
foreach ($reiheProp in $Manifest.komponenten.php.reihen.PSObject.Properties) {
    $reihe = $reiheProp.Name
    $alt = $reiheProp.Value
    $altBuild = Php-Build $alt.datei
    if ($NurProbe) {
        $Kandidaten += [pscustomobject]@{ reihe = $reihe; alt = $altBuild.name; neu = $alt.version; build = $altBuild.name; datei = $alt.datei; urls = @($alt.urls); sha256 = $alt.sha256; sicherheit = $false }
        continue
    }
    $rel = $Releases.$reihe
    if (-not $rel) { Log "PHP $reihe`: nicht (mehr) in releases.json - uebersprungen."; continue }
    $relBuild = Php-Build $rel.version
    $neuer = ([version]$relBuild.basis -gt [version]$altBuild.basis) -or
             (([version]$relBuild.basis -eq [version]$altBuild.basis) -and $relBuild.nr -gt $altBuild.nr)
    if (-not $neuer) { Log "PHP $reihe`: $($altBuild.name) ist aktuell."; continue }

    # Build mit demselben Compiler wie bisher (vs16/vs17), sonst neuester NTS-x64-Build
    $vsAlt = if ($alt.datei -match '-(vs\d+)-x64') { $Matches[1] } else { "" }
    $schluessel = @($rel.PSObject.Properties.Name | Where-Object { $_ -match '^nts-(vs|vc)\d+-x64$' } | Sort-Object -Descending)
    $wahl = if ($schluessel -contains "nts-$vsAlt-x64") { "nts-$vsAlt-x64" } else { $schluessel | Select-Object -First 1 }
    if (-not $wahl) { Log "PHP $reihe`: kein NTS-x64-Build fuer $($rel.version) - uebersprungen."; continue }
    $zip = $rel.$wahl.zip

    # Sicherheits-Kennzeichen nur fuer eine neue Basisversion (ein Neubau ist kein neues Release)
    $sicher = $false
    if ($relBuild.basis -ne $altBuild.basis) {
        try {
            $info = Invoke-RestMethod ($PhpNetJsonUrl -f $relBuild.basis) -UseBasicParsing
            $eintrag = $info.($relBuild.basis)
            if ($eintrag -and @($eintrag.tags) -contains "security") { $sicher = $true }
        } catch { Log "php.net-Angaben zu $($relBuild.basis) nicht abrufbar: $($_.Exception.Message)" }
    }

    Log "PHP $reihe`: neu $($relBuild.name) (bisher $($altBuild.name), Build $wahl, Sicherheit: $sicher)"
    $Kandidaten += [pscustomobject]@{
        reihe = $reihe; alt = $altBuild.name; neu = $relBuild.basis; build = $relBuild.name; datei = $zip.path; sicherheit = $sicher
        urls = @(($PhpDownloadUrl -f $zip.path), ($PhpArchivUrl -f $zip.path)); sha256 = $zip.sha256.ToLower()
        compilerwechsel = ($wahl -ne "nts-$vsAlt-x64")
    }
}

$Uebernommen = @()
$Fehler = @()
foreach ($k in $Kandidaten) {
    $phpDir = Join-Path $ArbeitsOrdner "php-$($k.build)"
    try {
        Log "PHP $($k.build): Download + Pruefsumme..."
        $zipPfad = Join-Path $ArbeitsOrdner $k.datei
        Hole-Datei $k.urls $zipPfad $k.sha256
        if (Test-Path $phpDir) { Remove-Item $phpDir -Recurse -Force }
        Expand-Archive $zipPfad $phpDir -Force
        Log "PHP $($k.build): Probe php.exe..."
        Pruefe-Php $phpDir $k.neu
        Log "PHP $($k.build): Probe ueber Apache + mod_fcgid..."
        Pruefe-PhpUeberApache $Manifest $phpDir $k.neu
        Log "PHP $($k.build): Probe bestanden."
        $Uebernommen += $k
    } catch {
        $msg = $_.Exception.Message
        Log "PHP $($k.build): FEHLGESCHLAGEN - $msg"
        $Fehler += [pscustomobject]@{ reihe = $k.reihe; version = $k.build; fehler = $msg }
    }
}

$heute = (Get-Date).ToString("yyyy-MM-dd")
$geaendert = $false
if (-not $NurProbe -and $Uebernommen.Count -gt 0) {
    foreach ($k in $Uebernommen) {
        $grund = "Automatisch festgelegt (PHP $($k.alt) -> $($k.build))"
        if ($k.sicherheit) { $grund = "Sicherheits-Release laut php.net; $grund" }
        if ($k.compilerwechsel) { $grund += "; anderer Compiler-Build ($($k.datei)), Visual-C++-Mindestversion pruefen" }
        $grund += "; Pruefsumme laut downloads.php.net, Probeinstallation mit Apache $($Manifest.komponenten.apache.version) + mod_fcgid bestanden."
        # Windows-Neubau derselben Version: bisherige Begruendung (z.B. CVE) behalten
        $bisher = $Manifest.komponenten.php.reihen.($k.reihe)
        if ((Php-Build $k.alt).basis -eq $k.neu -and $bisher.grund) {
            $grund = "Windows-Neubau. $grund Bisher: $($bisher.grund)"
            if ($bisher.sicherheit) { $k.sicherheit = $true }
        }
        $Manifest.komponenten.php.reihen.($k.reihe) = [pscustomobject][ordered]@{
            version       = $k.neu
            build         = $k.build
            datei         = $k.datei
            urls          = @($k.urls)
            sha256        = $k.sha256
            festgelegt_am = $heute
            sicherheit    = [bool]$k.sicherheit
            grund         = $grund
        }
    }
    $Manifest.stand = $heute
    Schreibe-Utf8OhneBom $ManifestPfad ((JsonWert $Manifest 0) + "`n")
    $geaendert = $true
    Log "manifest.json angepasst."
}

# ------------------------------------------------------------------
# Ergebnis
# ------------------------------------------------------------------
$versionen = @($Uebernommen | ForEach-Object { $_.build })
$sicherheit = @($Uebernommen | Where-Object { $_.sicherheit }).Count -gt 0
$titel = if ($versionen.Count) { "PHP " + ($versionen -join ", ") + $(if ($sicherheit) { " (Sicherheit)" } else { "" }) } else { "" }
$zweig = if ($versionen.Count) { "auto/php-" + ($versionen -join "_") } else { "" }

$md = New-Object System.Collections.Generic.List[string]
if ($NurProbe) { $md.Add("Probelauf mit den festgelegten Versionen (es wurde nichts geaendert).") ; $md.Add("") }
foreach ($k in $Uebernommen) {
    $md.Add("- **PHP $($k.reihe): $($k.alt) -> $($k.build)**$(if ($k.sicherheit) { ' - Sicherheits-Release' })")
    $md.Add("  - Datei ``$($k.datei)``, SHA-256 ``$($k.sha256)`` (stimmt mit downloads.php.net ueberein)")
    $md.Add("  - Probeinstallation bestanden: php -m (alle Erweiterungen wie install_production.ps1, OPcache), Testseite ueber Apache $($Manifest.komponenten.apache.version) + mod_fcgid $($Manifest.komponenten.mod_fcgid.version)")
}
foreach ($f in $Fehler) {
    $md.Add("- **PHP $($f.version) (Reihe $($f.reihe)): Probe fehlgeschlagen** - nicht uebernommen")
    $md.Add("  - $($f.fehler)")
}
if ($Kandidaten.Count -eq 0) { $md.Add("Keine neuen PHP-Versionen.") }

$zus = [pscustomobject][ordered]@{
    geaendert  = $geaendert
    titel      = $titel
    zweig      = $zweig
    sicherheit = $sicherheit
    versionen  = @($versionen)
    fehler     = @($Fehler | ForEach-Object { "PHP $($_.version): $($_.fehler)" })
}
Schreibe-Utf8OhneBom (Join-Path $ErgebnisOrdner "zusammenfassung.json") ((JsonWert $zus 0) + "`n")
Schreibe-Utf8OhneBom (Join-Path $ErgebnisOrdner "bericht.md") (($md -join "`n") + "`n")
Log "Fertig: $($Uebernommen.Count) uebernommen, $($Fehler.Count) fehlgeschlagen."
