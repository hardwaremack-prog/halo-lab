# Halo Lab launcher: starts halo-server.ps1 and, if anything goes wrong while starting,
# shows a message and writes the details to startup.log in this folder.
# It also (re)creates the Halo Lab icon on the Desktop so it always points here.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $here 'startup.log'

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

try {
  ('{0}  Starting Halo Lab (PowerShell {1})' -f (Get-Date -Format s), $PSVersionTable.PSVersion) | Out-File -FilePath $log -Encoding utf8
  & (Join-Path $here 'halo-server.ps1') @args 2>&1 | ForEach-Object { ('{0}  {1}' -f (Get-Date -Format s), $_) } | Out-File -FilePath $log -Append -Encoding utf8
} catch {
  ($_ | Out-String) | Out-File -FilePath $log -Append -Encoding utf8
  try {
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show(("Halo Lab couldn't start.`n`n" + $_.Exception.Message + "`n`nDetails are in:`n" + $log), 'Halo Lab')
  } catch {}
}
