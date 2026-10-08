# Halo Lab hardware monitor
# Shares live CPU, GPU and NPU use with the Halo Lab dashboard at http://localhost:11500/stats
# It only listens on this computer. Close this window to stop it.
# Reads the same Windows performance counters Task Manager uses. Works with Windows PowerShell 5.1.

$ErrorActionPreference = 'SilentlyContinue'
$port = 11500

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() } catch {
  Write-Host "Could not start on port $port. The monitor may already be running in another window."
  Start-Sleep -Seconds 4
  exit 1
}

# ---------- things that don't change ----------
$cpuInfo  = Get-CimInstance Win32_Processor
$cpuName  = (($cpuInfo | Select-Object -First 1).Name -replace '\s+', ' ').Trim()
$threads  = ($cpuInfo | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

$npuDev = Get-CimInstance Win32_PnPEntity |
  Where-Object { $_.PNPClass -eq 'ComputeAccelerator' -or $_.Name -match '\bNPU\b|Neural|\bIPU\b' } |
  Select-Object -First 1

# GPU name and how much memory is set aside for it (Variable Graphics Memory / UMA size)
$gpuName = $null
$gpuDedicatedTotalGB = $null
$classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
foreach ($k in (Get-ChildItem $classKey)) {
  $p = Get-ItemProperty $k.PSPath
  if ($p.DriverDesc -match 'Radeon|AMD') {
    $gpuName = $p.DriverDesc
    $m = $p.'HardwareInformation.qwMemorySize'
    if ($m -is [byte[]]) { $m = [BitConverter]::ToInt64($m, 0) }
    if ($m) { $gpuDedicatedTotalGB = [math]::Round([double]$m / 1GB, 1) }
  }
}
if (-not $gpuName) { $gpuName = (Get-CimInstance Win32_VideoController | Select-Object -First 1).Name }

$procNames = @{}
function Get-PName([int]$procId) {
  if (-not $procNames.ContainsKey($procId)) {
    $pr = Get-Process -Id $procId
    if ($pr) { $procNames[$procId] = $pr.ProcessName } else { $procNames[$procId] = "pid $procId" }
  }
  return $procNames[$procId]
}

function Get-TopProcs($a) {
  $out = @()
  if ($null -eq $a) { return ,$out }
  foreach ($kv in ($a.procs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)) {
    $out += @{ pid = $kv.Key; name = (Get-PName $kv.Key); util = [math]::Round([math]::Min(100, $kv.Value), 1) }
  }
  return ,$out
}

function Get-AdapterUtil($a) {
  if ($null -eq $a) { return $null }
  $max = 0
  foreach ($v in $a.eng.Values) { if ($v -gt $max) { $max = $v } }
  return [math]::Round([math]::Min(100, $max), 1)
}

# ---------- live numbers ----------
function Get-Stats {
  # Every engine of every graphics/compute adapter, per process. The NPU shows up here as its own adapter.
  $ad = @{}
  foreach ($e in (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine)) {
    if ($e.Name -notmatch '^pid_(\d+)_luid_(0x[0-9a-fA-F]+_0x[0-9a-fA-F]+)_phys_\d+_eng_(\d+)_engtype_(.*)$') { continue }
    $procId = [int]$Matches[1]; $luid = $Matches[2].ToLower(); $type = $Matches[4]
    $key = $Matches[3] + '|' + $type
    $u = [double]$e.UtilizationPercentage
    if (-not $ad.ContainsKey($luid)) { $ad[$luid] = @{ types = @{}; eng = @{}; procs = @{} } }
    $a = $ad[$luid]
    $a.types[$type] = $true
    if ($a.eng.ContainsKey($key)) { $a.eng[$key] += $u } else { $a.eng[$key] = $u }
    if ($u -gt 0) { if ($a.procs.ContainsKey($procId)) { $a.procs[$procId] += $u } else { $a.procs[$procId] = $u } }
  }

  # The GPU is the adapter with 3D/video engines and the most engines; the NPU is the busiest-equipped adapter without them.
  $gpuLuid = $null; $npuLuid = $null; $gpuCount = -1; $npuCount = -1
  foreach ($luid in $ad.Keys) {
    $a = $ad[$luid]
    $isGraphics = $false
    foreach ($t in $a.types.Keys) { if ($t -match '^3D|Video') { $isGraphics = $true } }
    $n = $a.eng.Count
    if ($isGraphics) { if ($n -gt $gpuCount) { $gpuCount = $n; $gpuLuid = $luid } }
    else { if ($n -gt $npuCount) { $npuCount = $n; $npuLuid = $luid } }
  }
  $gA = $null; if ($gpuLuid) { $gA = $ad[$gpuLuid] }
  $nA = $null; if ($npuLuid) { $nA = $ad[$npuLuid] }

  # GPU engine types (3D, Compute, Copy...) for the "busiest engine" label
  $engTypes = @{}
  if ($gA) {
    foreach ($kv in $gA.eng.GetEnumerator()) {
      $t = ($kv.Key.Split('|')[1]) -replace '_\d+$', ''
      $v = [math]::Round([math]::Min(100, $kv.Value), 1)
      if (-not $engTypes.ContainsKey($t) -or $engTypes[$t] -lt $v) { $engTypes[$t] = $v }
    }
  }

  # GPU memory in use
  $ded = $null; $shared = $null
  foreach ($m in (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory)) {
    if ($m.Name -match 'luid_(0x[0-9a-fA-F]+_0x[0-9a-fA-F]+)' -and $Matches[1].ToLower() -eq $gpuLuid) {
      $ded += [double]$m.DedicatedUsage; $shared += [double]$m.SharedUsage
    }
  }

  $cpuUtil = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
  $os = Get-CimInstance Win32_OperatingSystem
  $totalGB = [double]$os.TotalVisibleMemorySize * 1KB / 1GB
  $freeGB  = [double]$os.FreePhysicalMemory * 1KB / 1GB

  $npuName = $null; $npuStatus = $null
  if ($npuDev) { $npuName = $npuDev.Name; $npuStatus = $npuDev.Status }

  $dedGB = $null; if ($null -ne $ded) { $dedGB = [math]::Round($ded / 1GB, 2) }
  $shGB  = $null; if ($null -ne $shared) { $shGB = [math]::Round($shared / 1GB, 2) }

  return [ordered]@{
    ok   = $true
    time = (Get-Date).ToString('o')
    cpu  = [ordered]@{ name = $cpuName; threads = $threads; util = [double]$cpuUtil }
    ram  = [ordered]@{ totalGB = [math]::Round($totalGB, 1); usedGB = [math]::Round($totalGB - $freeGB, 1) }
    gpu  = [ordered]@{ name = $gpuName; util = (Get-AdapterUtil $gA); engines = $engTypes; procs = (Get-TopProcs $gA)
                       dedicatedGB = $dedGB; sharedGB = $shGB; dedicatedTotalGB = $gpuDedicatedTotalGB }
    npu  = [ordered]@{ present = [bool]$npuDev; found = [bool]$nA; name = $npuName; status = $npuStatus
                       util = (Get-AdapterUtil $nA); procs = (Get-TopProcs $nA) }
  }
}

Write-Host ""
Write-Host "  Halo Lab hardware monitor is running."
Write-Host "  CPU: $cpuName"
Write-Host "  GPU: $gpuName"
if ($npuDev) { Write-Host "  NPU: $($npuDev.Name) ($($npuDev.Status))" } else { Write-Host "  NPU: not found by Windows" }
Write-Host ""
Write-Host "  Leave this window open while you use Halo Lab. Close it to stop."
Write-Host ""

while ($listener.IsListening) {
  try { $ctx = $listener.GetContext() } catch { break }
  $res = $ctx.Response
  $res.Headers.Add('Access-Control-Allow-Origin', '*')
  $res.Headers.Add('Access-Control-Allow-Private-Network', 'true')
  $res.Headers.Add('Cache-Control', 'no-store')
  if ($ctx.Request.HttpMethod -eq 'OPTIONS') {
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET')
    $res.StatusCode = 204; $res.Close(); continue
  }
  try { $json = Get-Stats | ConvertTo-Json -Depth 6 -Compress }
  catch { $json = (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress) }
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $res.ContentType = 'application/json; charset=utf-8'
  $res.ContentLength64 = $bytes.Length
  try { $res.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
  $res.Close()
}
