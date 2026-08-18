# ============================================================
# Teams status -> Home Assistant webhook
#
# Parst de lokale logbestanden van de nieuwe Microsoft Teams-client
# en stuurt bij elke statuswijziging een webhook-POST naar Home
# Assistant. Werkt zonder Microsoft Graph API-toegang of
# adminrechten -- alleen leestoegang tot je eigen Teams-logs nodig.
#
# Vereist: config.ps1 in dezelfde map (kopieer config.example.ps1).
# ============================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$configPath = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Error "config.ps1 niet gevonden. Kopieer config.example.ps1 naar config.ps1 en vul je eigen waarden in."
    exit 1
}
. $configPath

function Get-TeamsStatus {
    param($LatestLogPath)

    $statusLine = Select-String -Path $LatestLogPath -Pattern "availability:\s*(\w+)" |
        Select-Object -Last 1

    if ($statusLine) { $statusLine.Matches[0].Groups[1].Value } else { "Unknown" }
}

function Get-TeamsCallState {
    param($LatestLogPath, $PreviousInCall)

    $callLine = Select-String -Path $LatestLogPath -Pattern "TeamsCallTracker: Call (became active|ended):" |
        Select-Object -Last 1

    # Geen call-event gevonden in dit (mogelijk net geroteerde) logbestand?
    # Dan de vorige bekende call-state behouden i.p.v. een gok te maken.
    if (-not $callLine) { return $PreviousInCall }

    return ($callLine.Line -match "became active")
}

function Send-StatusUpdate {
    param($Status, $InCall)

    $payload = @{
        status  = $Status
        in_call = $InCall
    } | ConvertTo-Json

    $params = @{
        Uri         = $webhookUrl
        Method      = "Post"
        Body        = $payload
        ContentType = "application/json"
        TimeoutSec  = 5
    }
    if ($proxyUrl) {
        $params["Proxy"] = $proxyUrl
        $params["ProxyUseDefaultCredentials"] = $true
    }

    Invoke-RestMethod @params
}

Write-Host "Teams status -> Home Assistant gestart. Ctrl+C om te stoppen."

while ($true) {
    $latestLog = Get-ChildItem -Path $logDir -Filter "MSTeams_20*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($latestLog) {
        # --- Vorige state inlezen ---
        $lastStatus = ""
        $lastInCall = $false
        if (Test-Path $stateFile) {
            $saved = Get-Content $stateFile
            if ($saved.Count -ge 2) {
                $lastStatus = $saved[0]
                $lastInCall = [bool]::Parse($saved[1])
            }
        }

        $status = Get-TeamsStatus -LatestLogPath $latestLog.FullName
        $inCall = Get-TeamsCallState -LatestLogPath $latestLog.FullName -PreviousInCall $lastInCall

        # --- Alleen versturen bij wijziging ---
        if ($status -ne $lastStatus -or $inCall -ne $lastInCall) {
            try {
                Send-StatusUpdate -Status $status -InCall $inCall
                # State pas opslaan na een geslaagde POST, zodat een gemiste
                # wijziging (bv. door een tijdelijke netwerkstoring) bij de
                # volgende iteratie opnieuw geprobeerd wordt.
                Set-Content -Path $stateFile -Value @($status, $inCall.ToString())
            } catch {
                Write-Warning "Kon status niet versturen: $($_.Exception.Message)"
            }
        }
    }

    Start-Sleep -Seconds $pollIntervalSeconds
}
