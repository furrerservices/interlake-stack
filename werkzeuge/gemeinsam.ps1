# gemeinsam.ps1 - Hilfsfunktionen fuer php_pruefen.ps1 und apache_pruefen.ps1 (dot-sourced).
# Erwartet im aufrufenden Skript: $ArbeitsOrdner, $ProbePort.

# Gleiche Liste wie install_production.ps1 (Phase 3) - bei Aenderung dort hier nachziehen.
$Erweiterungen = @("pdo_mysql", "mysqli", "mbstring", "openssl", "curl", "fileinfo", "gd", "intl", "zip")

$UserAgent = "Mozilla/5.0 (compatible; interlake-stack)"

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
                Invoke-WebRequest -Uri $u -OutFile $Ziel -UseBasicParsing -TimeoutSec 300 -UserAgent $UserAgent
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

# Festgelegte Apache- und mod_fcgid-Dateien aus manifest.json laden (Pruefsumme).
# Rueckgabe: @{ apache = <zip>; fcgid = <zip> }
function Hole-FestgelegtesApache($Manifest) {
    return @{ apache = (Hole-Festgelegt $Manifest "apache"); fcgid = (Hole-Festgelegt $Manifest "mod_fcgid") }
}

# Eine festgelegte Komponente (apache, mod_fcgid) laden; Rueckgabe: Pfad zur ZIP.
function Hole-Festgelegt($Manifest, [string]$Komponente) {
    $e = $Manifest.komponenten.$Komponente
    $zip = Join-Path $ArbeitsOrdner ("fest-" + $e.datei)
    Log "$Komponente $($e.version) laden (festgelegt)..."
    Hole-Datei @($e.urls) $zip $e.sha256
    return $zip
}

# Apache aus ZIP entpacken und mod_fcgid.so dazulegen; je Kombination nur einmal.
$script:ApacheCache = @{}
function Bereite-Apache([string]$ApacheZip, [string]$FcgidZip) {
    $schluessel = "$ApacheZip|$FcgidZip"
    if ($script:ApacheCache.ContainsKey($schluessel)) { return $script:ApacheCache[$schluessel] }
    $ziel = Join-Path $ArbeitsOrdner ("apache-" + $script:ApacheCache.Count)
    if (Test-Path $ziel) { Remove-Item $ziel -Recurse -Force }
    Expand-Archive $ApacheZip $ziel -Force
    $httpd = Get-ChildItem $ziel -Recurse -Filter "httpd.exe" | Select-Object -First 1
    if (-not $httpd) { throw "httpd.exe nicht im Apache-Archiv" }
    $root = Split-Path (Split-Path $httpd.FullName)
    $tmpF = Join-Path $ArbeitsOrdner "fcgid-tmp"
    if (Test-Path $tmpF) { Remove-Item $tmpF -Recurse -Force }
    Expand-Archive $FcgidZip $tmpF -Force
    $so = Get-ChildItem $tmpF -Recurse -Filter "mod_fcgid.so" | Select-Object -First 1
    if (-not $so) { throw "mod_fcgid.so nicht im Archiv" }
    Copy-Item $so.FullName (Join-Path $root "modules\mod_fcgid.so") -Force
    Remove-Item $tmpF -Recurse -Force
    $script:ApacheCache[$schluessel] = $root
    return $root
}

# PHP-ZIP der festgelegten Standard-Reihe laden und pruefen (fuer die Apache-Probe).
function Hole-FestgelegtesPhp($Manifest) {
    $reihe = $Manifest.komponenten.php.standard_reihe
    $e = $Manifest.komponenten.php.reihen.$reihe
    $zip = Join-Path $ArbeitsOrdner $e.datei
    $dir = Join-Path $ArbeitsOrdner ("php-fest-" + $e.version)
    Log "PHP $($e.version) laden (festgelegte Standard-Reihe $reihe)..."
    Hole-Datei @($e.urls) $zip $e.sha256
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Expand-Archive $zip $dir -Force
    Pruefe-Php $dir $e.version
    return @{ dir = $dir; version = $e.version }
}

# GPG-Signatur pruefen mit gpgv (kein gpg-agent noetig). $Fingerprint = erwarteter
# Primaerschluessel (40 Hex). Der Schluessel liegt fest im Repo (schluessel/), nie aus dem Netz.
function Pruefe-Signatur([string]$Datei, [string]$Signatur, [string]$Schluessel, [string]$Fingerprint) {
    $gpgv = $null
    foreach ($k in @((Get-Command gpgv -ErrorAction SilentlyContinue).Source, "C:\Program Files\Git\usr\bin\gpgv.exe")) {
        if ($k -and (Test-Path $k)) { $gpgv = $k; break }
    }
    if (-not $gpgv) { throw "gpgv nicht gefunden (Git for Windows installieren)" }

    # Text-Schluessel (ASCII-Armor) -> binaerer Schluesselbund fuer gpgv
    $zeilen = Get-Content $Schluessel
    $b64 = New-Object System.Text.StringBuilder
    $drin = $false; $kopf = $false
    foreach ($z in $zeilen) {
        if ($z -match '^-----BEGIN PGP PUBLIC KEY BLOCK-----') { $drin = $true; $kopf = $true; continue }
        if (-not $drin) { continue }
        if ($kopf) { if ($z.Trim() -eq '') { $kopf = $false }; continue }
        if ($z -match '^-----END' -or $z -match '^=') { break }
        [void]$b64.Append($z.Trim())
    }
    if ($b64.Length -eq 0) { throw "Schluesseldatei ohne PGP-Block: $Schluessel" }
    $bund = Join-Path $ArbeitsOrdner ("schluessel-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".gpg")
    [IO.File]::WriteAllBytes($bund, [Convert]::FromBase64String($b64.ToString()))

    # gpgv aus Git for Windows (MSYS) versteht "C:/..." nicht als absoluten Pfad -> "/c/..."
    $msys = $gpgv -like "*\usr\bin\*"
    $P = { param($x) $x = $x -replace '\\', '/'; if ($msys -and $x -match '^([A-Za-z]):/(.*)$') { "/" + $Matches[1].ToLower() + "/" + $Matches[2] } else { $x } }
    try {
        $v = Starte-Nativ $gpgv @("--status-fd", "1", "--keyring", (& $P $bund), (& $P $Signatur), (& $P $Datei))
        # VALIDSIG <fingerprint> ... <primaerschluessel-fingerprint>
        $zeile = ($v.text -split "`n") | Where-Object { $_ -match '\[GNUPG:\] VALIDSIG ' } | Select-Object -First 1
        if ($v.code -ne 0 -or -not $zeile) { throw "Signatur ungueltig: $($v.text)" }
        $teile = $zeile.Trim() -split '\s+'
        $primaer = $teile[$teile.Count - 1]
        if ($primaer -ne $Fingerprint) { throw "Signatur von fremdem Schluessel $primaer (erwartet $Fingerprint)" }
    } finally { Remove-Item $bund -Force -ErrorAction SilentlyContinue }
}

function Pruefe-PhpUeberApache([string]$ApacheRoot, [string]$PhpDir, [string]$Version) {
    $root = $ApacheRoot
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
