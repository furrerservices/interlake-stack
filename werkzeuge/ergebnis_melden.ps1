# ergebnis_melden.ps1 - Ergebnis von php_pruefen.ps1 im GitHub-Lauf umsetzen.
#
#   geaendert + AUTO_UEBERNEHMEN=ja -> Commit auf main + Info-Issue (sofort geschlossen, nur fuer die Mail)
#   geaendert + sonst               -> Zweig auto/php-<versionen> + Pull Request (nur einmal je Version)
#   fehler                          -> Issue "PHP <version>: Probe fehlgeschlagen" (nur einmal je Version)
#
# Braucht: gh (GH_TOKEN), git; laeuft im Repo-Ordner.

param([Parameter(Mandatory)][string]$ErgebnisOrdner)

$ErrorActionPreference = "Stop"
$zus = Get-Content (Join-Path $ErgebnisOrdner "zusammenfassung.json") -Raw | ConvertFrom-Json
$bericht = Join-Path $ErgebnisOrdner "bericht.md"
$auto = $env:AUTO_UEBERNEHMEN -eq "ja"
$repo = $env:GITHUB_REPOSITORY

function Gh([string[]]$Argumente) {
    $aus = & gh @Argumente 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "gh $($Argumente -join ' ') fehlgeschlagen: $($aus -join ' ')" }
    return ($aus -join "`n")
}
function Git([string[]]$Argumente) {
    & git @Argumente
    if ($LASTEXITCODE -ne 0) { throw "git $($Argumente -join ' ') fehlgeschlagen" }
}
# Auch geschlossene zaehlen: eine fehlgeschlagene Version wird nur einmal gemeldet,
# nicht nach dem Schliessen jeden Tag neu.
function Issue-Gibt-Es([string]$Titel) {
    $liste = Gh @("issue", "list", "--state", "all", "--limit", "200", "--json", "title") | ConvertFrom-Json
    return @($liste | Where-Object { $_.title -eq $Titel }).Count -gt 0
}

if ($env:NUR_PROBE -eq "true") {
    Write-Host "Probelauf - es wird nichts uebernommen."
    if (@($zus.fehler).Count -gt 0) { throw "Probe fehlgeschlagen: $($zus.fehler -join '; ')" }
    return
}

if ($zus.geaendert) {
    git config user.name  "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    $nachricht = "Automatisch festgelegt: $($zus.titel)"
    $info = Join-Path $ErgebnisOrdner "info.md"

    if ($auto) {
        Git @("add", "manifest.json")
        Git @("commit", "-q", "-m", $nachricht)
        Git @("push", "origin", "HEAD:main")
        $text = "Neue Versionen sind in ``manifest.json`` festgelegt und gelten ab der naechsten taeglichen Pruefung bei allen Installationen.`n`n" + (Get-Content $bericht -Raw) + "`n@furrerservices (nur zur Info, nichts zu tun)"
        [IO.File]::WriteAllText($info, $text)
        $url = Gh @("issue", "create", "--title", "Uebernommen: $($zus.titel)", "--body-file", $info)
        Gh @("issue", "close", $url) | Out-Null
        Write-Host "Auf main uebernommen: $($zus.titel)"
    } else {
        $zweig = $zus.zweig
        $vorhanden = & git ls-remote --heads origin $zweig
        if ($vorhanden) {
            Write-Host "Zweig $zweig existiert schon (Pull Request offen oder abgelehnt) - nichts zu tun."
        } else {
            Git @("checkout", "-q", "-b", $zweig)
            Git @("add", "manifest.json")
            Git @("commit", "-q", "-m", $nachricht)
            Git @("push", "-q", "origin", $zweig)
            $text = (Get-Content $bericht -Raw) + "`nMergen = Version festlegen. Danach wie bisher in ``stack_versionen.json`` (Interlake-Repo) nachfuehren, bis Interlake die Version selbst einspielt (briefing 225, Etappe 2).`n`n@furrerservices"
            [IO.File]::WriteAllText($info, $text)
            try {
                $url = Gh @("pr", "create", "--base", "main", "--head", $zweig, "--title", $zus.titel, "--body-file", $info)
                Write-Host "Pull Request: $url"
            } catch {
                # Repo-Einstellung "Allow GitHub Actions to create pull requests" fehlt -> Issue mit Link
                Write-Host "Pull Request nicht moeglich ($($_.Exception.Message)) - lege Issue an."
                $text += "`n`nPull Request von Hand erstellen: https://github.com/$repo/compare/main...$zweig"
                [IO.File]::WriteAllText($info, $text)
                Gh @("issue", "create", "--title", "Neue Version: $($zus.titel)", "--body-file", $info) | Out-Null
            }
        }
    }
}

foreach ($f in @($zus.fehler)) {
    $version = ($f -split ':')[0]   # "PHP 8.5.13"
    $titel = "${version}: Probe fehlgeschlagen"
    if (Issue-Gibt-Es $titel) { Write-Host "Issue '$titel' gibt es schon."; continue }
    $text = "Die Version wurde **nicht** festgelegt, ``manifest.json`` ist unveraendert. Kein Zeitdruck: alle Installationen laufen mit der bisherigen Version weiter.`n`n``````n$f`n```````n`nLauf: https://github.com/$repo/actions/runs/$env:GITHUB_RUN_ID`n`n@furrerservices"
    $datei = Join-Path $ErgebnisOrdner "fehler.md"
    [IO.File]::WriteAllText($datei, $text)
    Gh @("issue", "create", "--title", $titel, "--body-file", $datei) | Out-Null
    Write-Host "Issue angelegt: $titel"
}
