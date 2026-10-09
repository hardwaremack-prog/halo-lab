# Halo Lab launcher: starts halo-server.ps1 and, if anything goes wrong while starting,
# shows a message and writes the details to startup.log in this folder.
# It also (re)creates the Halo Lab icon on the Desktop so it always points here.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$url = 'http://localhost:11500/'

# Already running? Just open it in the browser.
try {
  $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 ($url + 'api/hl/ping')
  if ($r.Content -match '"app"\s*:\s*"halo-lab"') { Start-Process $url; exit 0 }
} catch {}

try {
  $desk = [Environment]::GetFolderPath('Desktop')
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut((Join-Path $desk 'Halo Lab.lnk'))
  $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $here 'halo-start.ps1') + '"'
  $sc.WorkingDirectory = $here
  $sc.IconLocation = (Join-Path $here 'Halo Lab.ico') + ',0'
  $sc.WindowStyle = 7
  $sc.Description = 'Halo Lab: local AI on this PC'
  $sc.Save()
} catch {}

# The log is opened and closed for each line, so it is never left locked.
$log = Join-Path $here 'startup.log'
function Write-Log([string]$text, [switch]$New) {
  $line = '{0}  {1}' -f (Get-Date -Format s), $text
  try {
    if ($New) { Set-Content -Path $log -Value $line -Encoding UTF8 -ErrorAction Stop }
    else { Add-Content -Path $log -Value $line -Encoding UTF8 -ErrorAction Stop }
  } catch {}
}

try {
  Write-Log ('Starting Halo Lab (PowerShell {0})' -f $PSVersionTable.PSVersion) -New
  & (Join-Path $here 'halo-server.ps1') @args 2>&1 | ForEach-Object { Write-Log ([string]$_) }
} catch {
  Write-Log ($_ | Out-String)
  try {
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show(("Halo Lab couldn't start.`n`n" + $_.Exception.Message + "`n`nDetails are in:`n" + $log), 'Halo Lab')
  } catch {}
}
