#Requires -Version 5.1
<#
============================================================
 Claude usage reports
============================================================

 PURPOSE
 Reads the usage log written by Invoke-Claude-API-01.ps1
 (Claude-Usage-API.csv, one row per API call) and reports on it.
 Makes no API call and needs no password.

 USAGE
   .\Get-ClaudeUsage-Report01.ps1                       # this month, every section
   .\Get-ClaudeUsage-Report01.ps1 -Period Today
   .\Get-ClaudeUsage-Report01.ps1 -Period LastMonth -Report Summary, Models
   .\Get-ClaudeUsage-Report01.ps1 -From 2026-10-01 -To 2026-10-15
   .\Get-ClaudeUsage-Report01.ps1 -Label 'nightly*'     # only matching labels
   .\Get-ClaudeUsage-Report01.ps1 -ExportCsv .\october.csv

 PERIODS
   Today, Yesterday, ThisWeek, LastWeek, ThisMonth (default),
   LastMonth, Last7Days, Last30Days, ThisYear, All.
   -From / -To (dates, inclusive) override -Period.

 SECTIONS (-Report; default All)
   Summary   Calls, failure rate, tokens, cost, averages, busiest day
   Budget    This month's spend against your budget, and a projection
             of the month's total at the current rate (all calls)
   Daily     Per day, with a running total
   Models    By model
   Callers   By calling script or program
   Labels    By label (Invoke-Claude -Label)
   Top       Most expensive and slowest calls
   Failures  Failed calls by reason, and the most recent ones

 NOTES
  - Costs are estimates recorded at the time of each call, from the
    Prices table in Invoke-Claude-API-01.ps1. Anthropic's invoice is
    the final word.
  - Calls made outside these scripts (other tools using the same API
    key) aren't in the log.
  - Times are shown in this computer's time zone.
============================================================
#>
[CmdletBinding()]
param(
    [ValidateSet('Today', 'Yesterday', 'ThisWeek', 'LastWeek', 'ThisMonth', 'LastMonth',
                 'Last7Days', 'Last30Days', 'ThisYear', 'All')]
    [string]$Period = 'ThisMonth',
    [datetime]$From,
    [datetime]$To,
    [string[]]$Report = 'All',      # One or more sections, e.g. Summary, Budget (see SECTIONS)
    [string]$Label,                 # Filter by label (wildcards allowed)
    [string]$Model,                 # Filter by model (wildcards allowed)
    [double]$MonthlyBudgetUsd = -1, # Override the budget setting for this run
    [string]$ExportCsv              # Also save the calls in the period to this CSV file
)

# ── SETTINGS ─────────────────────────────────────────────────
$UsageLogFile  = 'Claude-Usage-API.csv'  # Same as UsageLogFile in Invoke-Claude-API-01.ps1:
                                         # a name in this folder, or a full path
$MonthlyBudget = 5.00                    # USD per calendar month (0 = no budget)
$WeekStartsOn  = 'Sunday'                # 'Sunday' or 'Monday', for ThisWeek / LastWeek
$TopCount      = 5                       # Rows in the Top and recent-failures lists

# ── HELPERS ───────────────────────────────────────────────────
$Inv = [Globalization.CultureInfo]::InvariantCulture

# The log stores numbers with a dot for decimals, whatever this computer's regional settings
function ConvertTo-Number {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 0.0 }
    [double]::Parse($Value, [Globalization.NumberStyles]::Float, $Inv)
}

# Small amounts get more decimals so they don't all show as $0.00
function Format-Usd {
    param([double]$Value)
    if ($Value -ne 0 -and [math]::Abs($Value) -lt 0.01) { '$' + $Value.ToString('N6') } else { '$' + $Value.ToString('N2') }
}

function Format-Pct {
    param([double]$Part, [double]$Whole)
    if ($Whole -eq 0) { return '-' }
    ($Part / $Whole).ToString('P1')
}

function Write-Section {
    param([string]$Title)
    Write-Host ("`n── $Title " + ('─' * [math]::Max(3, 52 - $Title.Length))) -ForegroundColor Yellow
}

function Show-Table {
    param($Rows)
    Write-Host ((@($Rows) | Format-Table -AutoSize | Out-String -Width 220).Trim())
}

function Show-Line {
    param([string]$Name, [string]$Value, [string]$Color = 'Gray')
    Write-Host ('{0,-22}: {1}' -f $Name, $Value) -ForegroundColor $Color
}

# Calls, failures, tokens and cost for each group, most expensive first
function Get-GroupStats {
    param($Rows, [string]$By, [string]$Heading)
    $GrandCost = ($Rows | Measure-Object -Property Cost -Sum).Sum
    $Rows | Group-Object -Property $By | ForEach-Object {
        $Ok   = @($_.Group | Where-Object { $_.Status -eq 'Success' })
        $Cost = ($_.Group | Measure-Object -Property Cost -Sum).Sum
        [pscustomobject][ordered]@{
            $Heading     = $_.Name
            Calls        = $_.Count
            Failed       = $_.Count - $Ok.Count
            Tokens       = [long]($_.Group | Measure-Object -Property Total -Sum).Sum
            'Est. cost'  = Format-Usd $Cost
            Share        = Format-Pct $Cost $GrandCost
            'Avg / call' = Format-Usd ($Cost / [math]::Max(1, $Ok.Count))
            SortKey      = $Cost
        }
    } | Sort-Object SortKey -Descending | Select-Object -Property * -ExcludeProperty SortKey
}

# Accept a list (Summary, Budget) or one comma-separated string ('Summary,Budget'), as
# other programs calling through pwsh -File pass it that way
$Sections = 'Summary', 'Budget', 'Daily', 'Models', 'Callers', 'Labels', 'Top', 'Failures', 'All'
$Report   = @($Report | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
$Unknown  = @($Report | Where-Object { $Sections -notcontains $_ })
if ($Unknown.Count -or $Report.Count -eq 0) {
    Write-Host "Unknown -Report section: $($Unknown -join ', ')" -ForegroundColor Red
    Write-Host "  Use one or more of: $($Sections -join ', ')" -ForegroundColor DarkGray
    exit 10
}
$Want = { param($Name) $Report -contains 'All' -or $Report -contains $Name }

# ── LOAD THE LOG ──────────────────────────────────────────────
$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogPath = if ([IO.Path]::IsPathRooted($UsageLogFile)) { $UsageLogFile } else { Join-Path $BaseDir $UsageLogFile }

if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
    Write-Host 'No usage log found yet.' -ForegroundColor Yellow
    Write-Host "  Looked for : $LogPath" -ForegroundColor DarkGray
    Write-Host '  It is created by Invoke-Claude-API-01.ps1 after its first API call.' -ForegroundColor DarkGray
    Write-Host '  If it lives elsewhere, set $UsageLogFile in SETTINGS.' -ForegroundColor DarkGray
    exit 10
}

$Skipped = 0
$All = foreach ($R in (Import-Csv -LiteralPath $LogPath -Encoding UTF8)) {
    try {
        $When = [datetimeoffset]::Parse($R.Timestamp, $Inv).LocalDateTime
        [pscustomobject]@{
            When      = $When
            Day       = $When.Date
            Status    = $R.Status
            Model     = $R.Model
            Label     = $(if ($R.Label) { $R.Label } else { '(none)' })
            Input     = [long](ConvertTo-Number $R.InputTokens)
            Output    = [long](ConvertTo-Number $R.OutputTokens)
            Total     = [long](ConvertTo-Number $R.TotalTokens)
            Cost      = ConvertTo-Number $R.CostUsd
            Unpriced  = ($R.Status -eq 'Success' -and $R.PriceTier -eq 'unpriced')
            Elapsed   = ConvertTo-Number $R.ElapsedSeconds
            Reason    = $R.Reason
            Http      = $R.HttpStatus
            RequestId = $R.RequestId
            MessageId = $R.MessageId
            Caller    = $(if ($R.Caller -and $R.Caller -ne 'interactive console') { Split-Path -Leaf $R.Caller } else { 'interactive console' })
            Mode      = $R.Mode
        }
    } catch {
        $Skipped++
    }
}
$All = @($All)

# ── PERIOD AND FILTERS ────────────────────────────────────────
$Now        = Get-Date
$Today      = $Now.Date
$MonthStart = $Today.AddDays(1 - $Today.Day)
$WeekStart  = $Today.AddDays(-((7 + [int]$Today.DayOfWeek - [int][DayOfWeek]$WeekStartsOn) % 7))

$Start, $End = switch ($Period) {
    'Today'      { $Today,                  $Today.AddDays(1) }
    'Yesterday'  { $Today.AddDays(-1),      $Today }
    'ThisWeek'   { $WeekStart,              $Today.AddDays(1) }
    'LastWeek'   { $WeekStart.AddDays(-7),  $WeekStart }
    'ThisMonth'  { $MonthStart,             $Today.AddDays(1) }
    'LastMonth'  { $MonthStart.AddMonths(-1), $MonthStart }
    'Last7Days'  { $Today.AddDays(-6),      $Today.AddDays(1) }
    'Last30Days' { $Today.AddDays(-29),     $Today.AddDays(1) }
    'ThisYear'   { $Today.AddDays(1 - $Today.DayOfYear), $Today.AddDays(1) }
    'All'        { [datetime]::MinValue,    [datetime]::MaxValue }
}
$PeriodName = $Period
if ($PSBoundParameters.ContainsKey('From')) { $Start = $From.Date;            $PeriodName = 'Custom' }
if ($PSBoundParameters.ContainsKey('To'))   { $End   = $To.Date.AddDays(1);   $PeriodName = 'Custom' }
if ($MonthlyBudgetUsd -ge 0) { $MonthlyBudget = $MonthlyBudgetUsd }

$Rows = @($All | Where-Object { $_.When -ge $Start -and $_.When -lt $End })
if ($Label) { $Rows = @($Rows | Where-Object { $_.Label -like $Label }) }
if ($Model) { $Rows = @($Rows | Where-Object { $_.Model -like $Model }) }

# Readable date range for the title
$RangeText = if ($Period -eq 'All' -and $PeriodName -eq 'All') {
    if ($All.Count) { '{0:yyyy-MM-dd} to {1:yyyy-MM-dd}' -f ($All | Measure-Object When -Minimum).Minimum, ($All | Measure-Object When -Maximum).Maximum }
    else { 'no calls yet' }
} else {
    '{0:yyyy-MM-dd} to {1:yyyy-MM-dd}' -f $Start, $End.AddDays(-1)
}
$Filters = @()
if ($Label) { $Filters += "label '$Label'" }
if ($Model) { $Filters += "model '$Model'" }

Write-Host "`nClaude usage report: $PeriodName ($RangeText)" -ForegroundColor Cyan
if ($Filters) { Write-Host "Filtered by $($Filters -join ', ')" -ForegroundColor DarkGray }
Write-Host "Log: $LogPath" -ForegroundColor DarkGray
if ($Skipped) { Write-Host "Note: $Skipped unreadable row(s) in the log were skipped." -ForegroundColor Yellow }

$Ok     = @($Rows | Where-Object { $_.Status -eq 'Success' })
$Failed = @($Rows | Where-Object { $_.Status -ne 'Success' })

# ── SUMMARY ───────────────────────────────────────────────────
if ((& $Want 'Summary')) {
    Write-Section 'Summary'
    if ($Rows.Count -eq 0) {
        Write-Host 'No API calls recorded in this period.'
    } else {
        $Cost  = ($Rows | Measure-Object Cost -Sum).Sum
        $Tok   = ($Rows | Measure-Object Total -Sum).Sum
        Show-Line 'Calls'               ("{0}  ({1} succeeded, {2} failed, {3} failure rate)" -f $Rows.Count, $Ok.Count, $Failed.Count, (Format-Pct $Failed.Count $Rows.Count))
        Show-Line 'Tokens'              ("{0:N0} total  ({1:N0} in, {2:N0} out)" -f $Tok, ($Rows | Measure-Object Input -Sum).Sum, ($Rows | Measure-Object Output -Sum).Sum)
        Show-Line 'Estimated cost'      (Format-Usd $Cost) Green
        if ($Ok.Count) {
            Show-Line 'Avg cost per call'   (Format-Usd ($Cost / $Ok.Count))
            Show-Line 'Avg tokens per call' ('{0:N0}' -f (($Ok | Measure-Object Total -Average).Average))
            Show-Line 'Avg response time'   ('{0:N2} s' -f (($Ok | Measure-Object Elapsed -Average).Average))
        }
        $Busiest = $Rows | Group-Object Day | Sort-Object Count -Descending | Select-Object -First 1
        Show-Line 'Busiest day'         ('{0:yyyy-MM-dd} ({1} calls)' -f [datetime]$Busiest.Group[0].Day, $Busiest.Count)
        $Unpriced = @($Ok | Where-Object { $_.Unpriced })
        if ($Unpriced.Count) {
            Write-Host "Note: $($Unpriced.Count) call(s) used a model with no price listed, so their cost counts as zero." -ForegroundColor Yellow
        }
    }
}

# ── BUDGET (calendar month to date, all calls) ────────────────
if ((& $Want 'Budget')) {
    Write-Section "Budget: $($Today.ToString('MMMM yyyy'))"
    $Month       = @($All | Where-Object { $_.When -ge $MonthStart -and $_.When -lt $Today.AddDays(1) })
    $Spent       = [double]($Month | Measure-Object Cost -Sum).Sum
    $DaysInMonth = [datetime]::DaysInMonth($Today.Year, $Today.Month)
    $Projected   = $Spent / $Today.Day * $DaysInMonth     # today counts as a full day

    Show-Line 'Spent so far'        ("{0}  ({1} calls, day {2} of {3})" -f (Format-Usd $Spent), $Month.Count, $Today.Day, $DaysInMonth)
    Show-Line 'Daily average'       (Format-Usd ($Spent / $Today.Day))
    Show-Line 'Projected month'     (Format-Usd $Projected)
    if ($MonthlyBudget -gt 0) {
        Show-Line 'Budget'              ("{0}  ({1} used, {2} left)" -f (Format-Usd $MonthlyBudget), (Format-Pct $Spent $MonthlyBudget), (Format-Usd ([math]::Max(0, $MonthlyBudget - $Spent))))
        if ($Spent -gt $MonthlyBudget) {
            Show-Line 'Status' ("Over budget by {0}" -f (Format-Usd ($Spent - $MonthlyBudget))) Red
        } elseif ($Projected -gt $MonthlyBudget) {
            Show-Line 'Status' ("On pace to exceed the budget by {0}" -f (Format-Usd ($Projected - $MonthlyBudget))) Yellow
        } else {
            Show-Line 'Status' 'On track' Green
        }
    } else {
        Show-Line 'Budget' 'none set ($MonthlyBudget = 0)' DarkGray
    }
    if ($Filters) { Write-Host '(The budget always counts every call, whatever the filters.)' -ForegroundColor DarkGray }
}

if ($Rows.Count -gt 0) {

    # ── DAILY ─────────────────────────────────────────────────
    if ((& $Want 'Daily')) {
        Write-Section 'Daily'
        $Running = 0.0
        Show-Table ($Rows | Group-Object Day | Sort-Object { [datetime]$_.Group[0].Day } | ForEach-Object {
            $DayCost  = ($_.Group | Measure-Object Cost -Sum).Sum
            $Running += $DayCost
            [pscustomobject][ordered]@{
                Day           = ([datetime]$_.Group[0].Day).ToString('yyyy-MM-dd ddd')
                Calls         = $_.Count
                Failed        = @($_.Group | Where-Object { $_.Status -ne 'Success' }).Count
                Tokens        = [long]($_.Group | Measure-Object Total -Sum).Sum
                'Est. cost'   = Format-Usd $DayCost
                'Running total' = Format-Usd $Running
            }
        })
    }

    # ── BY MODEL / CALLER / LABEL ─────────────────────────────
    if ((& $Want 'Models'))  { Write-Section 'By model';  Show-Table (Get-GroupStats $Rows 'Model'  'Model') }
    if ((& $Want 'Callers')) { Write-Section 'By caller'; Show-Table (Get-GroupStats $Rows 'Caller' 'Caller') }
    if ((& $Want 'Labels'))  { Write-Section 'By label';  Show-Table (Get-GroupStats $Rows 'Label'  'Label') }

    # ── TOP CALLS ─────────────────────────────────────────────
    if ((& $Want 'Top') -and $Ok.Count) {
        Write-Section "Most expensive calls (top $TopCount)"
        Show-Table ($Ok | Sort-Object Cost -Descending | Select-Object -First $TopCount | ForEach-Object {
            [pscustomobject][ordered]@{
                When = $_.When.ToString('yyyy-MM-dd HH:mm'); Model = $_.Model; Label = $_.Label
                'Tokens in' = $_.Input; 'Tokens out' = $_.Output; 'Est. cost' = Format-Usd $_.Cost; Caller = $_.Caller
            }
        })
        Write-Section "Slowest calls (top $TopCount)"
        Show-Table ($Ok | Sort-Object Elapsed -Descending | Select-Object -First $TopCount | ForEach-Object {
            [pscustomobject][ordered]@{
                When = $_.When.ToString('yyyy-MM-dd HH:mm'); Model = $_.Model; Label = $_.Label
                Seconds = $_.Elapsed.ToString('N2'); Tokens = $_.Total; Caller = $_.Caller
            }
        })
    }

    # ── FAILURES ──────────────────────────────────────────────
    if ((& $Want 'Failures')) {
        Write-Section 'Failures'
        if ($Failed.Count -eq 0) {
            Write-Host 'No failed calls in this period.' -ForegroundColor Green
        } else {
            Show-Table ($Failed | Group-Object Reason | Sort-Object Count -Descending | ForEach-Object {
                [pscustomobject][ordered]@{
                    Reason      = $(if ($_.Name) { $_.Name } else { '(unknown)' })
                    Count       = $_.Count
                    'HTTP codes' = (($_.Group | ForEach-Object { $_.Http } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
                    'Last seen' = (($_.Group | Measure-Object When -Maximum).Maximum).ToString('yyyy-MM-dd HH:mm')
                }
            })
            Write-Host "`nMost recent:" -ForegroundColor DarkGray
            Show-Table ($Failed | Sort-Object When -Descending | Select-Object -First $TopCount | ForEach-Object {
                [pscustomobject][ordered]@{
                    When = $_.When.ToString('yyyy-MM-dd HH:mm'); Reason = $_.Reason; HTTP = $_.Http
                    'Request ID' = $_.RequestId; Caller = $_.Caller
                }
            })
            Write-Host 'Details for each failure are in Claude-Logs-API.txt (search for the request ID).' -ForegroundColor DarkGray
        }
    }
}

# ── EXPORT ────────────────────────────────────────────────────
if ($ExportCsv) {
    try {
        $Rows | Select-Object @{ n = 'When'; e = { $_.When.ToString('yyyy-MM-dd HH:mm:ss') } }, Status, Model, Label,
                              Input, Output, Total, Cost, Elapsed, Reason, Http, MessageId, RequestId, Caller, Mode |
            Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-Host "`nSaved $($Rows.Count) call(s) to $ExportCsv" -ForegroundColor Green
    } catch {
        Write-Host "`nCouldn't save $ExportCsv : $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Write-Host "`nEstimates only. Actual charges: Claude Console > Billing." -ForegroundColor DarkGray
exit 0
