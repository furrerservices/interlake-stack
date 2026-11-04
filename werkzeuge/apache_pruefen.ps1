# apache_pruefen.ps1 - neue Apache-Lounge-Builds (httpd + mod_fcgid) erkennen, pruefen, festlegen.
#
# Laeuft taeglich im GitHub-Lauf ".github/workflows/stack-pruefen.yml" (nach PHP), lokal mit
# Windows PowerShell 5.1 oder PowerShell 7.
#
# Apache Lounge hat keine Versionsliste: die Download-Seite wird ausgelesen. Erkannt wird
#   - eine neue Datei (neue Version oder neues Build-Datum im Namen) und
#   - ein stiller Neubau unter gleichem Namen (Pruefsumme anders; kam 2026-10-24 vor).
#
# httpd:     GPG-Signatur (.asc) mit dem fest im Repo liegenden Schluessel von Apache Lounge
#            (schluessel/apachelounge.asc, Fingerprint unten) + SHA-256 aus der .txt.
# mod_fcgid: Apache Lounge veroeffentlicht weder Signatur noch Pruefsumme -> nur erkennen und
#            pruefen, Uebernahme immer als Pull Request (nie automatisch), siehe immer_pr.
#
# Probe: neues httpd (bzw. festgelegtes) + neues mod_fcgid (bzw. festgelegtes) mit JEDER
# festgelegten PHP-Reihe; Testseite ueber php-cgi muss antworten, httpd -v die Version nennen.
# Bestanden -> manifest.json anpassen (Spiegel-URL zuerst), Dateien in zusammenfassung.json
# unter "spiegel" (ergebnis_melden.ps1 laedt sie ins Release pakete-<Datum>).
#
# -NurProbe: festgelegte Versionen pruefen, nichts aendern.

param(
    [string]$ManifestPfad   = (Join-Path $PSScriptRoot "..\manifest.json"),
    [string]$ArbeitsOrdner  = (Join-Path $env:TEMP "interlake-stack-pruefen"),
    [string]$ErgebnisOrdner = (Join-Path $env:TEMP "interlake-stack-ergebnis-apache"),
    [string]$Repo           = "furrerservices/interlake-stack",
    [int]$ProbePort         = 18081,
    [switch]$NurProbe,
    [switch]$VcRedistInstallieren
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AlBasis      = "https://www.apachelounge.com"
$DownloadSeite = "$AlBasis/download/"
$Fingerprint  = "3D49885EADE8BC399F46D5DDBEE88A7829C17558"   # Steffen Land (Apache Lounge), seit 2013
$Schluessel   = Join-Path $PSScriptRoot "..\schluessel\apachelounge.asc"

. (Join-Path $PSScriptRoot "gemeinsam.ps1")

function Lade([string]$Url, [string]$Ziel) {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -Uri $Url -OutFile $Ziel -UseBasicParsing -TimeoutSec 300 -UserAgent $UserAgent; return }
        catch { if ($i -eq 3) { throw "Download fehlgeschlagen ($Url): $($_.Exception.Message)" }; Start-Sleep -Seconds (5 * $i) }
    }
}
function Sha([string]$Datei) { return (Get-FileHash $Datei -Algorithm SHA256).Hash.ToLower() }

# ------------------------------------------------------------------
New-Item -ItemType Directory -Force $ArbeitsOrdner, $ErgebnisOrdner | Out-Null
$ManifestPfad = (Resolve-Path $ManifestPfad).Path
$Manifest = Get-Content $ManifestPfad -Raw | ConvertFrom-Json
if ($VcRedistInstallieren) { Installiere-VcRedist $Manifest }
$altA = $Manifest.komponenten.apache
$altF = $Manifest.komponenten.mod_fcgid
$heute = (Get-Date).ToString("yyyy-MM-dd")
$tag = "pakete-$heute"
$Fehler = @()
$neuA = $null
$neuF = $null
$immerPr = $false

if (-not $NurProbe) {
    Log "Lade $DownloadSeite"
    $html = (Invoke-WebRequest $DownloadSeite -UseBasicParsing -UserAgent $UserAgent -TimeoutSec 120).Content

    # --- httpd ---
    try {
        $m = [regex]::Match($html, 'href="(/download/(VS\d+)/binaries/(httpd-(2\.4\.\d+)-(\d+)-Win64-VS\d+\.zip))"')
        if (-not $m.Success) { throw "Kein httpd-2.4-Win64-Download auf der Seite gefunden (Seite umgebaut?)" }
        $pfad = $m.Groups[1].Value; $vs = $m.Groups[2].Value; $datei = $m.Groups[3].Value
        $version = $m.Groups[4].Value; $build = $m.Groups[5].Value
        $zip = Join-Path $ArbeitsOrdner $datei
        Lade "$AlBasis$pfad" $zip
        $sha = Sha $zip
        if ($datei -eq $altA.datei -and $sha -eq $altA.sha256.ToLower()) {
            Log "Apache: $datei ist aktuell."
        } else {
            Log "Apache: neu $datei (bisher $($altA.datei)), SHA-256 $sha"
            if ([version]$version -lt [version]$altA.version) { throw "Seite nennt aeltere Version $version als festgelegt ($($altA.version))" }
            Lade "$AlBasis$pfad.asc" "$zip.asc"
            Lade "$AlBasis$pfad.txt" "$zip.txt"
            Pruefe-Signatur $zip "$zip.asc" (Resolve-Path $Schluessel).Path $Fingerprint
            $txt = Get-Content "$zip.txt" -Raw
            $t = [regex]::Match($txt, "SHA256-Checksum for: $([regex]::Escape($datei)):\s*([0-9A-Fa-f]{64})")
            if (-not $t.Success) { throw "SHA-256 fehlt in $datei.txt" }
            if ($t.Groups[1].Value.ToLower() -ne $sha) { throw "SHA-256 laut $datei.txt ($($t.Groups[1].Value)) passt nicht zur Datei ($sha)" }
            $vsAlt = if ($altA.datei -match '-(VS\d+)\.zip$') { $Matches[1] } else { "" }
            $compiler = ($vs -ne $vsAlt)
            if ($compiler) { $immerPr = $true }
            $art = "neue Version"
            if ($version -eq $altA.version -and $datei -eq $altA.datei) { $art = "stiller Neubau unter gleichem Namen" }
            elseif ($version -eq $altA.version) { $art = "Neubau" }
            $neuA = [pscustomobject]@{ version = $version; build = $build; datei = $datei; zip = $zip; sha = $sha; vs = $vs; compiler = $compiler; art = $art
                vendorUrl = "$AlBasis$pfad" }
        }
    } catch {
        Log "Apache: FEHLER - $($_.Exception.Message)"
        $Fehler += "Apache: $($_.Exception.Message)"
    }

    # --- mod_fcgid ---
    try {
        $m = [regex]::Match($html, 'href="(/download/(VS\d+)/modules/(mod_fcgid-(\d+\.\d+\.\d+)-win64-VS\d+\.zip))"')
        if (-not $m.Success) { throw "Kein mod_fcgid-Win64-Download auf der Seite gefunden (Seite umgebaut?)" }
        $pfad = $m.Groups[1].Value; $datei = $m.Groups[3].Value; $version = $m.Groups[4].Value
        $zip = Join-Path $ArbeitsOrdner $datei
        Lade "$AlBasis$pfad" $zip
        $sha = Sha $zip
        if ($datei -eq $altF.datei -and $sha -eq $altF.sha256.ToLower()) {
            Log "mod_fcgid: $datei ist aktuell."
        } else {
            Log "mod_fcgid: neu $datei (bisher $($altF.datei)), SHA-256 $sha - ohne Anbieter-Pruefsumme, nur als Pull Request"
            $art = "neue Version"; if ($datei -eq $altF.datei) { $art = "stiller Neubau unter gleichem Namen" }
            $neuF = [pscustomobject]@{ version = $version; datei = $datei; zip = $zip; sha = $sha; art = $art; vendorUrl = "$AlBasis$pfad" }
            $immerPr = $true
        }
    } catch {
        Log "mod_fcgid: FEHLER - $($_.Exception.Message)"
        $Fehler += "mod_fcgid: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------
# Probe (bei Kandidaten oder -NurProbe)
# ------------------------------------------------------------------
$bestanden = $false
if ($NurProbe -or $neuA -or $neuF) {
    $name = @()
    if ($neuA) { $name += "Apache $($neuA.version) ($($neuA.datei))" }
    if ($neuF) { $name += "mod_fcgid $($neuF.version)" }
    if (-not $name) { $name = @("festgelegte Versionen") }
    $name = $name -join " + "
    try {
        # Nur laden, was nicht neu geprueft wird
        if ($neuA) { $zipA = $neuA.zip } else { $zipA = Hole-Festgelegt $Manifest "apache" }
        if ($neuF) { $zipF = $neuF.zip } else { $zipF = Hole-Festgelegt $Manifest "mod_fcgid" }
        $erwartet = $altA.version; if ($neuA) { $erwartet = $neuA.version }
        $root = Bereite-Apache $zipA $zipF
        $v = Starte-Nativ (Join-Path $root "bin\httpd.exe") @("-v")
        if ($v.text -notmatch "Apache/$([regex]::Escape($erwartet))\b") { throw "httpd -v meldet nicht $erwartet`: $($v.text)" }
        foreach ($rp in $Manifest.komponenten.php.reihen.PSObject.Properties) {
            $e = $rp.Value
            $zip = Join-Path $ArbeitsOrdner $e.datei
            $dir = Join-Path $ArbeitsOrdner ("php-fest-" + $rp.Name)
            Log "Probe $name mit PHP $($e.version)..."
            Hole-Datei @($e.urls) $zip $e.sha256
            if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
            Expand-Archive $zip $dir -Force
            Pruefe-Php $dir $e.version
            Pruefe-PhpUeberApache $root $dir $e.version
        }
        Log "Probe $name bestanden."
        $bestanden = $true
    } catch {
        Log "Probe $name FEHLGESCHLAGEN - $($_.Exception.Message)"
        $Fehler += "${name}: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------
# manifest.json anpassen
# ------------------------------------------------------------------
$spiegel = @()
$geaendert = $false
$phpListe = (@($Manifest.komponenten.php.reihen.PSObject.Properties | ForEach-Object { $_.Value.version }) -join ", ")
if (-not $NurProbe -and $bestanden -and ($neuA -or $neuF)) {
    if ($neuA) {
        $grund = "Automatisch festgelegt ($($neuA.art): $($altA.datei) -> $($neuA.datei)); GPG-Signatur Apache Lounge und SHA-256 laut .txt geprueft, Probe mit PHP $phpListe bestanden."
        if ($neuA.compiler) { $grund += " Anderer Compiler ($($neuA.vs)): Visual-C++-Mindestversion (vc_redist) pruefen!" }
        $Manifest.komponenten.apache = [pscustomobject][ordered]@{
            version       = $neuA.version
            build         = $neuA.build
            datei         = $neuA.datei
            urls          = @("https://github.com/$Repo/releases/download/$tag/$($neuA.datei)", $neuA.vendorUrl)
            sha256        = $neuA.sha
            festgelegt_am = $heute
            sicherheit    = $false
            grund         = $grund
        }
        $spiegel += [pscustomobject]@{ tag = $tag; datei = $neuA.datei; pfad = $neuA.zip }
    }
    if ($neuF) {
        $Manifest.komponenten.mod_fcgid = [pscustomobject][ordered]@{
            version       = $neuF.version
            datei         = $neuF.datei
            urls          = @("https://github.com/$Repo/releases/download/$tag/$($neuF.datei)", $neuF.vendorUrl)
            sha256        = $neuF.sha
            festgelegt_am = $heute
            grund         = "Automatisch erkannt ($($neuF.art): $($altF.datei) -> $($neuF.datei)); Apache Lounge veroeffentlicht fuer Module keine Pruefsumme (beim Download gemessen), Probe mit PHP $phpListe bestanden. Von Hand freigegeben (Pull Request)."
        }
        $spiegel += [pscustomobject]@{ tag = $tag; datei = $neuF.datei; pfad = $neuF.zip }
    }
    Schreibe-Utf8OhneBom $ManifestPfad ((JsonWert $Manifest 0) + "`n")
    $geaendert = $true
    Log "manifest.json angepasst."
}

# ------------------------------------------------------------------
# Ergebnis
# ------------------------------------------------------------------
$teile = @()
$zweigTeile = @()
if ($neuA -and $geaendert) { $teile += "Apache $($neuA.version)$(if ($neuA.art -ne 'neue Version') { ' Neubau' })"; $zweigTeile += "httpd-$($neuA.version)-$($neuA.build)-$($neuA.sha.Substring(0, 8))" }
if ($neuF -and $geaendert) { $teile += "mod_fcgid $($neuF.version)$(if ($neuF.art -ne 'neue Version') { ' Neubau' })"; $zweigTeile += "fcgid-$($neuF.version)-$($neuF.sha.Substring(0, 8))" }
$titel = $teile -join ", "
$zweig = ""; if ($zweigTeile) { $zweig = "auto/apache-" + ($zweigTeile -join "_") }

$md = New-Object System.Collections.Generic.List[string]
if ($NurProbe) { $md.Add("Probelauf Apache $($altA.version) + mod_fcgid $($altF.version) mit PHP $phpListe (es wurde nichts geaendert).") ; $md.Add("") }
if ($neuA -and $geaendert) {
    $md.Add("- **Apache: $($altA.datei) -> $($neuA.datei)** ($($neuA.art))")
    $md.Add("  - SHA-256 ``$($neuA.sha)``, GPG-Signatur von Apache Lounge gueltig (Schluessel $Fingerprint), stimmt mit .txt ueberein")
    if ($neuA.compiler) { $md.Add("  - **Anderer Compiler ($($neuA.vs))** - Visual-C++-Mindestversion in manifest.json (vc_redist) pruefen, deshalb Pull Request statt automatisch") }
}
if ($neuF -and $geaendert) {
    $md.Add("- **mod_fcgid: $($altF.datei) -> $($neuF.datei)** ($($neuF.art))")
    $md.Add("  - SHA-256 ``$($neuF.sha)`` (selbst gemessen - Apache Lounge veroeffentlicht fuer Module keine Pruefsumme, darum immer von Hand freigeben)")
}
if ($geaendert) {
    $md.Add("  - Probeinstallation bestanden mit PHP $phpListe (Testseite ueber php-cgi)")
    $md.Add("  - Gespiegelt ins Release ``$tag`` (erste Download-Adresse in manifest.json)")
}
if ($NurProbe -and $bestanden) { $md.Add("Probe bestanden.") }
foreach ($f in $Fehler) { $md.Add("- **Fehler:** $f") }
if (-not $NurProbe -and -not $neuA -and -not $neuF -and -not $Fehler) { $md.Add("Apache und mod_fcgid unveraendert.") }

$zus = [pscustomobject][ordered]@{
    geaendert  = $geaendert
    titel      = $titel
    bereich    = "apache"
    immer_pr   = [bool]$immerPr
    zweig      = $zweig
    sicherheit = $false
    versionen  = @($teile)
    fehler     = @($Fehler)
    spiegel    = @($spiegel | ForEach-Object { [pscustomobject][ordered]@{ tag = $_.tag; datei = $_.datei; pfad = $_.pfad } })
}
Schreibe-Utf8OhneBom (Join-Path $ErgebnisOrdner "zusammenfassung.json") ((JsonWert $zus 0) + "`n")
Schreibe-Utf8OhneBom (Join-Path $ErgebnisOrdner "bericht.md") (($md -join "`n") + "`n")
Log "Fertig: geaendert=$geaendert, Fehler=$($Fehler.Count)."
