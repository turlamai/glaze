# Launch a packaged Windows app the way Explorer does — through
# ShellExecute, so the process gets no standard handles — and report whether
# it allocated a console window.
#
# glaze#173: Racket's runtime allocates a console on the first stdio use of a
# GUI process that has none, and the WebView backend wrote a line per resource
# request. Every install therefore opened with a console window that filled
# with [glaze-win-webview] output. A shell-launched runner inherits handles and
# cannot reproduce that, which is why this must not use `& $exe`.
#
#   -ExpectConsole   the launch must allocate a console (control run: proves the
#                    detector works on this machine)
#   default          the launch must not allocate a console
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [int]$Seconds = 15,
  [switch]$ExpectConsole
)
$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path -LiteralPath $Exe).Path

$start = [System.Diagnostics.ProcessStartInfo]::new($Exe)
$start.UseShellExecute = $true
$start.WorkingDirectory = Split-Path -Parent $Exe
$app = [System.Diagnostics.Process]::Start($start)
try {
  Start-Sleep -Seconds $Seconds
  if ($app.HasExited) { throw "$(Split-Path -Leaf $Exe) exited within $Seconds s with code $($app.ExitCode)" }

  # conhost.exe hosts the classic console; OpenConsole.exe is the same job
  # under Windows Terminal as the default terminal.
  $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($app.Id)" |
    ForEach-Object { $_.Name })
  $consoleHosts = @($children | Where-Object { $_ -eq 'conhost.exe' -or $_ -eq 'OpenConsole.exe' })
  "children after $Seconds s: $($children -join ', ')"
  $hasConsole = $consoleHosts.Count -gt 0

  if ($ExpectConsole -and -not $hasConsole) {
    throw 'control run: GLAZE_DEBUG=1 should have opened a console, none detected - the detector does not work on this host'
  }
  if (-not $ExpectConsole -and $hasConsole) {
    throw "packaged app allocated a console window: $($consoleHosts -join ', ')"
  }
  "OK: console allocated = $hasConsole (expected $ExpectConsole)"
} finally {
  if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
