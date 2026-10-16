# ps-claude-api-toolkit

PowerShell toolkit for the Anthropic Claude API. Your API key stays in KeePass, the same script works three ways (run it, call it as a function, or call it from any program with JSON), and every call is logged with its token count and estimated cost.

```powershell
. .\Invoke-Claude-API-01.ps1
$R = Invoke-Claude "Summarise this in one line: ..." -Label "daily notes"
$R.Text
$R.EstimatedCostUsd
```

## What's in it

| File | What it does | Needs the KeePass password |
| --- | --- | --- |
| `Invoke-Claude-API-01.ps1` | Opens KeePass, calls the API, returns the reply, writes the usage and error logs | Yes |
| `Get-ClaudeBilling-Report01.ps1` | Makes one tiny test call (under 100 tokens) and shows its tokens and estimated cost | Yes |
| `Get-ClaudeUsage-Report01.ps1` | Reports spend by day, model, caller and label against a monthly budget | No |

## Features

- **Key kept in KeePass.** The master password is asked for on every call, held only as a SecureString and discarded as soon as the vault opens. The key is never printed, logged or returned.
- **Three ways to call it:** run it in a console, dot-source it and call `Invoke-Claude` from your own scripts, or run it with `-Json` from Python, C#, batch files and other programs.
- **Output your way.** The latest reply is kept in `$ClaudeOutput`, can be saved to a file (text or JSON) for other apps, and screen output can be turned off so a caller captures the result: `$R = .\Invoke-Claude-API-01.ps1 -Prompt "..."`.
- **Clear errors.** Each failure has a plain-English message and its own exit code: KeePass, TLS, HTTP 401 or 429, out of credits, timeouts and more.
- **TLS checks.** Checks the TLS version you choose against your PowerShell and Windows, offers fixes, and tests a real connection before the key is used.
- **Usage tracking.** One CSV row per call, with tokens, estimated cost, model, label and caller. Prompt and reply text are never recorded.
- **Reports.** Summary, budget with a month-end projection, daily totals, totals by model, caller and label, most expensive calls, and failures.
- **Error log.** Every error is written to a log, and anything that looks like an API key is masked.

## Quick start

1. Put the three scripts and your KeePass database (`root.kdbx`) in one folder.
2. In KeePass, create an entry with Title `Anthropic API`, User name `keepassUser` and your API key in the Password field. Other names work too: set `KeePassTitle` and `KeePassUser` in the script's SETTINGS block to match.
3. In PowerShell, run:

   ```powershell
   .\Invoke-Claude-API-01.ps1
   ```

   It offers to install the PoshKeePass module the first time, asks for your master password, and sends a test prompt.

4. See your usage:

   ```powershell
   .\Get-ClaudeUsage-Report01.ps1
   ```

If Windows won't run the scripts, run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` and then `Unblock-File .\*.ps1`.

## From other programs

```
pwsh -NoProfile -File Invoke-Claude-API-01.ps1 -Prompt "Hello" -Json -MasterPasswordFromStdin
```

Write the master password as the first line of standard input. Standard output is one JSON object (`ok`, `text`, token counts, `estimatedCostUsd`, or an `error` object), and the exit code tells you what happened.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- [PoshKeePass](https://www.powershellgallery.com/packages/PoshKeePass) (installed for you on first run)
- A KeePass database that opens with a master password only (no key file)
- An Anthropic API key from the [Claude Console](https://console.anthropic.com)

## Documentation

The [full manual](docs/MANUAL.md) covers every setting, parameter, report section and exit code, plus security notes and troubleshooting.

## Costs

The costs shown are estimates calculated from the `Prices` table in `Invoke-Claude-API-01.ps1`, which uses [Anthropic's published rates](https://platform.claude.com/docs/en/about-claude/pricing) as of October 2026. Update the table when prices change. Your actual charges are in the Claude Console.

This project isn't affiliated with or endorsed by Anthropic.

## Licence

[MIT License](LICENSE).
