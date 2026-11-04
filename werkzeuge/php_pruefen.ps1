# php_pruefen.ps1 - neue PHP-Versionen erkennen, pruefen und in manifest.json festlegen.
#
# Laeuft taeglich im GitHub-Lauf ".github/workflows/stack-pruefen.yml" (Windows-Runner),
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


. (Join-Path $PSScriptRoot "gemeinsam.ps1")

# ------------------------------------------------------------------
# Hauptteil
# ------------------------------------------------------------------
New-Item -ItemType Directory -Force $ArbeitsOrdner, $ErgebnisOrdner | Out-Null
$ManifestPfad = (Resolve-Path $ManifestPfad).Path
$Manifest = Get-Content $ManifestPfad -Raw | ConvertFrom-Json
if ($VcRedistInstallieren) { Installiere-VcRedist $Manifest }

Log "Lade $ReleasesUrl"
$Releases = Invoke-RestMethod $ReleasesUrl -UseBasicParsing

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
$festApache = $null
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
        if (-not $festApache) { $z = Hole-FestgelegtesApache $Manifest; $festApache = Bereite-Apache $z.apache $z.fcgid }
        Pruefe-PhpUeberApache $festApache $phpDir $k.neu
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
    bereich    = "php"
    immer_pr   = $false
    zweig      = $zweig
    sicherheit = $sicherheit
    versionen  = @($versionen)
    fehler     = @($Fehler | ForEach-Object { "PHP $($_.version): $($_.fehler)" })
    spiegel    = @()
}
Schreibe-Utf8OhneBom (Join-Path $ErgebnisOrdner "zusammenfassung.json") ((JsonWert $zus 0) + "`n")
Schreibe-Utf8OhneBom (Join-Path $ErgebnisOrdner "bericht.md") (($md -join "`n") + "`n")
Log "Fertig: $($Uebernommen.Count) uebernommen, $($Fehler.Count) fehlgeschlagen."
