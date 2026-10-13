#Requires -Version 5.1
<#
============================================================
 Claude billing report
============================================================

 PURPOSE
 Sends one tiny request through Invoke-Claude (kept under 100
 tokens in total) and reports what it used and what it cost.

 USAGE
   .\Get-ClaudeBilling-Report01.ps1
 Needs the Invoke-Claude script (named in $LibraryFile below) in the
 same folder. Asks for the KeePass master password like it does.

 NOTES
  - Costs are estimates in US dollars from the Prices table in the
    Invoke-Claude script's SETTINGS (one table for everything).
    Anthropic bills from its own records; check the Claude Console
    (Billing / Usage) for actual charges and your credit balance.
  - This call is recorded in the usage log with the label below, so
    usage reports can show it separately.
  - Exits with the same codes as the Invoke-Claude script if the call fails.
============================================================
#>

# ── SETTINGS ─────────────────────────────────────────────────
$LibraryFile     = 'Invoke-Claude-API-01.ps1'   # The Invoke-Claude script, in this folder
$ReportPrompt    ='Reply with one short sentence confirming you are working.'
$ReportMaxTokens = 40      # Reply limit; keeps the whole request well under the budget
$TokenBudget     = 100     # Warn if a request uses this many tokens or more (input + output)
$ReportLabel     = 'billing-report'   # How this call appears in the usage log

# ── RUN ───────────────────────────────────────────────────────
$Lib = Join-Path $PSScriptRoot $LibraryFile
if (-not (Test-Path -LiteralPath $Lib)) {
    Write-Host "$LibraryFile not found next to this report." -ForegroundColor Red
    Write-Host "  Looked for : $Lib" -ForegroundColor DarkGray
    Write-Host "  Check `$LibraryFile in SETTINGS." -ForegroundColor DarkGray
    exit 10
}
. $Lib

try {
    $R = Invoke-Claude -Prompt $ReportPrompt -MaxTokens $ReportMaxTokens -Label $ReportLabel
} catch {
    $Data = $_.Exception.Data
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($Data -and $Data['Details']) { $Data['Details'] | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
    if ($Data -and $Data['LogFile']) { Write-Host "  Logged to  : $($Data['LogFile'])" -ForegroundColor DarkGray }
    exit $(if ($Data -and $null -ne $Data['ExitCode']) { [int]$Data['ExitCode'] } else { 1 })
}

Write-Host "`n── Billing report ────────────────────────────────────" -ForegroundColor Yellow
Write-Host ("Date (UTC)      : {0}" -f ([datetime]$R.Timestamp).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host ("Model           : {0}" -f $R.Model)
Write-Host ("Input tokens    : {0}" -f $R.InputTokens)
Write-Host ("Output tokens   : {0}" -f $R.OutputTokens)
Write-Host ("Total tokens    : {0} (budget {1})" -f $R.TotalTokens, $TokenBudget)

if ($null -ne $R.EstimatedCostUsd) {
    # Rates and total come from Invoke-Claude, so this report and the usage log always agree
    $Tier    = if ($R.PriceTier -eq 'long-prompt') { ' (long-prompt rate)' } else { '' }
    $InCost  = $R.InputTokens  * $R.InputRate  / 1e6
    $OutCost = $R.OutputTokens * $R.OutputRate / 1e6
    $Total   = $R.EstimatedCostUsd

    Write-Host ("Rates           : `${0:N2} in / `${1:N2} out per million tokens{2}" -f $R.InputRate, $R.OutputRate, $Tier)
    Write-Host ("Input cost      : `${0:N7}" -f $InCost)
    Write-Host ("Output cost     : `${0:N7}" -f $OutCost)
    if ($R.CacheWriteTokens -or $R.CacheReadTokens) {
        Write-Host ("Cache cost      : `${0:N7}" -f ($Total - $InCost - $OutCost))
    }
    Write-Host ("Total cost      : `${0:N7}" -f $Total) -ForegroundColor Green
    Write-Host ("Per 1,000 calls : `${0:N4}" -f ($Total * 1000))
} else {
    Write-Host "Cost            : no price listed for $($R.Model). Add it to Prices in $LibraryFile." -ForegroundColor Yellow
}
Write-Host "──────────────────────────────────────────────────────" -ForegroundColor Yellow

if ($R.TotalTokens -ge $TokenBudget) {
    Write-Host "Warning: this request used $($R.TotalTokens) tokens, over the $TokenBudget-token budget." -ForegroundColor Yellow
}
Write-Host 'Estimate only. Actual charges and balance: Claude Console > Billing.' -ForegroundColor DarkGray
exit 0
