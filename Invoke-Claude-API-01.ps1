#Requires -Version 5.1
<#
============================================================
 Invoke-Claude: Anthropic API call, key held in KeePass
============================================================

 PURPOSE
 Sends a prompt to Anthropic's Messages API using an API key
 stored in KeePass. No passwords or keys are stored in this file,
 printed, written to disk, or returned to the caller.

 THREE WAYS TO USE IT

  1. RUN IT AS A SCRIPT (a person at the keyboard)
       .\Invoke-Claude-API-01.ps1                      # sends the test prompt
       .\Invoke-Claude-API-01.ps1 -Prompt "Hello"
     Prints the reply and usage details, and ends with an exit code.

  2. USE IT AS A FUNCTION (from other PowerShell scripts)
       . .\Invoke-Claude-API-01.ps1                    # note the dot and space
       $R = Invoke-Claude -Prompt "Hello"
       $R.Text; $R.TotalTokens
     Returns an object (see RETURNED OBJECT). Failures are thrown as
     errors you can catch; $_.Exception.Data.Reason names the problem
     and $_.Exception.Data.ExitCode gives its number.
       "One", "Two" | Invoke-Claude             # several prompts, one unlock
       Invoke-Claude "Hello" -Label "nightly summary"   # label for usage reports

  3. CALL IT FROM ANOTHER PROGRAM (Python, C#, batch, ...)
       pwsh -NoProfile -File Invoke-Claude-API-01.ps1 -Prompt "Hello" -Json
     Standard output carries exactly one JSON object; status messages
     and the password prompt go to standard error. Check the exit code.

 THE KEEPASS MASTER PASSWORD
  It is asked for on every run or call, and discarded straight
  after the vault is opened. The API key is never kept between calls.
  A caller that already has the password can supply it instead:
    - PowerShell:     Invoke-Claude -MasterPassword $SecureString
    - Other programs: -MasterPasswordFromStdin   (write the password
                      as the first line of standard input; recommended)
                      -MasterPasswordEnv NAME     (read from environment
                      variable NAME, which is then cleared)
  There is deliberately no way to pass it as a plain command-line
  argument: other programs on the computer can read those.

 RETURNED OBJECT (function) / JSON FIELDS (-Json)
  Text, Model, StopReason, Truncated, InputTokens, OutputTokens,
  CacheWriteTokens, CacheReadTokens, TotalTokens, EstimatedCostUsd,
  InputRate, OutputRate, PriceTier, Label, Id, ElapsedSeconds,
  Timestamp (UTC), Usage (raw).
  JSON adds ok = true, or on failure ok = false and an error object:
  reason, exitCode, message, details, httpStatus, requestId, logFile.

 USAGE LOG
  Every API call, successful or failed, adds one row to
  Claude-Usage-API.csv in the working folder (see UsageLog settings):
  time, status, model, label, token counts, estimated cost, response
  time, stop reason, failure reason, HTTP status, message/request IDs,
  calling script, mode, user and computer. Failures before the API is
  reached (wrong password, missing entry) aren't calls, so they appear
  in the error log only. Prompt and reply text are never recorded.
  Costs are estimates from PRICES; Anthropic's invoice is the final word.
  Get-ClaudeUsage-Report01.ps1 turns this file into reports.

 ERROR LOG
  Every error, in every mode, is appended to Claude-Logs-API.txt in
  the working folder (see ErrorLog settings). Each entry has the time,
  reason, exit code, message, details, HTTP status and request ID when
  there is one, and context: mode, model, calling script, PowerShell
  version, user and computer. Passwords and keys are never written;
  anything shaped like an API key is masked as a safety net.
  If the working folder can't be used, the log goes to the temp folder.

 EXIT CODES (script and -Json)
    0   Success
    1   Unexpected error
    10  A setting or parameter is invalid, or the working folder is missing
    11  Required module declined, failed to install, or won't load
    12  The chosen TLS version isn't available or failed its check
    20  KeePass file not found, empty, invalid, or access denied
    21  No master password given, or it was not accepted
    22  API key entry not found, or its key is empty
    30  API rejected the request (bad setting or model name)
    31  API key rejected
    32  Account out of credits
    33  Rate limited, overloaded, or server error: try again later
    34  No reply from the API: timeout, DNS, TLS or connection

 SECURITY NOTES
  - The master password is only ever held as a SecureString.
  - The API key exists in plain text only briefly, inside the call.
  - The functions live in a private module, so their internal
    variables aren't visible as ordinary variables to the caller.
  - TLS: on Windows PowerShell 5.1 the chosen version is applied
    only for the duration of each request, then the previous
    process-wide setting is restored.
  - Limits: code running in the same PowerShell session could still
    reach module internals, and .NET can't wipe plain-text strings
    from memory. On Linux/macOS a SecureString is only obscured,
    not encrypted.

 REQUIREMENTS
  - Windows PowerShell 5.1 or PowerShell 7+
  - PoshKeePass module (offered for install when run interactively)
  - root.kdbx in the working folder
============================================================
#>
[CmdletBinding()]
param(
    # Variable names are prefixed so that dot-sourcing this file
    # can't overwrite a caller's own $Prompt, $Model, and so on.
    [Parameter(Position = 0)][Alias('Prompt')]      [string]$ClaudePrompt,
    [Alias('Model')]                                 [string]$ClaudeModel,
    [Alias('MaxTokens')]                             [int]$ClaudeMaxTokens,
    [Alias('Temperature')]                           [Nullable[double]]$ClaudeTemperature,
    [Alias('System')]                                [string]$ClaudeSystem,
    [Alias('Label')]                                 [string]$ClaudeLabel,
    [Alias('Json')]                                  [switch]$ClaudeJson,
    [Alias('MasterPasswordFromStdin')]               [switch]$ClaudePwdStdin,
    [Alias('MasterPasswordEnv')]                     [string]$ClaudePwdEnv
)

# ── SETTINGS ─────────────────────────────────────────────────
# Defaults for every call. Script and function parameters override
# the request settings (Model, MaxTokens, Temperature, System, Prompt).

$ClaudeConfig = [ordered]@{

    # ·· General ··
    # $PSScriptRoot is this file's folder. If the code is pasted into a console
    # it is empty, so the current folder is used. To pin a folder, use e.g.
    #   WorkingDir = 'C:\Path\To\Folder'
    WorkingDir          = $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path })
    RequiredModules     = @('PoshKeePass')  # PowerShell modules checked before opening KeePass
    AuthPauseSeconds    = 2                 # Pause after "Authenticated." in script mode (0 = none)

    # ·· Error log ··
    ErrorLogEnabled     = $true             # Record every error (all modes) in the log file
    ErrorLogFile        = 'Claude-Logs-API.txt'  # In WorkingDir, or a full path like 'C:\Logs\Claude-Logs-API.txt'
    ErrorLogMaxKB       = 1024              # When the log passes this size, it's renamed to .old and a new one started

    # ·· Usage log (one row per API call; read by Get-ClaudeUsage-Report01.ps1) ··
    UsageLogEnabled     = $true
    UsageLogFile        = 'Claude-Usage-API.csv'  # In WorkingDir, or a full path

    # ·· Prices: USD per million tokens, as of October 2026 ··
    # Used for the cost estimates in results, the usage log and reports.
    # CacheWrite = 5-minute cache writes. A model with LongPromptOver charges
    # its Long rates when the prompt (input + cache tokens) is longer than that.
    # Update when prices change: https://platform.claude.com/docs/en/about-claude/pricing
    Prices              = @{
        'claude-haiku-5-5'  = @{ Input = 0.10; Output = 0.50; CacheWrite = 0.125; CacheRead = 0.01
                                 LongPromptOver = 100000
                                 Long = @{ Input = 0.50; Output = 2.50; CacheWrite = 0.625; CacheRead = 0.05 } }
        'claude-sonnet-5-5' = @{ Input = 2.00;  Output = 10.00; CacheWrite = 2.50;  CacheRead = 0.10 }
        'claude-opus-5-5'   = @{ Input = 4.00;  Output = 20.00; CacheWrite = 5.00;  CacheRead = 0.20 }
        'claude-fable-5-1'  = @{ Input = 10.00; Output = 50.00; CacheWrite = 12.50; CacheRead = 0.25 }
    }

    # ·· Security: TLS ··
    TlsVersion          = 'Tls12'           # 'Tls12', 'Tls13' (Windows 11 / Server 2022 or later),
                                            # or 'SystemDefault' (let Windows choose)
    VerifyTlsHandshake  = $true             # Test a real TLS connection once per session

    # ·· KeePass ··
    KeePassFileName     = 'root.kdbx'       # Database file, inside WorkingDir
    KeePassTitle        = 'Anthropic API'   # Entry title holding the API key
    KeePassUser         = 'ND_Testing'      # Entry username holding the API key
    KeePassProfileName  = 'KPProfile'       # Temporary PoshKeePass profile name (process ID is added)

    # ·· Anthropic API: connection ··
    AnthropicUri        = 'https://api.anthropic.com/v1/messages'
    AnthropicVersion    = '2023-06-01'      # Sent as the 'anthropic-version' header
    RequestTimeoutSec   = 60                # Give up if no reply within this many seconds

    # ·· Anthropic API: request defaults ··
    Model               = 'claude-haiku-5-5'
    MaxTokens           = 100               # Maximum length of the reply, in tokens
    Temperature         = $null             # 0.0 to 1.0, lower = more predictable. $null = API default
    System              = ''                # Optional system prompt. '' = none
    DefaultPrompt       = 'Tell me a small paragraph explaining how this Anthropic API works.'

    # ·· Script-mode display ($true = show, $false = hide) ··
    ShowModel           = $true             # Model that answered
    ShowInputTokens     = $true             # Tokens sent (your prompt)
    ShowOutputTokens    = $true             # Tokens received (the reply)
    ShowTotalTokens     = $true             # Input + output
    ShowStopReason      = $true             # Why the reply ended (end_turn, max_tokens, ...)
    ShowMessageId       = $false            # Message ID, useful when contacting support
    ShowElapsedTime     = $true             # How long the API call took
    ShowCost            = $true             # Estimated cost of the call
    ShowExitCode        = $true             # Exit code and its meaning, at the very end
}

# ── LIBRARY ───────────────────────────────────────────────────
# Loaded as a private in-memory module named ClaudeApi.
# Only Invoke-Claude is exported; everything else stays internal.

$ClaudeLib = {
    param($Config)

    $IsLegacyPS = $PSVersionTable.PSVersion.Major -lt 6   # Windows PowerShell 5.1 (.NET Framework)
    $OnWindows  = $IsLegacyPS -or $IsWindows

    # Module state
    $OutputMode   = 'Function'      # 'Function', 'Console' (script) or 'Json'; set by the entry point
    $TlsReady     = $false          # TLS checked this session
    $TlsEffective = $Config.TlsVersion
    $TlsParams    = @{}             # Extra Invoke-RestMethod parameters on PowerShell 7
    $DepsReady    = $false          # Modules checked this session

    $ExitCodes = @{
        Success = 0; Unexpected = 1; Settings = 10; Dependency = 11; Tls = 12
        DatabaseFile = 20; DatabaseAuth = 21; DatabaseEntry = 22
        ApiRequest = 30; ApiKey = 31; ApiCredits = 32; ApiRetryLater = 33; ApiNoResponse = 34
    }
    $ErrorCategories = @{
        Unexpected = 'NotSpecified'; Settings = 'InvalidArgument'; Dependency = 'NotInstalled'
        Tls = 'ConnectionError'; DatabaseFile = 'ObjectNotFound'; DatabaseAuth = 'AuthenticationError'
        DatabaseEntry = 'ObjectNotFound'; ApiRequest = 'InvalidArgument'; ApiKey = 'AuthenticationError'
        ApiCredits = 'QuotaExceeded'; ApiRetryLater = 'LimitsExceeded'; ApiNoResponse = 'ConnectionError'
    }

    # ·· Helpers ··

    # Status messages: coloured in script mode, standard error in JSON mode, -Verbose as a function
    function Write-Status {
        param([string]$Text, [string]$Color = 'Gray', [switch]$Warning)
        switch ($script:OutputMode) {
            'Console' { Write-Host $Text -ForegroundColor $(if ($Warning) { 'Yellow' } else { $Color }) }
            'Json'    { [Console]::Error.WriteLine($(if ($Warning) { "Warning: $($Text.Trim())" } else { $Text })) }
            default   { if ($Warning) { Write-Warning $Text.Trim() } else { Write-Verbose $Text.Trim() } }
        }
    }

    # Questions are only asked when a person is likely at the keyboard (not in JSON mode)
    function Test-CanAsk { $script:OutputMode -ne 'Json' }

    function Read-YesNo {
        param([string]$Question)
        (Read-Host "  $Question (Y/N)") -match '^(y|yes)$'
    }

    function Test-IsAdmin {
        $Id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal $Id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # An exception and all the exceptions nested inside it
    function Get-ExceptionChain {
        param([Exception]$Exception)
        $Ex = $Exception
        while ($Ex) { $Ex; $Ex = $Ex.InnerException }
    }

    # Mask anything shaped like an Anthropic API key (safety net for messages that echo it back)
    function Hide-Secret {
        param([string]$Text)
        $Text -replace 'sk-ant-[A-Za-z0-9_\-]{4,}', 'sk-ant-[MASKED]'
    }

    # Builds the error thrown for each kind of failure. Callers read
    # $_.Exception.Data: Reason, ExitCode, Details, HttpStatus, RequestId.
    function New-ClaudeError {
        param(
            [Parameter(Mandatory, Position = 0)][string]$Reason,
            [Parameter(Mandatory, Position = 1)][string]$Message,
            [string[]]$Details = @(),
            [int]$Status = 0,
            [string]$RequestId
        )
        $Ex = New-Object Exception (Hide-Secret $Message)
        $Ex.Data['Reason']   = $Reason
        $Ex.Data['ExitCode'] = $ExitCodes[$Reason]
        $Ex.Data['Details']  = [string[]]@($Details | ForEach-Object { Hide-Secret $_ })
        if ($Status)    { $Ex.Data['HttpStatus'] = $Status }
        if ($RequestId) { $Ex.Data['RequestId']  = $RequestId }
        New-Object Management.Automation.ErrorRecord $Ex, $Reason,
            ([Management.Automation.ErrorCategory]$ErrorCategories[$Reason]), $null
    }

    # Ask for the master password. Masked; never held as plain text.
    function Read-MasterPassword {
        $NoKeyboard = New-ClaudeError DatabaseAuth "Can't ask for the KeePass master password: input is redirected." -Details @(
            'Run it from a console window so the password can be typed,',
            'or supply it with -MasterPassword (PowerShell), -MasterPasswordFromStdin or -MasterPasswordEnv.')

        if ($script:OutputMode -ne 'Json') {
            # Read-Host asks through the PowerShell host. Editors such as PowerShell ISE and
            # VS Code have their own way of taking input and report the console as "redirected"
            # even though typing works, so only the plain console host is checked.
            if ($Host.Name -eq 'ConsoleHost' -and [Console]::IsInputRedirected) { throw $NoKeyboard }
            return (Read-Host "`nKeePass master password" -AsSecureString)
        }

        # JSON mode reads keys straight from the console (standard output is reserved for the
        # JSON), so a real console is needed here
        if ([Console]::IsInputRedirected) { throw $NoKeyboard }
        # Prompt on standard error
        [Console]::Error.Write('KeePass master password: ')
        $Secure = New-Object Security.SecureString
        while ($true) {
            $Key = [Console]::ReadKey($true)
            if ($Key.Key -eq 'Enter') { break }
            if ($Key.Key -eq 'Backspace') {
                if ($Secure.Length -gt 0) { $Secure.RemoveAt($Secure.Length - 1) }
                continue
            }
            if ($Key.KeyChar -ne [char]0) { $Secure.AppendChar($Key.KeyChar) }
        }
        [Console]::Error.WriteLine()
        $Secure.MakeReadOnly()
        $Secure
    }

    # Run a web request with the chosen TLS version. On Windows PowerShell 5.1 the
    # setting is process-wide, so the caller's previous setting is restored afterwards.
    function Invoke-WithTls {
        param([scriptblock]$Action)
        $Previous = $null
        if ($IsLegacyPS) {
            $Previous = [Net.ServicePointManager]::SecurityProtocol
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]$script:TlsEffective
        }
        try { & $Action }
        finally { if ($null -ne $Previous) { [Net.ServicePointManager]::SecurityProtocol = $Previous } }
    }

    # ·· TLS ··

    # Offer to drop from TLS 1.3 to TLS 1.2 for this session, or stop
    function Use-Tls12Fallback {
        param([string]$Why)
        if ((Test-CanAsk)) {
            Write-Status "  $Why" -Warning
            if (Read-YesNo 'Use TLS 1.2 for this session instead?') {
                $script:TlsEffective = 'Tls12'
                Write-Status "  Using TLS 1.2. Set TlsVersion = 'Tls12' in SETTINGS to make it permanent." DarkGray
                return
            }
        }
        throw (New-ClaudeError Tls $Why -Details @("Set TlsVersion = 'Tls12' in SETTINGS to use TLS 1.2."))
    }

    # Old .NET Framework without the needed TLS: offer PowerShell 7, or the .NET 4.8 download page
    function Invoke-TlsRuntimeFix {
        $Msg = "This Windows PowerShell runs on an old .NET Framework that can't use $script:TlsEffective."
        $Fix = @('Fix: install PowerShell 7 (no admin rights or restart; runs alongside 5.1),',
                 'or install .NET Framework 4.8 (admin rights and a restart).')
        if ((Test-CanAsk)) {
            Write-Status "  $Msg" Red
            $Fix | ForEach-Object { Write-Status "  $_" DarkGray }
            if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Read-YesNo 'Install PowerShell 7 now with winget?')) {
                winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
                if ($LASTEXITCODE -eq 0) {
                    throw (New-ClaudeError Tls 'PowerShell 7 is installed. Open a new window and run this with pwsh.' -Details @(
                        "pwsh -File `"$PSCommandPath`""))
                }
                throw (New-ClaudeError Tls "winget couldn't install PowerShell 7 (code $LASTEXITCODE)." -Details $Fix)
            }
            if (Read-YesNo 'Open the .NET Framework 4.8 download page?') {
                Start-Process 'https://dotnet.microsoft.com/download/dotnet-framework/net48'
            }
        }
        throw (New-ClaudeError Tls $Msg -Details $Fix)
    }

    # Connect, complete a TLS handshake, return the version negotiated. No data is sent.
    function Test-TlsHandshake {
        param([string]$HostName, [string]$Version, [bool]$CheckRevocation)
        $Tcp = $null; $Ssl = $null
        try {
            $Tcp = New-Object Net.Sockets.TcpClient
            if (-not $Tcp.ConnectAsync($HostName, 443).Wait(10000)) {
                throw (New-Object TimeoutException "Connecting to $HostName timed out.")
            }
            $Ssl = New-Object Net.Security.SslStream($Tcp.GetStream(), $false)
            $Ssl.ReadTimeout = 10000; $Ssl.WriteTimeout = 10000
            $Proto = if ($Version -eq 'SystemDefault') { [Security.Authentication.SslProtocols]::None }
                     else { [Security.Authentication.SslProtocols]$Version }
            # Checks the certificate too: fails if it isn't valid for the host or isn't trusted
            $Ssl.AuthenticateAsClient($HostName, $null, $Proto, $CheckRevocation)
            $Ssl.SslProtocol
        } finally {
            if ($Ssl) { $Ssl.Dispose() }
            if ($Tcp) { $Tcp.Dispose() }
        }
    }

    # Check the TLS setting once per session: valid, supported, not switched off, and working
    function Initialize-ClaudeTls {
        if ($script:TlsReady) { return }
        Write-Status "`nChecking TLS..." Cyan

        # 1. Valid setting? (also normalises spelling, e.g. 'tls12' -> 'Tls12')
        $Choices = 'Tls12', 'Tls13', 'SystemDefault'
        $Match = $Choices | Where-Object { $_ -eq $Config.TlsVersion }
        if (-not $Match) {
            throw (New-ClaudeError Settings "TlsVersion is '$($Config.TlsVersion)'. Use one of: $($Choices -join ', ').")
        }
        $script:TlsEffective = $Match

        # 2. Windows version supports TLS 1.3? (it can't be added by installing anything)
        if ($script:TlsEffective -eq 'Tls13' -and $OnWindows) {
            $Build = [Environment]::OSVersion.Version.Build
            if ($Build -lt 20348) {
                Use-Tls12Fallback ("TLS 1.3 needs Windows 11 or Windows Server 2022 or later. " +
                                   "This is Windows build $Build, and TLS 1.3 can't be added to it.")
            }
        }

        # 3. This PowerShell / .NET supports it?
        if ($IsLegacyPS) {
            $Supported = [enum]::GetNames([Net.SecurityProtocolType])
            if ($Supported -notcontains $script:TlsEffective) {
                if ($script:TlsEffective -eq 'Tls13' -and $Supported -contains 'Tls12') {
                    Use-Tls12Fallback "This Windows PowerShell's .NET Framework doesn't support TLS 1.3 (it needs .NET Framework 4.8)."
                } else {
                    Invoke-TlsRuntimeFix
                }
            }
        } elseif ($script:TlsEffective -ne 'SystemDefault') {
            $ParamType = (Get-Command Invoke-RestMethod).Parameters['SslProtocol'].ParameterType
            $Supported = if ($ParamType) { [enum]::GetNames($ParamType) } else { @() }
            if ($Supported -notcontains $script:TlsEffective) {
                Use-Tls12Fallback "This PowerShell $($PSVersionTable.PSVersion) can't request TLS 1.3. Updating PowerShell 7 would add it."
            }
        }

        # 4. Switched off in Windows? (Schannel registry, client side)
        if ($OnWindows -and $script:TlsEffective -ne 'SystemDefault') {
            $ProtoName = @{ Tls12 = 'TLS 1.2'; Tls13 = 'TLS 1.3' }[$script:TlsEffective]
            $RegKey    = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$ProtoName\Client"
            $Reg       = Get-ItemProperty -LiteralPath $RegKey -ErrorAction SilentlyContinue

            if ($Reg -and $Reg.PSObject.Properties.Name -contains 'Enabled' -and $Reg.Enabled -eq 0) {
                $Msg     = "$ProtoName is switched off for outgoing connections in Windows (Schannel setting)."
                $Details = @("Registry: $RegKey  (Enabled = 0)")
                if ((Test-CanAsk)) {
                    Write-Status "  $Msg" Red
                    if (-not (Test-IsAdmin)) {
                        $Details += 'Switching it back on needs admin rights. Run PowerShell as administrator, then try again.'
                    } else {
                        Write-Status '  If your organisation manages this setting, policy may switch it off again.' DarkGray
                        if (Read-YesNo "Switch $ProtoName back on for outgoing connections? (Windows security setting; restart needed)") {
                            Set-ItemProperty -LiteralPath $RegKey -Name Enabled           -Value 1 -Type DWord
                            Set-ItemProperty -LiteralPath $RegKey -Name DisabledByDefault -Value 0 -Type DWord
                            $Msg = "$ProtoName has been switched back on. Restart Windows, then try again."
                            $Details = @()
                        }
                    }
                } else {
                    $Details += 'An administrator can switch it back on (restart needed).'
                }
                throw (New-ClaudeError Tls $Msg -Details $Details)
            }
        }

        # 5. Parameters for PowerShell 7 requests (5.1 is handled per request by Invoke-WithTls)
        $script:TlsParams = @{}
        if (-not $IsLegacyPS -and $script:TlsEffective -ne 'SystemDefault') {
            $script:TlsParams.SslProtocol = $script:TlsEffective
        }
        Write-Status "  TLS setting : $script:TlsEffective (supported here)" Green

        # 6. Prove it with a real TLS connection to the API host
        if ($Config.VerifyTlsHandshake) {
            $ApiHost = ([Uri]$Config.AnthropicUri).Host
            try {
                try {
                    $Negotiated = Test-TlsHandshake -HostName $ApiHost -Version $script:TlsEffective -CheckRevocation $true
                    Write-Status "  TLS verified: $Negotiated connection to $ApiHost, certificate trusted." Green
                } catch {
                    # Revocation lists can be unreachable (offline, firewall). The certificate is
                    # otherwise checked, so retry without that one check rather than fail outright.
                    if ($_.Exception.ToString() -notmatch 'Revocation') { throw }
                    $Negotiated = Test-TlsHandshake -HostName $ApiHost -Version $script:TlsEffective -CheckRevocation $false
                    Write-Status "  TLS verified: $Negotiated connection to $ApiHost, certificate trusted." Green
                    Write-Status "  (Its revocation status couldn't be checked from here; everything else passed.)" DarkGray
                }
            } catch {
                $Chain = @(Get-ExceptionChain $_.Exception)
                $Inner = $Chain[-1].Message
                if (($Chain | ForEach-Object { $_.GetType().Name }) -contains 'AuthenticationException') {
                    throw (New-ClaudeError Tls "TLS check failed: $ApiHost would not complete a $script:TlsEffective connection, or its certificate wasn't trusted." -Details @(
                        'A proxy or antivirus inspecting traffic can cause this.', "Detail : $Inner"))
                }
                Write-Status "  Couldn't run the TLS test (a direct connection was blocked, e.g. by a proxy)." -Warning
                Write-Status "  Continuing: requests will still use $script:TlsEffective. Detail: $Inner" DarkGray
            }
        }
        $script:TlsReady = $true
    }

    # ·· Dependencies ··

    function Assert-ClaudeDependencies {
        if ($script:DepsReady) { return }
        Write-Status "`nChecking dependencies..." Cyan

        foreach ($ModuleName in $Config.RequiredModules) {
            if (Get-Module -ListAvailable -Name $ModuleName) {
                Write-Status "  $ModuleName : installed" Green
            } else {
                $Manual = "Install it with: Install-Module $ModuleName -Scope CurrentUser"
                if (-not (Test-CanAsk)) {
                    throw (New-ClaudeError Dependency "$ModuleName isn't installed." -Details @($Manual))
                }
                Write-Status "  $ModuleName : not installed" -Warning
                if (-not (Read-YesNo "Install $ModuleName from the PowerShell Gallery for your user account?")) {
                    throw (New-ClaudeError Dependency "$ModuleName is required." -Details @($Manual))
                }
                try {
                    # CurrentUser scope: no admin rights needed. PowerShell may also ask to install
                    # the NuGet provider or to trust the PSGallery repository: answer Yes to both.
                    Invoke-WithTls { Install-Module -Name $ModuleName -Scope CurrentUser -Repository PSGallery -ErrorAction Stop }
                    Write-Status "  $ModuleName : installed successfully" Green
                } catch {
                    throw (New-ClaudeError Dependency "Failed to install $ModuleName." -Details @($_.Exception.Message, $Manual))
                }
            }
            try {
                Import-Module $ModuleName -ErrorAction Stop
            } catch {
                throw (New-ClaudeError Dependency "$ModuleName is installed but could not be loaded." -Details @($_.Exception.Message))
            }
        }
        $script:DepsReady = $true
    }

    # ·· KeePass ··

    # Open the vault and return the API key (plain text, for the duration of one call)
    function Get-KeyFromVault {
        param([Security.SecureString]$MasterPassword)

        $WorkingDir = $Config.WorkingDir
        if ([string]::IsNullOrWhiteSpace($WorkingDir)) {
            throw (New-ClaudeError Settings 'The working folder (WorkingDir) is empty.' -Details @(
                "Set it in SETTINGS, e.g. WorkingDir = 'C:\Path\To\Folder'"))
        }
        if (-not (Test-Path -LiteralPath $WorkingDir -PathType Container)) {
            throw (New-ClaudeError Settings "The working folder doesn't exist: $WorkingDir")
        }

        Assert-ClaudeDependencies

        $Db = Join-Path $WorkingDir $Config.KeePassFileName
        if (-not (Test-Path -LiteralPath $Db -PathType Leaf)) {
            throw (New-ClaudeError DatabaseFile 'KeePass database not found.' -Details @(
                "Looked for : $Db", 'Check KeePassFileName and WorkingDir in SETTINGS.'))
        }
        if ((Get-Item -LiteralPath $Db).Length -eq 0) {
            throw (New-ClaudeError DatabaseFile "The KeePass database file is empty (0 bytes): $Db")
        }

        # Use the caller's password if given; otherwise ask. Only our own copy is disposed here.
        $OwnPassword = -not $MasterPassword
        if ($OwnPassword) { $MasterPassword = Read-MasterPassword }
        if (-not $MasterPassword -or $MasterPassword.Length -eq 0) {
            if ($OwnPassword -and $MasterPassword) { $MasterPassword.Dispose() }
            throw (New-ClaudeError DatabaseAuth 'No master password entered.')
        }

        Write-Status "`nOpening KeePass database..." Cyan

        # Process ID in the profile name keeps simultaneous runs from clashing
        $ProfileName = "$($Config.KeePassProfileName)_$PID"
        try { Remove-KeePassDatabaseConfiguration -DatabaseProfileName $ProfileName `
              -Confirm:$false -ErrorAction SilentlyContinue 6>$null } catch {}

        $Found = @(); $OtherUsers = @(); $Unlocked = $false
        try {
            try {
                New-KeePassDatabaseConfiguration -DatabaseProfileName $ProfileName `
                    -DatabasePath $Db -UseMasterKey -ErrorAction Stop 6>$null | Out-Null

                # Unlocks the vault: if this returns without an error, the password was accepted
                $Found = @(Get-KeePassEntry -DatabaseProfileName $ProfileName -MasterKey $MasterPassword `
                               -Title $Config.KeePassTitle -UserName $Config.KeePassUser `
                               -AsPlainText -ErrorAction Stop 6>$null)
                $Unlocked = $true

                # No exact match: see whether the title exists with another username.
                # No -AsPlainText here, so those entries' passwords stay protected;
                # only the usernames are read.
                if ($Found.Count -eq 0) {
                    $OtherUsers = @(Get-KeePassEntry -DatabaseProfileName $ProfileName -MasterKey $MasterPassword `
                                        -Title $Config.KeePassTitle -ErrorAction Stop 6>$null |
                                    ForEach-Object {
                                        if ($_.PSObject.Properties['UserName']) { "$($_.UserName)" }
                                        elseif ($_.Strings) { $_.Strings.ReadSafe('UserName') }   # raw KeePass entry
                                    } | Where-Object { $_ })
                }
            } catch {
                $Chain     = @(Get-ExceptionChain $_.Exception)
                $TypeNames = $Chain | ForEach-Object { $_.GetType().Name }
                $AllMsgs   = ($Chain | ForEach-Object { $_.Message }) -join ' | '
                $Details   = @("Database : $Db", "Detail   : $($_.Exception.Message)")

                if ($TypeNames -contains 'InvalidCompositeKeyException' -or $AllMsgs -match 'composite key') {
                    throw (New-ClaudeError DatabaseAuth 'Could not open the KeePass database: the master password was not accepted.' -Details (@(
                        "If this database also needs a key file or Windows account login, that isn't supported yet.") + $Details))
                }
                if ($AllMsgs -match 'signature|format|not a KeePass|corrupt|unexpected end') {
                    throw (New-ClaudeError DatabaseFile "The file isn't a readable KeePass database (wrong file, damaged, or unsupported format)." -Details $Details)
                }
                if ($AllMsgs -match 'denied|unauthorized|being used by another process') {
                    throw (New-ClaudeError DatabaseFile 'Windows refused access to the KeePass database file.' -Details (@(
                        'Check file permissions, or whether another program has it locked.') + $Details))
                }
                if (-not $Unlocked -and $AllMsgs -match 'profile|configuration') {
                    throw (New-ClaudeError Dependency "Could not register the temporary PoshKeePass profile '$ProfileName'." -Details $Details)
                }
                throw (New-ClaudeError Unexpected 'Could not open the KeePass database for an unexpected reason.' -Details $Details)
            }
        } finally {
            # Always remove the profile, and discard the password if we asked for it
            try { Remove-KeePassDatabaseConfiguration -DatabaseProfileName $ProfileName `
                  -Confirm:$false -ErrorAction SilentlyContinue 6>$null } catch {}
            if ($OwnPassword) { $MasterPassword.Dispose() }
        }

        Write-Status "Authenticated. Vault unlocked: $($Config.KeePassFileName)" Green
        if ($script:OutputMode -eq 'Console' -and $Config.AuthPauseSeconds -gt 0) {
            Start-Sleep -Seconds $Config.AuthPauseSeconds
        }

        if ($Found.Count -eq 0) {
            $Details = if ($OtherUsers.Count -gt 0) {
                @("An entry titled '$($Config.KeePassTitle)' exists, but not with username '$($Config.KeePassUser)'.",
                  "Usernames under that title: $(($OtherUsers | Sort-Object -Unique) -join ', ')")
            } else {
                @("No entry titled '$($Config.KeePassTitle)' in the database.")
            }
            throw (New-ClaudeError DatabaseEntry 'KeePass entry not found.' -Details ($Details + @(
                'Check KeePassTitle and KeePassUser in SETTINGS (they must match exactly).')))
        }
        if ($Found.Count -gt 1) {
            Write-Status "$($Found.Count) entries match '$($Config.KeePassTitle)' / '$($Config.KeePassUser)'. Using the first one." -Warning
        }

        # Trim stray spaces or line breaks picked up when the key was pasted into KeePass
        $Key = "$($Found[0].Password)".Trim()
        $Found = $null
        if ([string]::IsNullOrWhiteSpace($Key)) {
            throw (New-ClaudeError DatabaseEntry 'The KeePass entry was found, but its password field (the API key) is empty.')
        }
        if ($Key -notlike 'sk-ant-*') {
            Write-Status "The stored key doesn't start with 'sk-ant-', so it may not be an Anthropic API key." -Warning
        }
        Write-Status 'API key loaded successfully.' Green
        $Key
    }

    # ·· API ··

    # Turn a failed Invoke-RestMethod into a specific error
    function ConvertTo-ApiError {
        param($Err, [double]$Elapsed, [string]$Model)
        $Resp = $Err.Exception.Response
        $Elapsed = [math]::Round($Elapsed, 2)

        $Status = 0
        if ($Resp) { try { $Status = [int]$Resp.StatusCode } catch {} }

        # Error body: PS 7 puts it in ErrorDetails; PS 5.1 sometimes only in the response stream
        $Raw = $Err.ErrorDetails.Message
        if (-not $Raw -and $Resp -and $Resp.PSObject.Methods.Name -contains 'GetResponseStream') {
            try { $Raw = (New-Object IO.StreamReader($Resp.GetResponseStream())).ReadToEnd() } catch {}
        }
        $ErrorBody = $null
        if ($Raw) { try { $ErrorBody = $Raw | ConvertFrom-Json -ErrorAction Stop } catch {} }

        $ErrType = $null
        $ErrMsg  = $Err.Exception.Message
        if ($ErrorBody -and $ErrorBody.error) { $ErrType = $ErrorBody.error.type; $ErrMsg = $ErrorBody.error.message }

        # Request ID from the response headers (quote it when contacting Anthropic support)
        $RequestId = $null
        if ($Resp) {
            try {
                if ($Resp.Headers -is [Net.WebHeaderCollection]) { $RequestId = $Resp.Headers['request-id'] }
                else { $RequestId = @($Resp.Headers.GetValues('request-id'))[0] }
            } catch {}
        }

        if ($Status) {
            $Explain, $Reason = switch ($Status) {
                400 {
                    if ($ErrMsg -match 'credit balance') {
                        'Your account is out of credits. Add credits in the Claude Console under Billing.', 'ApiCredits'
                    } else {
                        'The request was rejected as invalid. Check the model, max tokens and temperature.', 'ApiRequest'
                    }
                }
                401 { 'The API key was rejected. It may be mistyped, revoked, or from a different organization.', 'ApiKey' }
                403 { "The API key doesn't have permission for this request.", 'ApiKey' }
                404 { "Not found. Usually the model name is wrong or no longer offered: $Model", 'ApiRequest' }
                413 { 'The request is too large.', 'ApiRequest' }
                429 { 'Rate limit reached. Wait a moment and try again.', 'ApiRetryLater' }
                500 { "Anthropic's servers had an internal error. Try again shortly.", 'ApiRetryLater' }
                529 { 'The Anthropic API is temporarily overloaded. Try again shortly.', 'ApiRetryLater' }
                default {
                    if ($Status -ge 500) { 'Server-side error at Anthropic. Try again shortly.', 'ApiRetryLater' }
                    else                 { 'Unexpected error response from the API.', 'ApiRequest' }
                }
            }
            $Details = @()
            if ($ErrType)   { $Details += "Type       : $ErrType" }
            $Details += "Message    : $ErrMsg"
            if ($RequestId) { $Details += "Request ID : $RequestId" }
            $Details += "Elapsed    : $Elapsed s"
            return (New-ClaudeError $Reason "API call failed (HTTP $Status). $Explain" -Details $Details `
                        -Status $Status -RequestId $RequestId)
        }

        # No HTTP response at all: the problem is between this computer and the API
        $AllMsgs = (Get-ExceptionChain $Err.Exception | ForEach-Object { $_.Message }) -join ' | '
        $Explain =
            if     ($AllMsgs -match 'timed out|timeout|canceled|cancelled') {
                "No reply within $($Config.RequestTimeoutSec) seconds (timed out). Try again, or raise RequestTimeoutSec." }
            elseif ($AllMsgs -match 'SSL|TLS|secure channel|trust relationship|certificate') {
                'A secure (TLS) connection could not be set up. A proxy, antivirus or outdated system may be interfering.' }
            elseif ($AllMsgs -match 'No such host|could not be resolved|name resolution|nodename|remote name') {
                "Couldn't look up the API address. Check your internet connection or DNS." }
            elseif ($AllMsgs -match 'refused|unable to connect|unreachable|connection') {
                'Could not connect to the API. Check internet access, VPN, firewall or proxy settings.' }
            else {
                'The request failed before reaching the API.' }
        New-ClaudeError ApiNoResponse "API call failed: no response from the server. $Explain" -Details @(
            "Detail  : $($Err.Exception.Message)", "Elapsed : $Elapsed s")
    }

    # ·· Log files ··

    # Where a log goes: the name in WorkingDir, a full path, or the temp folder as a fallback
    function Get-LogPath {
        param([string]$Name)
        if ([IO.Path]::IsPathRooted($Name)) { return $Name }
        $Dir = $Config.WorkingDir
        if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir -PathType Container)) {
            $Dir = [IO.Path]::GetTempPath()
        }
        Join-Path $Dir $Name
    }

    # Append text, retrying briefly in case another run is writing at the same moment.
    # UTF-8 with a byte-order mark at the start of a new file, so Excel reads accents correctly.
    function Add-TextToFile {
        param([string]$Path, [string]$Text)
        $Utf8 = New-Object Text.UTF8Encoding $true
        for ($i = 1; $i -le 5; $i++) {
            try { [IO.File]::AppendAllText($Path, $Text, $Utf8); return }
            catch { if ($i -eq 5) { throw }; Start-Sleep -Milliseconds 100 }
        }
    }

    # ·· Prices and cost ··

    # Price entry for a model. The API may report a dated name, so match by prefix (longest first).
    function Get-ClaudePrice {
        param([string]$Model)
        $Key = $Config.Prices.Keys | Sort-Object Length -Descending |
               Where-Object { $Model -like "$_*" } | Select-Object -First 1
        if ($Key) { $Config.Prices[$Key] }
    }

    # Estimated cost in USD, with the rates and tier used. Cost is $null for a model with no price.
    function Get-ClaudeCost {
        param([string]$Model, [double]$InputTokens, [double]$OutputTokens,
              [double]$CacheWriteTokens, [double]$CacheReadTokens)
        $P = Get-ClaudePrice $Model
        if (-not $P) { return [pscustomobject]@{ Cost = $null; InputRate = $null; OutputRate = $null; Tier = 'unpriced' } }
        $Rates = $P; $Tier = 'standard'
        $PromptSize = $InputTokens + $CacheWriteTokens + $CacheReadTokens
        if ($P.LongPromptOver -and $P.Long -and $PromptSize -gt $P.LongPromptOver) { $Rates = $P.Long; $Tier = 'long-prompt' }
        $Cost = ($InputTokens * $Rates.Input + $OutputTokens * $Rates.Output +
                 $CacheWriteTokens * $Rates.CacheWrite + $CacheReadTokens * $Rates.CacheRead) / 1e6
        [pscustomobject]@{ Cost = $Cost; InputRate = $Rates.Input; OutputRate = $Rates.Output; Tier = $Tier }
    }

    # ·· Usage log ··

    $UsageColumns = 'Timestamp', 'Status', 'Model', 'Label', 'InputTokens', 'OutputTokens',
                    'CacheWriteTokens', 'CacheReadTokens', 'TotalTokens', 'CostUsd', 'PriceTier',
                    'ElapsedSeconds', 'StopReason', 'Reason', 'HttpStatus', 'MessageId', 'RequestId',
                    'Caller', 'Mode', 'User', 'Computer'

    # One CSV field: numbers in invariant format (always a dot for decimals), text quoted when needed
    function ConvertTo-CsvField {
        param($Value)
        if ($null -eq $Value) { return '' }
        $Inv = [Globalization.CultureInfo]::InvariantCulture
        if ($Value -is [double] -or $Value -is [decimal]) { return $Value.ToString('0.##########', $Inv) }
        if ($Value -is [ValueType]) { return [Convert]::ToString($Value, $Inv) }
        $S = "$Value"
        if ($S -match '[",\r\n]') { return '"' + ($S -replace '"', '""') + '"' }
        $S
    }

    # Add one API call to the usage log. Never throws: logging must not break the call.
    function Write-ClaudeUsageLog {
        param([hashtable]$Row)
        if (-not $Config.UsageLogEnabled) { return }
        try {
            $Row.Timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
            $Row.Mode      = @{ Function = 'Function'; Console = 'Script'; Json = 'Json' }[$script:OutputMode]
            $Row.User      = [Environment]::UserName
            $Row.Computer  = [Environment]::MachineName
            if (-not $Row.Caller) { $Row.Caller = 'interactive console' }

            $Path = Get-LogPath $Config.UsageLogFile
            $NL   = [Environment]::NewLine
            $Text = (($UsageColumns | ForEach-Object { ConvertTo-CsvField $Row[$_] }) -join ',') + $NL
            $Item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if (-not $Item -or $Item.Length -eq 0) { $Text = ($UsageColumns -join ',') + $NL + $Text }
            Add-TextToFile $Path (Hide-Secret $Text)
        } catch {
            Write-Status "Couldn't write to the usage log: $($_.Exception.Message)" -Warning
        }
    }

    # ·· Error log ··

    # Append one error to the log. Never throws: a logging problem must not hide the real error.
    function Write-ClaudeErrorLog {
        param([Management.Automation.ErrorRecord]$ErrorRecord, [string]$Model, [string]$Caller)
        if (-not $Config.ErrorLogEnabled -or -not $ErrorRecord) { return }
        $Ex = $ErrorRecord.Exception
        if ($Ex.Data['Logged']) { return }      # Already written (errors pass through several layers)
        try {
            $D      = $Ex.Data
            $Ours   = [bool]$D['Reason']
            $Reason = if ($Ours) { $D['Reason'] } else { 'Unexpected' }
            $Code   = if ($null -ne $D['ExitCode']) { $D['ExitCode'] } else { $ExitCodes.Unexpected }
            $Mode   = @{ Function = 'Function'; Console = 'Script'; Json = 'Json' }[$script:OutputMode]
            if (-not $Caller) { $Caller = 'interactive console' }
            if (-not $Model)  { $Model  = $Config.Model }

            $Lines = New-Object Collections.Generic.List[string]
            $Head  = '{0} | ERROR | {1} (exit {2})' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'), $Reason, $Code
            if ($D['HttpStatus']) { $Head += " | HTTP $($D['HttpStatus'])" }
            if ($D['RequestId'])  { $Head += " | Request $($D['RequestId'])" }
            $Lines.Add($Head)
            $Lines.Add("  Message : $($Ex.Message)")
            foreach ($L in @($D['Details'])) { if ($L) { $Lines.Add("      $L") } }
            if (-not $Ours) {
                $Lines.Add("  Type    : $($Ex.GetType().FullName)")
                if ($ErrorRecord.InvocationInfo) {
                    $Lines.Add("  Where   : line $($ErrorRecord.InvocationInfo.ScriptLineNumber): $("$($ErrorRecord.InvocationInfo.Line)".Trim())")
                }
            }
            $Lines.Add(("  Context : mode {0} | model {1} | caller {2} | PowerShell {3} | {4}@{5}" -f
                        $Mode, $Model, $Caller, $PSVersionTable.PSVersion, [Environment]::UserName, [Environment]::MachineName))

            # Safety net: mask anything shaped like an Anthropic key (covers unexpected errors too)
            $Text = Hide-Secret (($Lines -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine)

            $Path = Get-LogPath $Config.ErrorLogFile
            $Item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if ($Item -and $Item.Length -gt ($Config.ErrorLogMaxKB * 1KB)) {
                Move-Item -LiteralPath $Path -Destination "$Path.old" -Force
            }
            Add-TextToFile $Path $Text
            $Ex.Data['Logged']  = $true
            $Ex.Data['LogFile'] = $Path
        } catch {
            Write-Status "Couldn't write to the error log: $($_.Exception.Message)" -Warning
        }
    }

    function Invoke-Claude {
        <#
        .SYNOPSIS
        Sends prompts to Claude using the API key stored in KeePass.
        .DESCRIPTION
        Opens the KeePass vault once per call (asking for the master password
        unless -MasterPassword is given), sends each prompt, and returns one
        object per prompt. The key is discarded when the call ends.
        .EXAMPLE
        $R = Invoke-Claude "Summarise this: ..."; $R.Text
        .EXAMPLE
        "First question", "Second question" | Invoke-Claude -Model claude-sonnet-5-5
        #>
        [CmdletBinding()]
        param(
            [Parameter(Position = 0, ValueFromPipeline)][string]$Prompt,
            [string]$Model = $Config.Model,
            [int]$MaxTokens = $Config.MaxTokens,
            [Nullable[double]]$Temperature = $Config.Temperature,
            [string]$System = $Config.System,
            [Security.SecureString]$MasterPassword,
            [string]$Label            # Free text recorded in the usage log, e.g. 'nightly summary'
        )
        begin {
            # The script that called this function, for the error log
            $Caller = $MyInvocation.ScriptName
            try {
                if ($MaxTokens -lt 1) { throw (New-ClaudeError Settings "MaxTokens must be 1 or more (got $MaxTokens).") }
                if ($null -ne $Temperature -and ($Temperature -lt 0 -or $Temperature -gt 1)) {
                    throw (New-ClaudeError Settings "Temperature must be between 0.0 and 1.0 (got $Temperature).")
                }
                if ([string]::IsNullOrWhiteSpace($Model)) { throw (New-ClaudeError Settings 'Model is empty.') }

                Initialize-ClaudeTls
                $ApiKey = Get-KeyFromVault -MasterPassword $MasterPassword
                $Headers = @{ 'x-api-key' = $ApiKey; 'anthropic-version' = $Config.AnthropicVersion }
                $ApiKey = $null
            } catch {
                $ApiKey = $null
                Write-ClaudeErrorLog -ErrorRecord $_ -Model $Model -Caller $Caller
                throw
            }
        }
        process {
          try {
            if ([string]::IsNullOrWhiteSpace($Prompt)) { $Prompt = $Config.DefaultPrompt }

            # Ordered so the JSON reads sensibly if ever inspected
            $Request = [ordered]@{ model = $Model; max_tokens = $MaxTokens }
            if ($System)               { $Request.system      = $System }
            if ($null -ne $Temperature) { $Request.temperature = $Temperature }
            $Request.messages = @(@{ role = 'user'; content = $Prompt })

            # Sent as UTF-8 bytes so accents and symbols arrive intact
            $Body = [Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Depth 5))

            Write-Status "`nCalling Anthropic API ($Model)..." Cyan
            $Timer = [Diagnostics.Stopwatch]::StartNew()
            try {
                $Response = Invoke-WithTls {
                    Invoke-RestMethod -Uri $Config.AnthropicUri -Method POST -Headers $Headers -Body $Body `
                        -ContentType 'application/json; charset=utf-8' `
                        -TimeoutSec $Config.RequestTimeoutSec -ErrorAction Stop @script:TlsParams
                }
                $Timer.Stop()
            } catch {
                $Timer.Stop()
                $Headers = $null
                $ApiErr = ConvertTo-ApiError -Err $_ -Elapsed $Timer.Elapsed.TotalSeconds -Model $Model
                $D = $ApiErr.Exception.Data
                # A failed call is still a transaction: record it (failed requests aren't billed, so no cost)
                Write-ClaudeUsageLog @{
                    Status = 'Failed'; Model = $Model; Label = $Label; CostUsd = 0.0
                    ElapsedSeconds = [math]::Round($Timer.Elapsed.TotalSeconds, 2)
                    Reason = $D['Reason']; HttpStatus = $D['HttpStatus']; RequestId = $D['RequestId']; Caller = $Caller
                }
                throw $ApiErr
            }

            $U   = $Response.usage
            $In  = [int]$U.input_tokens
            $Out = [int]$U.output_tokens
            $CW  = [int]$U.cache_creation_input_tokens   # 0 when prompt caching isn't used
            $CR  = [int]$U.cache_read_input_tokens
            $Cost    = Get-ClaudeCost -Model $Response.model -InputTokens $In -OutputTokens $Out `
                           -CacheWriteTokens $CW -CacheReadTokens $CR
            $Elapsed = [math]::Round($Timer.Elapsed.TotalSeconds, 2)

            Write-ClaudeUsageLog @{
                Status = 'Success'; Model = $Response.model; Label = $Label
                InputTokens = $In; OutputTokens = $Out; CacheWriteTokens = $CW; CacheReadTokens = $CR
                TotalTokens = $In + $Out + $CW + $CR; CostUsd = $Cost.Cost; PriceTier = $Cost.Tier
                ElapsedSeconds = $Elapsed; StopReason = $Response.stop_reason; MessageId = $Response.id
                Caller = $Caller
            }

            [pscustomobject]@{
                PSTypeName       = 'Claude.Response'
                Text             = ($Response.content | Where-Object { $_.type -eq 'text' } |
                                    ForEach-Object { $_.text }) -join "`n"
                Model            = $Response.model
                StopReason       = $Response.stop_reason
                Truncated        = ($Response.stop_reason -eq 'max_tokens')
                InputTokens      = $In
                OutputTokens     = $Out
                CacheWriteTokens = $CW
                CacheReadTokens  = $CR
                TotalTokens      = $In + $Out + $CW + $CR
                EstimatedCostUsd = $Cost.Cost
                InputRate        = $Cost.InputRate
                OutputRate       = $Cost.OutputRate
                PriceTier        = $Cost.Tier
                Label            = $Label
                Id               = $Response.id
                ElapsedSeconds   = $Elapsed
                Timestamp        = (Get-Date).ToUniversalTime().ToString('o')
                Usage            = $U
            }
          } catch {
            $Headers = $null
            Write-ClaudeErrorLog -ErrorRecord $_ -Model $Model -Caller $Caller
            throw
          }
        }
        end {
            # Drop the key at the end of the call
            $Headers = $null
        }
    }

    # Used by the script entry point only
    function Set-ClaudeOutputMode {
        param([ValidateSet('Function', 'Console', 'Json')][string]$Mode)
        $script:OutputMode = $Mode
        if ($Mode -eq 'Json') {
            # Keep standard output clean for the JSON
            $script:ProgressPreference = 'SilentlyContinue'
            $script:WarningPreference  = 'SilentlyContinue'
        }
    }

    Export-ModuleMember -Function Invoke-Claude
}

# ── LOAD ──────────────────────────────────────────────────────
Remove-Module ClaudeApi -Force -ErrorAction SilentlyContinue
New-Module -Name ClaudeApi -ScriptBlock $ClaudeLib -ArgumentList $ClaudeConfig | Import-Module -Global -Force

# Dot-sourced (". .\Invoke-Claude-API-01.ps1"): just make Invoke-Claude available, tidy up, stop here
if ($MyInvocation.InvocationName -eq '.') {
    Remove-Variable ClaudeConfig, ClaudeLib, ClaudePrompt, ClaudeModel, ClaudeMaxTokens, ClaudeTemperature,
                    ClaudeSystem, ClaudeLabel, ClaudeJson, ClaudePwdStdin, ClaudePwdEnv -ErrorAction SilentlyContinue
    return
}

# ── RUN AS A SCRIPT ───────────────────────────────────────────
$ClaudeMode = if ($ClaudeJson) { 'Json' } else { 'Console' }
& (Get-Module ClaudeApi) { param($M) Set-ClaudeOutputMode $M } $ClaudeMode

if ($ClaudeMode -eq 'Json') {
    $ProgressPreference = 'SilentlyContinue'
    $WarningPreference  = 'SilentlyContinue'
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
} else {
    $Source = if ($PSScriptRoot) { 'script folder' } else { 'current folder, because this is not running from a saved .ps1 file' }
    if ($PSScriptRoot -and $ClaudeConfig.WorkingDir -ne $PSScriptRoot) { $Source = 'set in SETTINGS' }
    Write-Host "`nWorking folder: $($ClaudeConfig.WorkingDir)" -ForegroundColor DarkGray
    Write-Host "  ($Source)" -ForegroundColor DarkGray
}

$CallArgs = @{}
if ($ClaudePrompt)                { $CallArgs.Prompt      = $ClaudePrompt }
if ($ClaudeModel)                 { $CallArgs.Model       = $ClaudeModel }
if ($ClaudeMaxTokens)             { $CallArgs.MaxTokens   = $ClaudeMaxTokens }
if ($null -ne $ClaudeTemperature) { $CallArgs.Temperature = $ClaudeTemperature }
if ($ClaudeSystem)                { $CallArgs.System      = $ClaudeSystem }
if ($ClaudeLabel)                 { $CallArgs.Label       = $ClaudeLabel }

$Reason = 'Success'
$Result = $null
$ErrInfo = $null
try {
    # Master password supplied by another program?
    if ($ClaudePwdStdin -and $ClaudePwdEnv) {
        throw (& (Get-Module ClaudeApi) { New-ClaudeError Settings 'Use either -MasterPasswordFromStdin or -MasterPasswordEnv, not both.' })
    }
    if ($ClaudePwdStdin -or $ClaudePwdEnv) {
        if ($ClaudePwdStdin) {
            $Plain = [Console]::In.ReadLine()
            $From  = 'standard input'
        } else {
            $Plain = [Environment]::GetEnvironmentVariable($ClaudePwdEnv)
            [Environment]::SetEnvironmentVariable($ClaudePwdEnv, $null)   # clear it from this process
            $From  = "environment variable $ClaudePwdEnv"
        }
        if ([string]::IsNullOrEmpty($Plain)) {
            throw (& (Get-Module ClaudeApi) { param($F) New-ClaudeError DatabaseAuth "No master password was received from $F." } $From)
        }
        $Secure = New-Object Security.SecureString
        foreach ($Ch in $Plain.ToCharArray()) { $Secure.AppendChar($Ch) }
        $Secure.MakeReadOnly()
        $Plain = $null
        $CallArgs.MasterPassword = $Secure
    }

    $Result = Invoke-Claude @CallArgs
} catch {
    # Errors from inside Invoke-Claude are already logged; this catches the rest (e.g. password input)
    $LogModel = if ($ClaudeModel) { $ClaudeModel } else { $ClaudeConfig.Model }
    & (Get-Module ClaudeApi) { param($E, $M, $C) Write-ClaudeErrorLog -ErrorRecord $E -Model $M -Caller $C } $_ $LogModel $PSCommandPath

    $Data    = $_.Exception.Data
    $Reason  = if ($Data -and $Data['Reason']) { $Data['Reason'] } else { 'Unexpected' }
    $ErrInfo = [ordered]@{
        reason     = $Reason
        exitCode   = if ($Data -and $null -ne $Data['ExitCode']) { [int]$Data['ExitCode'] } else { 1 }
        message    = & (Get-Module ClaudeApi) { param($T) Hide-Secret $T } $_.Exception.Message
        details    = if ($Data -and $Data['Details']) { @($Data['Details']) } else { @() }
        httpStatus = if ($Data -and $Data['HttpStatus']) { [int]$Data['HttpStatus'] } else { $null }
        requestId  = if ($Data -and $Data['RequestId']) { $Data['RequestId'] } else { $null }
        logFile    = if ($Data -and $Data['LogFile']) { $Data['LogFile'] } else { $null }
    }
    if ($Reason -eq 'Unexpected' -and -not ($Data -and $Data['Reason'])) {
        $ErrInfo.details += "At line $($_.InvocationInfo.ScriptLineNumber): $("$($_.InvocationInfo.Line)".Trim())"
    }
} finally {
    if ($CallArgs.MasterPassword) { $CallArgs.MasterPassword.Dispose() }
}

$ExitCode = if ($ErrInfo) { $ErrInfo.exitCode } else { 0 }

if ($ClaudeMode -eq 'Json') {
    $Out = if ($ErrInfo) {
        [ordered]@{ ok = $false; error = $ErrInfo }
    } else {
        [ordered]@{
            ok = $true; text = $Result.Text; model = $Result.Model; stopReason = $Result.StopReason
            truncated = $Result.Truncated; inputTokens = $Result.InputTokens; outputTokens = $Result.OutputTokens
            cacheWriteTokens = $Result.CacheWriteTokens; cacheReadTokens = $Result.CacheReadTokens
            totalTokens = $Result.TotalTokens; estimatedCostUsd = $Result.EstimatedCostUsd
            inputRate = $Result.InputRate; outputRate = $Result.OutputRate; priceTier = $Result.PriceTier
            label = $Result.Label; id = $Result.Id; elapsedSeconds = $Result.ElapsedSeconds
            timestamp = $Result.Timestamp; usage = $Result.Usage
        }
    }
    [Console]::Out.WriteLine(($Out | ConvertTo-Json -Depth 6 -Compress))
    exit $ExitCode
}

# Script mode: friendly output
$C = $ClaudeConfig
if ($ErrInfo) {
    Write-Host $ErrInfo.message -ForegroundColor Red
    foreach ($Line in $ErrInfo.details) { Write-Host "  $Line" -ForegroundColor DarkGray }
    if ($ErrInfo.logFile) { Write-Host "  Logged to  : $($ErrInfo.logFile)" -ForegroundColor DarkGray }
} else {
    Write-Host "`n── Response ──────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host $Result.Text
    Write-Host "──────────────────────────────────────────────────────" -ForegroundColor Yellow
    if ($C.ShowModel)        { Write-Host "Model         : $($Result.Model)"        -ForegroundColor DarkGray }
    if ($C.ShowInputTokens)  { Write-Host "Input tokens  : $($Result.InputTokens)"  -ForegroundColor DarkGray }
    if ($C.ShowOutputTokens) { Write-Host "Output tokens : $($Result.OutputTokens)" -ForegroundColor DarkGray }
    if ($C.ShowTotalTokens)  { Write-Host "Total tokens  : $($Result.TotalTokens)"  -ForegroundColor DarkGray }
    if ($C.ShowStopReason)   { Write-Host "Stop reason   : $($Result.StopReason)"   -ForegroundColor DarkGray }
    if ($C.ShowMessageId)    { Write-Host "Message ID    : $($Result.Id)"           -ForegroundColor DarkGray }
    if ($C.ShowElapsedTime)  { Write-Host ("Elapsed       : {0:N2} s" -f $Result.ElapsedSeconds) -ForegroundColor DarkGray }
    if ($C.ShowCost) {
        if ($null -ne $Result.EstimatedCostUsd) {
            Write-Host ("Est. cost     : `${0:N7} USD" -f $Result.EstimatedCostUsd) -ForegroundColor DarkGray
        } else {
            Write-Host "Est. cost     : no price listed for $($Result.Model) (add it to Prices)" -ForegroundColor DarkGray
        }
    }
    if ($Result.Truncated) {
        $Max = if ($ClaudeMaxTokens) { $ClaudeMaxTokens } else { $C.MaxTokens }
        Write-Host "Note: the reply was cut off at the max tokens limit ($Max)." -ForegroundColor Yellow
    }
}
if ($C.ShowExitCode) { Write-Host "`nExit code: $ExitCode ($Reason)" -ForegroundColor DarkGray }
exit $ExitCode
