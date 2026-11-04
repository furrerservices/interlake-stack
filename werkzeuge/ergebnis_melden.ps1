# ergebnis_melden.ps1 - Ergebnis von php_pruefen.ps1 im GitHub-Lauf umsetzen.
#
#   geaendert + AUTO_UEBERNEHMEN=ja -> Commit auf main + Info-Issue (sofort geschlossen, nur fuer die Mail)
#   geaendert + sonst oder immer_pr -> Zweig + Pull Request (nur einmal je Zweig), vorher Spiegel-Upload
#   fehler                          -> Issue "PHP <version>: Probe fehlgeschlagen" (nur einmal je Version)
#
# Braucht: gh (GH_TOKEN), git; laeuft im Repo-Ordner.

param([Parameter(Mandatory)][string]$ErgebnisOrdner)

$ErrorActionPreference = "Stop"
$zus = Get-Content (Join-Path $ErgebnisOrdner "zusammenfassung.json") -Raw | ConvertFrom-Json
$bericht = Join-Path $ErgebnisOrdner "bericht.md"
$auto = $env:AUTO_UEBERNEHMEN -eq "ja"
$repo = $env:GITHUB_REPOSITORY

function Gh-Aufruf([string[]]$Argumente) {
    $aus = & gh @Argumente 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "gh $($Argumente -join ' ') fehlgeschlagen: $($aus -join ' ')" }
    return ($aus -join "`n")
}
function Git-Aufruf([string[]]$Argumente) {
    & git @Argumente
    if ($LASTEXITCODE -ne 0) { throw "git $($Argumente -join ' ') fehlgeschlagen" }
}
# Auch geschlossene zaehlen: eine fehlgeschlagene Version wird nur einmal gemeldet,
# nicht nach dem Schliessen jeden Tag neu.
function Issue-Gibt-Es([string]$Titel) {
    $liste = Gh-Aufruf @("issue", "list", "--state", "all", "--limit", "200", "--json", "title") | ConvertFrom-Json
    return @($liste | Where-Object { $_.title -eq $Titel }).Count -gt 0
}

if ($env:NUR_PROBE -eq "true") {
    Write-Host "Probelauf - es wird nichts uebernommen."
    if (@($zus.fehler).Count -gt 0) { throw "Probe fehlgeschlagen: $($zus.fehler -join '; ')" }
    return
}

# Dateien ins eigene Release pakete-<Datum> laden (Spiegel), bevor manifest.json darauf zeigt.
function Spiegeln($Liste) {
    foreach ($s in @($Liste)) {
        & gh release view $s.tag *> $null
        if ($LASTEXITCODE -ne 0) {
            Gh-Aufruf @("release", "create", $s.tag, "--title", $s.tag, "--notes", "Unveraenderte Kopien von Paketen, deren Anbieter alte Builds nicht dauerhaft anbieten. Automatisch angelegt vom Lauf Stack pruefen.") | Out-Null
        }
        Gh-Aufruf @("release", "upload", $s.tag, $s.pfad, "--clobber") | Out-Null
        Write-Host "Gespiegelt: $($s.datei) -> Release $($s.tag)"
    }
}

if ($zus.geaendert) {
    git config user.name  "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    $nachricht = "Automatisch festgelegt: $($zus.titel)"
    $info = Join-Path $ErgebnisOrdner "info.md"

    if ($auto -and -not $zus.immer_pr) {
        Spiegeln $zus.spiegel
        Git-Aufruf @("add", "manifest.json")
        Git-Aufruf @("commit", "-q", "-m", $nachricht)
        # Der PHP-Teil kann im selben Lauf schon gepusht haben
        Git-Aufruf @("pull", "-q", "--rebase", "origin", "main")
        Git-Aufruf @("push", "origin", "HEAD:main")
        $text = "Neue Versionen sind in ``manifest.json`` festgelegt und gelten ab der naechsten taeglichen Pruefung bei allen Installationen.`n`n" + (Get-Content $bericht -Raw) + "`n@furrerservices (nur zur Info, nichts zu tun)"
        [IO.File]::WriteAllText($info, $text)
        $url = Gh-Aufruf @("issue", "create", "--title", "Uebernommen: $($zus.titel)", "--body-file", $info)
        Gh-Aufruf @("issue", "close", $url) | Out-Null
        Write-Host "Auf main uebernommen: $($zus.titel)"
    } else {
        $zweig = $zus.zweig
        $vorhanden = & git ls-remote --heads origin $zweig
        if ($vorhanden) {
            Write-Host "Zweig $zweig existiert schon (Pull Request offen oder abgelehnt) - nichts zu tun."
        } else {
            Spiegeln $zus.spiegel
            Git-Aufruf @("checkout", "-q", "-b", $zweig)
            Git-Aufruf @("add", "manifest.json")
            Git-Aufruf @("commit", "-q", "-m", $nachricht)
            Git-Aufruf @("push", "-q", "origin", $zweig)
            $hinweis = "Mergen = Version festlegen."
            if ($zus.immer_pr) { $hinweis += " **Muss von Hand freigegeben werden** (siehe oben: keine Anbieter-Pruefsumme bzw. anderer Compiler)." }
            if ($zus.bereich -eq "php") { $hinweis += " Danach wie bisher in ``stack_versionen.json`` (Interlake-Repo) nachfuehren, bis Interlake die Version selbst einspielt (briefing 225, Etappe 2)." }
            $text = (Get-Content $bericht -Raw) + "`n$hinweis`n`n@furrerservices"
            [IO.File]::WriteAllText($info, $text)
            try {
                $url = Gh-Aufruf @("pr", "create", "--base", "main", "--head", $zweig, "--title", $zus.titel, "--body-file", $info)
                Write-Host "Pull Request: $url"
            } catch {
                # Repo-Einstellung "Allow GitHub Actions to create pull requests" fehlt -> Issue mit Link
                Write-Host "Pull Request nicht moeglich ($($_.Exception.Message)) - lege Issue an."
                $text += "`n`nPull Request von Hand erstellen: https://github.com/$repo/compare/main...$zweig"
                [IO.File]::WriteAllText($info, $text)
                Gh-Aufruf @("issue", "create", "--title", "Neue Version: $($zus.titel)", "--body-file", $info) | Out-Null
            }
        }
    }
}

foreach ($f in @($zus.fehler)) {
    # Titel = Teil vor dem ersten ":" ("PHP 8.5.13", "Apache 2.4.70 (...)") -> einmal je Version.
    # Ohne Versionsnummer (z.B. "Apache: Seite umgebaut") hoechstens einmal im Monat.
    $was = ($f -split ':')[0]
    if ($was -notmatch '\d') { $was += " ($((Get-Date).ToString('yyyy-MM')))" }
    $titel = "${was}: Probe fehlgeschlagen"
    if ($titel.Length -gt 120) { $titel = $titel.Substring(0, 117) + "..." }
    if (Issue-Gibt-Es $titel) { Write-Host "Issue '$titel' gibt es schon."; continue }
    $text = "Wurde **nicht** festgelegt, ``manifest.json`` ist dafuer unveraendert. Kein Zeitdruck: alle Installationen laufen mit der bisherigen Version weiter.`n`n``````n$f`n```````n`nLauf: https://github.com/$repo/actions/runs/$env:GITHUB_RUN_ID`n`n@furrerservices"
    $datei = Join-Path $ErgebnisOrdner "fehler.md"
    [IO.File]::WriteAllText($datei, $text)
    Gh-Aufruf @("issue", "create", "--title", $titel, "--body-file", $datei) | Out-Null
    Write-Host "Issue angelegt: $titel"
}
