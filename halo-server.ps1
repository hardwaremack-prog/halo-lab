# Halo Lab server
# - Serves the Halo Lab dashboard at http://localhost:11500/
# - Shares live CPU / GPU / NPU use with it
# - Installs the AI engine (llama.cpp, Vulkan build for the Radeon GPU) the first time
# - Downloads models from Hugging Face and loads them into the GPU
# Only this computer can reach it. Quit from the tray icon (right-click > Quit).
# Works with the Windows PowerShell 5.1 that comes with Windows. Keep this file plain ASCII.

param([switch]$NoBrowser)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Port = 11500
$IsWin = ($env:OS -eq 'Windows_NT')
$Url = "http://localhost:$Port/"

# ---------- already running? just open it ----------
try {
  $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 ($Url + 'api/hl/ping')
  if ($r.StatusCode -eq 200 -and $r.Content -match '"app"\s*:\s*"halo-lab"') { if (-not $NoBrowser) { Start-Process $Url }; exit 0 }
} catch {}

# the hardware monitor from Halo Lab 1.x used the same port; stop it so this version can start
if ($env:OS -eq 'Windows_NT') {
  try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
      Where-Object { $_.CommandLine -and $_.CommandLine -like '*halo-monitor.ps1*' -and $_.ProcessId -ne $PID } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
  } catch {}
}

if ($env:HALO_DATA) { $Data = $env:HALO_DATA }
elseif ($IsWin) { $Data = Join-Path $env:LOCALAPPDATA 'HaloLab' }
else { $Data = Join-Path $HOME '.halolab' }
foreach ($d in @($Data, (Join-Path $Data 'engine'), (Join-Path $Data 'models'), (Join-Path $Data 'logs'))) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------- code shared by the server and its background jobs ----------
$Lib = @'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-HLConfig($sync) {
  $f = Join-Path $sync.data 'config.json'
  if (Test-Path $f) { try { return (Get-Content $f -Raw | ConvertFrom-Json) } catch {} }
  return [pscustomobject]@{ modelsDir = '' }
}

function Get-ModelsDir($sync) {
  $c = Get-HLConfig $sync
  if ($c.modelsDir -and (Test-Path $c.modelsDir)) { return $c.modelsDir }
  return (Join-Path $sync.data 'models')
}

function Get-SafeName([string]$id) { return ($id -replace '[^A-Za-z0-9._-]', '_') }

# Downloads one file with resume support. $st holds progress: baseDone + this file = done.
function Save-Url([string]$url, [string]$dest, $st) {
  $part = "$dest.part"
  $have = 0L
  if (Test-Path $part) { $have = (Get-Item $part).Length }
  $req = [Net.HttpWebRequest]::Create($url)
  $req.UserAgent = 'HaloLab/1.0'
  $req.AllowAutoRedirect = $true
  $req.Timeout = 30000
  $req.ReadWriteTimeout = 120000
  if ($have -gt 0) { $req.AddRange([long]$have) }
  $resp = $req.GetResponse()
  try {
    $mode = [IO.FileMode]::Create
    if ($have -gt 0 -and [int]$resp.StatusCode -eq 206) { $mode = [IO.FileMode]::Append } else { $have = 0L }
    $fs = [IO.File]::Open($part, $mode, [IO.FileAccess]::Write)
    try {
      $in = $resp.GetResponseStream()
      $buf = New-Object byte[] 1048576
      $st.fileDone = $have
      $st.done = $st.baseDone + $have
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $fs.Write($buf, 0, $n)
        $st.fileDone += $n
        $st.done = $st.baseDone + $st.fileDone
        if ($st.cancel) { throw 'Cancelled' }
      }
    } finally { $fs.Close() }
  } finally { $resp.Close() }
  if (Test-Path $dest) { Remove-Item $dest -Force }
  Move-Item $part $dest -Force
}
'@

# ---------- background job: install the engine ----------
$EngineJob = {
  param($sync)
  $ErrorActionPreference = 'Stop'
  . ([scriptblock]::Create($sync.lib))
  $st = $sync.engineJob
  try {
    $pattern = 'bin-win-vulkan-x64\.zip$'
    if (-not $sync.isWin) { $pattern = 'bin-ubuntu-x64\.tar\.gz$' }
    $url = $env:HALO_ENGINE_URL; $ver = 'custom'
    if (-not $url) {
      $st.status = 'Finding the newest engine'
      try {
        $rels = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'HaloLab' } 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15'
        foreach ($r in $rels) {
          foreach ($a in $r.assets) { if ($a.name -match $pattern) { $url = $a.browser_download_url; $ver = $r.tag_name; break } }
          if ($url) { break }
        }
      } catch {}
    }
    if (-not $url) {
      $ver = 'b11435'
      if ($sync.isWin) { $url = 'https://github.com/ggml-org/llama.cpp/releases/download/b11435/llama-b11435-bin-win-vulkan-x64.zip' }
      else { $url = 'https://github.com/ggml-org/llama.cpp/releases/download/b11435/llama-b11435-bin-ubuntu-x64.tar.gz' }
    }
    $st.status = 'Downloading the engine'
    $st.baseDone = 0L; $st.done = 0L; $st.total = 0L
    try {
      $h = [Net.HttpWebRequest]::Create($url); $h.Method = 'HEAD'; $h.UserAgent = 'HaloLab/1.0'
      $hr = $h.GetResponse(); $st.total = $hr.ContentLength; $hr.Close()
    } catch {}
    $leaf = ($url -split '/')[-1]
    $tmp = Join-Path $sync.data $leaf
    Save-Url $url $tmp $st
    $st.status = 'Unpacking'
    $dir = Join-Path (Join-Path $sync.data 'engine') $ver
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if ($leaf -like '*.zip') { Expand-Archive -Path $tmp -DestinationPath $dir -Force }
    else { & tar -xzf $tmp -C $dir }
    Remove-Item $tmp -Force
    $exeName = 'llama-server'; if ($sync.isWin) { $exeName = 'llama-server.exe' }
    $exe = @(Get-ChildItem -Path $dir -Recurse -Filter $exeName)[0]
    if (-not $exe) { throw "The engine download didn't contain $exeName." }
    $info = [ordered]@{ version = $ver; exe = $exe.FullName; installed = (Get-Date).ToString('o') }
    ($info | ConvertTo-Json) | Set-Content -Path (Join-Path (Join-Path $sync.data 'engine') 'engine.json') -Encoding UTF8
    $st.status = 'done'
  } catch {
    $st.error = $_.Exception.Message
    $st.status = 'failed'
  }
}

# ---------- background job: download a model from Hugging Face ----------
$PullJob = {
  param($sync, $id)
  $ErrorActionPreference = 'Stop'
  . ([scriptblock]::Create($sync.lib))
  $st = $sync.dl[$id]
  try {
    $base = 'https://huggingface.co'; if ($env:HALO_HF) { $base = $env:HALO_HF }
    $repo = $st.repo; $quant = $st.quant
    $st.status = 'Finding files'
    $tree = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'HaloLab' } "$base/api/models/$repo/tree/main?recursive=1"
    # (foreach loops instead of pipelines: Windows PowerShell 5.1 passes a JSON array down a pipeline as one item)
    $files = @(foreach ($x in $tree) { if ($x.type -eq 'file' -and $x.path -like '*.gguf') { $x } })
    if (-not $files.Count) { throw "No model files (.gguf) found in $repo." }
    $q = [regex]::Escape($quant)
    $cands = @(foreach ($x in $files) {
      $leaf = ($x.path -split '/')[-1]
      if (($leaf -notmatch '^(?i)(mmproj|eagle|draft)') -and ($leaf -match "(?i)[-_.]$q(-\d{5}-of-\d{5})?\.gguf$")) { $x }
    })
    if (-not $cands.Count) { throw "No $quant version found in $repo." }
    $split = @(foreach ($x in $cands) { if ($x.path -match '-\d{5}-of-\d{5}\.gguf$') { $x } })
    if ($split.Count) {
      $split = @($split | Sort-Object -Property path)
      $first = ($split[0].path -replace '-\d{5}-of-\d{5}\.gguf$', '')
      $pick = @(foreach ($x in $split) { if (($x.path -replace '-\d{5}-of-\d{5}\.gguf$', '') -eq $first) { $x } })
    } else {
      $pick = @(@($cands | Sort-Object -Property { $_.path.Length })[0])
    }
    $mm = $null
    if ($st.vision) {
      $mms = @(foreach ($x in $files) { if ((($x.path -split '/')[-1]) -match '^(?i)mmproj') { $x } })
      foreach ($x in $mms) { if (-not $mm -and (($x.path -split '/')[-1]) -match '(?i)(?<!b)f16\.gguf$') { $mm = $x } }
      if (-not $mm -and $mms.Count) { $mm = $mms[0] }
    }
    $all = @($pick); if ($mm) { $all += $mm }
    $total = 0L; foreach ($f in $all) { $total += [long]$f.size }
    $st.total = $total; $st.baseDone = 0L; $st.done = 0L

    $dir = Join-Path (Get-ModelsDir $sync) (Get-SafeName $id)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $root = [IO.Path]::GetPathRoot($dir)
    try {
      $free = (New-Object IO.DriveInfo($root)).AvailableFreeSpace
      $need = $total
      foreach ($f in $all) { $p = Join-Path $dir (($f.path -split '/')[-1]); if (Test-Path $p) { $need -= (Get-Item $p).Length } elseif (Test-Path "$p.part") { $need -= (Get-Item "$p.part").Length } }
      if ($need -gt $free - 2GB) { throw ('Not enough disk space: this model needs {0:N1} GB and {1:N1} GB is free on {2}' -f ($need / 1GB), ($free / 1GB), $root) }
    } catch { if ($_.Exception.Message -like 'Not enough*') { throw } }

    $leaves = @()
    $i = 0
    foreach ($f in $all) {
      $i++
      $leaf = ($f.path -split '/')[-1]
      $leaves += $leaf
      $dest = Join-Path $dir $leaf
      if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq [long]$f.size)) { $st.baseDone += [long]$f.size; $st.done = $st.baseDone; continue }
      $st.status = 'Downloading'
      if ($all.Count -gt 1) { $st.status = "Downloading part $i of $($all.Count)" }
      $u = "$base/$repo/resolve/main/" + (($f.path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
      Save-Url $u $dest $st
      $st.baseDone += [long]$f.size; $st.done = $st.baseDone
    }
    $mainLeaf = ($pick[0].path -split '/')[-1]
    $mmLeaf = $null; if ($mm) { $mmLeaf = ($mm.path -split '/')[-1] }
    $man = [ordered]@{ id = $id; name = $st.name; repo = $repo; quant = $quant; main = $mainLeaf; mmproj = $mmLeaf; files = $leaves; bytes = $total; added = (Get-Date).ToString('o') }
    ($man | ConvertTo-Json -Depth 4) | Set-Content -Path (Join-Path $dir 'manifest.json') -Encoding UTF8
    $st.status = 'done'
  } catch {
    $msg = $_.Exception.Message
    if ($msg -like '*404*') { $msg = "Couldn't find $($st.repo) on Hugging Face." }
    if ($msg -eq 'Cancelled' -or $st.cancel) { $st.status = 'cancelled'; $st.error = $null; return }
    if ($msg -match '(?i)remote name could not be resolved|unable to connect|timed out|No such host') { $msg = "Couldn't reach Hugging Face. Check the internet connection, then press Retry. The download continues where it stopped." }
    $st.error = $msg
    $st.status = 'failed'
  }
}

# ---------- background job: pass one request through to the engine (streams answers) ----------
$ProxyJob = {
  param($sync, $ctx)
  $req = $ctx.Request; $res = $ctx.Response; $up = $null
  try {
    $up = [Net.HttpWebRequest]::Create('http://127.0.0.1:11600' + $req.Url.PathAndQuery)
    $up.Method = $req.HttpMethod
    $up.Timeout = 900000
    $up.ReadWriteTimeout = 900000
    $up.KeepAlive = $false
    if ($req.ContentType) { $up.ContentType = $req.ContentType }
    if ($req.HasEntityBody) {
      $ms = New-Object IO.MemoryStream
      $req.InputStream.CopyTo($ms)
      $bytes = $ms.ToArray()
      $up.ContentLength = $bytes.Length
      $rs = $up.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
    }
    $ur = $null
    try { $ur = $up.GetResponse() }
    catch [Net.WebException] { $ur = $_.Exception.Response; if (-not $ur) { throw } }
    $res.StatusCode = [int]$ur.StatusCode
    if ($ur.ContentType) { $res.ContentType = $ur.ContentType }
    $res.SendChunked = $true
    $in = $ur.GetResponseStream(); $out = $res.OutputStream
    $buf = New-Object byte[] 8192
    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n); $out.Flush() }
    $ur.Close()
  } catch {
    try { if ($up) { $up.Abort() } } catch {}
    try {
      $res.StatusCode = 502
      $res.ContentType = 'application/json'
      $b = [Text.Encoding]::UTF8.GetBytes('{"error":{"message":"The AI engine is not running. Pick a model in Chat to load it."}}')
      $res.OutputStream.Write($b, 0, $b.Length)
    } catch {}
  }
  try { $res.Close() } catch {}
}

# ---------- the web server ----------
$ServerCode = {
  param($sync)
  . ([scriptblock]::Create($sync.lib))
  $EnginePort = 11600

  function Start-Bg($code, [object[]]$a) {
    # tidy up finished jobs
    foreach ($j in @($sync.jobs)) { if ($j.h.IsCompleted) { try { [void]$j.p.EndInvoke($j.h) } catch {}; $j.p.Dispose(); $sync.jobs.Remove($j) } }
    $p = [powershell]::Create()
    [void]$p.AddScript($code)
    foreach ($x in $a) { [void]$p.AddArgument($x) }
    $h = $p.BeginInvoke()
    [void]$sync.jobs.Add(@{ p = $p; h = $h })
  }

  function Get-Engine {
    $f = Join-Path (Join-Path $sync.data 'engine') 'engine.json'
    if (Test-Path $f) {
      try { $e = Get-Content $f -Raw | ConvertFrom-Json; if ($e.exe -and (Test-Path $e.exe)) { return $e } } catch {}
    }
    return $null
  }

  function Get-Models {
    $out = @()
    $dir = Get-ModelsDir $sync
    if (-not (Test-Path $dir)) { return $out }
    foreach ($m in (Get-ChildItem -Path $dir -Directory)) {
      $f = Join-Path $m.FullName 'manifest.json'
      if (-not (Test-Path $f)) { continue }
      try {
        $j = Get-Content $f -Raw | ConvertFrom-Json
        $out += [ordered]@{ id = $j.id; name = $j.name; repo = $j.repo; quant = $j.quant; bytes = [long]$j.bytes; vision = [bool]$j.mmproj; dir = $m.FullName; main = $j.main; mmproj = $j.mmproj }
      } catch {}
    }
    return $out
  }

  function Get-LogTail([int]$n) {
    $p = Join-Path (Join-Path $sync.data 'logs') 'engine.log'
    if (Test-Path $p) { try { return @(Get-Content $p -Tail $n) } catch {} }
    return @()
  }

  function Stop-Model {
    $s = $sync.srv
    if ($s.pid) { try { Stop-Process -Id $s.pid -Force -ErrorAction Stop } catch {} }
    $s.pid = $null; $s.state = 'stopped'; $s.model = $null; $s.error = $null; $s.detail = $null; $s.device = $null
  }

  function Start-Model([string]$id, [int]$ctx) {
    Stop-Model
    $s = $sync.srv
    $eng = Get-Engine
    if (-not $eng) { throw 'The AI engine is not set up yet.' }
    $m = Get-Models | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $m) { throw "Model $id is not downloaded." }
    if ($ctx -lt 1024) { $ctx = 8192 }
    $q = [char]34
    $log = Join-Path (Join-Path $sync.data 'logs') 'engine.log'
    if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }
    $argList = @('-m', ($q + (Join-Path $m.dir $m.main) + $q), '-c', $ctx, '-ngl', 'all', '--host', '127.0.0.1', '--port', $EnginePort, '--alias', ($q + $id + $q), '--no-webui', '--log-colors', 'off', '--log-file', ($q + $log + $q))
    if ($m.mmproj) { $argList += @('--mmproj', ($q + (Join-Path $m.dir $m.mmproj) + $q)) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $eng.exe
    $psi.Arguments = ($argList -join ' ')
    $psi.WorkingDirectory = (Split-Path $eng.exe)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $s.pid = $p.Id; $s.model = $id; $s.ctx = $ctx; $s.state = 'loading'; $s.error = $null; $s.detail = $null; $s.since = (Get-Date).ToString('o'); $s.device = $null
  }

  function Update-Server {
    $s = $sync.srv
    if ($s.state -ne 'loading' -and $s.state -ne 'ready') { return }
    $alive = $false
    try { $p = Get-Process -Id $s.pid -ErrorAction Stop; $alive = -not $p.HasExited } catch {}
    if (-not $alive) {
      $tail = (Get-LogTail 40) -join "`n"
      $msg = 'The engine stopped unexpectedly.'
      if ($tail -match '(?i)out ?of ?(device )?memory|failed to allocate|ErrorOutOfDeviceMemory|unable to allocate') { $msg = 'Not enough GPU memory for this model at this context size. Try a smaller context window or model, or give the GPU more memory in AMD Software.' }
      elseif ($tail -match '(?i)failed to load model|error loading model') { $msg = "The engine couldn't open this model file. It may be damaged (delete and download it again) or need a newer engine." }
      elseif ($tail -match '(?i)address already in use|bind') { $msg = "Port $EnginePort is in use by another program." }
      $lastErr = @(Get-LogTail 40 | Where-Object { $_ -match '(?i)error|fail' } | Select-Object -Last 3) -join ' | '
      $s.state = 'failed'; $s.error = $msg; $s.detail = $lastErr; $s.pid = $null
      return
    }
    if ($s.state -eq 'loading') {
      try {
        $r = [Net.HttpWebRequest]::Create("http://127.0.0.1:$EnginePort/health"); $r.Timeout = 600
        $resp = $r.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close()
        if ($code -eq 200) {
          $s.state = 'ready'
          $tail = Get-LogTail 400
          $dev = $tail | Where-Object { $_ -match 'ggml_vulkan: \d+ = ([^|(]+)' } | Select-Object -First 1
          if ($dev -and ($dev -match 'ggml_vulkan: \d+ = ([^|(]+)')) { $s.device = $Matches[1].Trim() }
        }
      } catch {}
    }
  }

  # asks the engine which GPUs it can use (llama-server --list-devices); cached until the engine changes
  function Get-Devices {
    $eng = Get-Engine
    if (-not $eng) { return $null }
    if ($sync.devKey -eq $eng.exe -and $null -ne $sync.devices) { return $sync.devices }
    $list = @()
    try {
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = $eng.exe; $psi.Arguments = '--list-devices'
      $psi.WorkingDirectory = (Split-Path $eng.exe)
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $p = [Diagnostics.Process]::Start($psi)
      $errTask = $p.StandardError.ReadToEndAsync()
      $out = $p.StandardOutput.ReadToEnd()
      [void]$p.WaitForExit(20000)
      $all = $out + "`n" + $errTask.Result
      $sync.devText = $all
      foreach ($line in ($all -split "`r?`n")) {
        if ($line -match '^\s+([A-Za-z]+\d+):\s+(.+)$') { $list += [ordered]@{ id = $Matches[1]; name = $Matches[2].Trim() } }
      }
    } catch { $sync.devText = $_.Exception.Message }
    $sync.devices = $list; $sync.devKey = $eng.exe
    return $list
  }

  function Get-Status {
    Update-Server
    $eng = Get-Engine
    $ej = $sync.engineJob
    $engine = [ordered]@{ installed = [bool]$eng; version = $null; installing = ($ej.status -and $ej.status -ne 'done' -and $ej.status -ne 'failed'); status = $ej.status; done = $ej.done; total = $ej.total; error = $ej.error }
    if ($eng) {
      $engine.version = $eng.version
      if (-not $engine.installing) { $engine.devices = @(Get-Devices); $engine.gpu = [bool](@($engine.devices | Where-Object { $_.id -match '^(Vulkan|ROCm|CUDA|HIP)' }).Count) }
    }
    $models = @()
    foreach ($m in (Get-Models)) { $models += [ordered]@{ id = $m.id; name = $m.name; repo = $m.repo; quant = $m.quant; bytes = $m.bytes; vision = $m.vision } }
    $dls = [ordered]@{}
    foreach ($k in @($sync.dl.Keys)) { $d = $sync.dl[$k]; $dls[$k] = [ordered]@{ status = $d.status; done = $d.done; total = $d.total; error = $d.error; name = $d.name; repo = $d.repo; quant = $d.quant; vision = $d.vision } }
    $mdir = Get-ModelsDir $sync
    $free = $null
    try { $free = [math]::Round((New-Object IO.DriveInfo([IO.Path]::GetPathRoot($mdir))).AvailableFreeSpace / 1GB, 1) } catch {}
    $s = $sync.srv
    return [ordered]@{
      ok = $true; app = 'halo-lab'; version = '2.0'
      engine = $engine
      server = [ordered]@{ state = $s.state; model = $s.model; ctx = $s.ctx; port = $EnginePort; error = $s.error; detail = $s.detail; device = $s.device; since = $s.since }
      models = $models; downloads = $dls
      disk = [ordered]@{ modelsDir = $mdir; freeGB = $free }
    }
  }

  # ----- hardware stats (same counters Task Manager uses) -----
  function Get-Stats {
    if (-not $sync.isWin) { return [ordered]@{ ok = $false; error = 'Hardware counters need Windows.' } }
    if (-not $sync.hw) {
      $cpuInfo = Get-CimInstance Win32_Processor
      $hw = @{}
      $hw.cpuName = (($cpuInfo | Select-Object -First 1).Name -replace '\s+', ' ').Trim()
      $hw.threads = ($cpuInfo | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
      $hw.npu = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPClass -eq 'ComputeAccelerator' -or $_.Name -match '\bNPU\b|Neural|\bIPU\b' } | Select-Object -First 1
      $hw.gpuName = $null; $hw.gpuTotal = $null
      $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
      foreach ($k in (Get-ChildItem $classKey -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($p.DriverDesc -match 'Radeon|AMD') {
          $hw.gpuName = $p.DriverDesc
          $m = $p.'HardwareInformation.qwMemorySize'
          if ($m -is [byte[]]) { $m = [BitConverter]::ToInt64($m, 0) }
          if ($m) { $hw.gpuTotal = [math]::Round([double]$m / 1GB, 1) }
        }
      }
      if (-not $hw.gpuName) { $hw.gpuName = (Get-CimInstance Win32_VideoController | Select-Object -First 1).Name }
      $hw.names = @{}
      $sync.hw = $hw
    }
    $hw = $sync.hw
    $ad = @{}
    foreach ($e in (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine)) {
      # names look like pid_1234_luid_0x..._0x..._phys_0_eng_1_engtype_Compute 0 (the pid part is not always there)
      if ($e.Name -notmatch '(?:pid_(\d+)_)?luid_(0x[0-9a-fA-F]+_0x[0-9a-fA-F]+)_phys_\d+_eng_(\d+)_engtype_(.*)$') { continue }
      $procId = 0; if ($Matches[1]) { $procId = [int]$Matches[1] }
      $luid = $Matches[2].ToLower(); $type = $Matches[4]; $key = $Matches[3] + '|' + $type
      $u = [double]$e.UtilizationPercentage
      if (-not $ad.ContainsKey($luid)) { $ad[$luid] = @{ types = @{}; eng = @{}; procs = @{} } }
      $a = $ad[$luid]; $a.types[$type] = $true
      if ($a.eng.ContainsKey($key)) { $a.eng[$key] += $u } else { $a.eng[$key] = $u }
      if ($u -gt 0 -and $procId -gt 0) { if ($a.procs.ContainsKey($procId)) { $a.procs[$procId] += $u } else { $a.procs[$procId] = $u } }
    }
    $gpuLuid = $null; $npuLuid = $null; $gc = -1; $nc = -1
    foreach ($luid in $ad.Keys) {
      $a = $ad[$luid]; $isG = $false
      foreach ($t in $a.types.Keys) { if ($t -match '^3D|Video') { $isG = $true } }
      # a real GPU has many kinds of engine (3D, Compute, Copy, Video...); virtual display adapters can list
      # dozens of engines of a single kind, so rank by kinds first and count second
      $n = $a.types.Count * 1000 + $a.eng.Count
      if ($isG) { if ($n -gt $gc) { $gc = $n; $gpuLuid = $luid } } else { if ($n -gt $nc) { $nc = $n; $npuLuid = $luid } }
    }
    $sync.gsel = @(foreach ($l in $ad.Keys) { "$l n=$($ad[$l].eng.Count) types=$(@($ad[$l].types.Keys) -join '/') picked=$(if ($l -eq $gpuLuid) {'GPU'} elseif ($l -eq $npuLuid) {'NPU'} else {'-'})" })
    $util = { param($a) if ($null -eq $a) { return $null }; $mx = 0; foreach ($v in $a.eng.Values) { if ($v -gt $mx) { $mx = $v } }; [math]::Round([math]::Min(100, $mx), 1) }
    $top = { param($a)
      $o = @(); if ($null -eq $a) { return ,$o }
      foreach ($kv in ($a.procs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)) {
        $pidv = [int]$kv.Key
        if (-not $hw.names.ContainsKey($pidv)) { $pr = Get-Process -Id $pidv -ErrorAction SilentlyContinue; if ($pr) { $hw.names[$pidv] = $pr.ProcessName } else { $hw.names[$pidv] = "pid $pidv" } }
        $o += [ordered]@{ pid = $pidv; name = $hw.names[$pidv]; util = [math]::Round([math]::Min(100, $kv.Value), 1) }
      }
      return ,$o }
    $gA = $null; if ($gpuLuid) { $gA = $ad[$gpuLuid] }
    $nA = $null; if ($npuLuid) { $nA = $ad[$npuLuid] }
    $engTypes = @{}
    if ($gA) { foreach ($kv in $gA.eng.GetEnumerator()) { $t = ($kv.Key.Split('|')[1]) -replace '_\d+$', ''; $v = [math]::Round([math]::Min(100, $kv.Value), 1); if (-not $engTypes.ContainsKey($t) -or $engTypes[$t] -lt $v) { $engTypes[$t] = $v } } }
    $ded = $null; $sh = $null
    foreach ($m in (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory)) {
      if ($m.Name -match 'luid_(0x[0-9a-fA-F]+_0x[0-9a-fA-F]+)' -and $Matches[1].ToLower() -eq $gpuLuid) { $ded += [double]$m.DedicatedUsage; $sh += [double]$m.SharedUsage }
    }
    $cpuU = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    $os = Get-CimInstance Win32_OperatingSystem
    $tot = [double]$os.TotalVisibleMemorySize * 1KB / 1GB; $fr = [double]$os.FreePhysicalMemory * 1KB / 1GB
    $dedGB = $null; if ($null -ne $ded) { $dedGB = [math]::Round($ded / 1GB, 2) }
    $shGB = $null; if ($null -ne $sh) { $shGB = [math]::Round($sh / 1GB, 2) }
    $npuName = $null; $npuStatus = $null; if ($hw.npu) { $npuName = $hw.npu.Name; $npuStatus = $hw.npu.Status }
    return [ordered]@{
      ok = $true
      cpu = [ordered]@{ name = $hw.cpuName; threads = $hw.threads; util = [double]$cpuU }
      ram = [ordered]@{ totalGB = [math]::Round($tot, 1); usedGB = [math]::Round($tot - $fr, 1) }
      gpu = [ordered]@{ name = $hw.gpuName; util = (& $util $gA); engines = $engTypes; procs = (& $top $gA); dedicatedGB = $dedGB; sharedGB = $shGB; dedicatedTotalGB = $hw.gpuTotal }
      npu = [ordered]@{ present = [bool]$hw.npu; found = [bool]$nA; name = $npuName; status = $npuStatus; util = (& $util $nA); procs = (& $top $nA) }
    }
  }

  function Send-Bytes($res, [byte[]]$bytes, [string]$type, [int]$code) {
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.ContentLength64 = $bytes.Length
    try { $res.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
    try { $res.Close() } catch {}
  }
  function Send-Json($res, $obj, [int]$code = 200) {
    $json = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
    Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $code
  }
  function Read-Body($req) {
    if (-not $req.HasEntityBody) { return [pscustomobject]@{} }
    $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
    $t = $sr.ReadToEnd(); $sr.Close()
    if (-not $t) { return [pscustomobject]@{} }
    return ($t | ConvertFrom-Json)
  }

  # clean up engines left running by an earlier session
  try {
    $engDir = Join-Path $sync.data 'engine'
    Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($engDir) } | Stop-Process -Force -ErrorAction SilentlyContinue
  } catch {}

  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add($sync.url)
  try { $listener.Start() } catch { $sync.error = "Could not start on port $($sync.port): $($_.Exception.Message)"; return }
  $sync.ready = $true

  while ($listener.IsListening -and -not $sync.stop) {
    try { $ctx = $listener.GetContext() } catch { break }
    $req = $ctx.Request; $res = $ctx.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    $res.Headers.Add('Access-Control-Allow-Private-Network', 'true')
    $res.Headers.Add('Cache-Control', 'no-store')
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    try {
      if ($method -eq 'OPTIONS') { $res.StatusCode = 204; $res.Close(); continue }
      switch -Regex ($path) {
        '^/$|^/index\.html$' {
          $f = Join-Path $sync.root 'Halo Lab.html'
          Send-Bytes $res ([IO.File]::ReadAllBytes($f)) 'text/html; charset=utf-8' 200; break }
        '^/halo-lab-icon\.png$' {
          $f = Join-Path $sync.root 'halo-lab-icon.png'
          if (Test-Path $f) { Send-Bytes $res ([IO.File]::ReadAllBytes($f)) 'image/png' 200 } else { Send-Json $res @{ error = 'not found' } 404 }; break }
        '^/stats$' {
          try { Send-Json $res (Get-Stats) } catch { Send-Json $res ([ordered]@{ ok = $false; error = $_.Exception.Message }) }; break }
        '^/v1/' {
          # chat goes through here so the page only ever talks to Halo Lab itself
          Start-Bg $sync.proxyCode @($sync, $ctx); break }
        '^/api/hl/gpudebug$' {
          $rows = @()
          $ad = @{}
          $rawNames = @()
          foreach ($e in (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine)) {
            if ($rawNames.Count -lt 12 -and [double]$e.UtilizationPercentage -gt 0) { $rawNames += $e.Name }
            if ($e.Name -notmatch 'luid_(0x[0-9a-fA-F]+_0x[0-9a-fA-F]+)_phys_\d+_eng_(\d+)_engtype_(.*)$') { continue }
            $k = $Matches[1].ToLower() + '|' + $Matches[3]
            if (-not $ad.ContainsKey($k)) { $ad[$k] = 0.0 }
            $ad[$k] += [double]$e.UtilizationPercentage
          }
          foreach ($kv in $ad.GetEnumerator()) { $rows += [ordered]@{ key = $kv.Key; util = $kv.Value } }
          $mem = @()
          foreach ($m in (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory)) { $mem += [ordered]@{ name = $m.Name; ded = $m.DedicatedUsage; sh = $m.SharedUsage } }
          $vc = @(Get-CimInstance Win32_VideoController | ForEach-Object { [ordered]@{ name = $_.Name; pnp = $_.PNPDeviceID } })
          Send-Json $res ([ordered]@{ engines = ($rows | Sort-Object { $_.key }); memory = $mem; controllers = $vc; busyNames = $rawNames; selection = $sync.gsel }); break }
        '^/api/hl/log$' {
          $txt = (@(Get-LogTail 200) -join "`n")
          if ($sync.devText) { $txt = "--- devices ---`n" + $sync.devText + "`n--- engine log ---`n" + $txt }
          Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes($txt)) 'text/plain; charset=utf-8' 200; break }
        '^/api/hl/ping$' { Send-Json $res @{ ok = $true; app = 'halo-lab' }; break }
        '^/api/hl/status$' { Send-Json $res (Get-Status); break }
        '^/api/hl/engine/install$' {
          $ej = $sync.engineJob
          if (-not ($ej.status -and $ej.status -ne 'done' -and $ej.status -ne 'failed')) {
            $ej.status = 'Starting'; $ej.error = $null; $ej.done = 0L; $ej.total = 0L; $ej.baseDone = 0L; $ej.cancel = $false
            Start-Bg $sync.engineCode @($sync)
          }
          Send-Json $res @{ ok = $true }; break }
        '^/api/hl/pull$' {
          $b = Read-Body $req
          if (-not $b.id -or -not $b.repo) { Send-Json $res @{ error = 'id and repo are required' } 400; break }
          $cur = $sync.dl[$b.id]
          if ($cur -and $cur.status -ne 'done' -and $cur.status -ne 'failed' -and $cur.status -ne 'cancelled') { Send-Json $res @{ ok = $true }; break }
          $quant = 'Q4_K_M'; if ($b.quant) { $quant = [string]$b.quant }
          $name = [string]$b.id; if ($b.name) { $name = [string]$b.name }
          $sync.dl[$b.id] = [hashtable]::Synchronized(@{ status = 'Starting'; repo = [string]$b.repo; quant = $quant; vision = [bool]$b.vision; name = $name; done = 0L; total = 0L; baseDone = 0L; fileDone = 0L; cancel = $false; error = $null })
          Start-Bg $sync.pullCode @($sync, [string]$b.id)
          Send-Json $res @{ ok = $true }; break }
        '^/api/hl/cancel$' {
          $b = Read-Body $req; $d = $sync.dl[$b.id]
          if ($d) { $d.cancel = $true }
          Send-Json $res @{ ok = $true }; break }
        '^/api/hl/dismiss$' {
          $b = Read-Body $req; $d = $sync.dl[$b.id]
          if ($d -and ($d.status -eq 'done' -or $d.status -eq 'failed')) { $sync.dl.Remove($b.id) }
          Send-Json $res @{ ok = $true }; break }
        '^/api/hl/delete$' {
          $b = Read-Body $req
          if ($sync.srv.model -eq $b.id) { Stop-Model }
          $m = Get-Models | Where-Object { $_.id -eq $b.id } | Select-Object -First 1
          $dir = $null
          if ($m) { $dir = $m.dir } else { $dir = Join-Path (Get-ModelsDir $sync) (Get-SafeName $b.id) }
          if ($dir -and (Test-Path $dir)) { Start-Sleep -Milliseconds 300; Remove-Item $dir -Recurse -Force }
          $sync.dl.Remove($b.id)
          Send-Json $res @{ ok = $true }; break }
        '^/api/hl/load$' {
          $b = Read-Body $req
          $ctxN = 8192; if ($b.ctx) { $ctxN = [int]$b.ctx }
          $s = $sync.srv
          if ($s.model -eq $b.id -and $s.ctx -eq $ctxN -and ($s.state -eq 'ready' -or $s.state -eq 'loading')) { Send-Json $res @{ ok = $true }; break }
          try { Start-Model ([string]$b.id) $ctxN; Send-Json $res @{ ok = $true } }
          catch { Send-Json $res @{ error = $_.Exception.Message } 400 }
          break }
        '^/api/hl/unload$' { Stop-Model; Send-Json $res @{ ok = $true }; break }
        '^/api/hl/config$' {
          $b = Read-Body $req
          $dir = [string]$b.modelsDir
          if ($dir) {
            try { if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
            catch { Send-Json $res @{ error = "Couldn't use that folder: $($_.Exception.Message)" } 400; break }
          }
          $cfg = [ordered]@{ modelsDir = $dir }
          ($cfg | ConvertTo-Json) | Set-Content -Path (Join-Path $sync.data 'config.json') -Encoding UTF8
          Send-Json $res @{ ok = $true }; break }
        '^/api/hl/quit$' {
          Stop-Model
          Send-Json $res @{ ok = $true }
          $sync.stop = $true; break }
        default { Send-Json $res @{ error = 'not found' } 404 }
      }
    } catch {
      try { Send-Json $res @{ error = $_.Exception.Message } 500 } catch {}
    }
  }
  Stop-Model
  try { $listener.Stop(); $listener.Close() } catch {}
  $sync.stopped = $true
}

# ---------- start ----------
$sync = [hashtable]::Synchronized(@{
  root = $Root; data = $Data; port = $Port; url = $Url; isWin = $IsWin
  lib = $Lib; engineCode = $EngineJob.ToString(); pullCode = $PullJob.ToString(); proxyCode = $ProxyJob.ToString()
  jobs = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
  dl = [hashtable]::Synchronized(@{})
  engineJob = [hashtable]::Synchronized(@{ status = $null; done = 0L; total = 0L; baseDone = 0L; cancel = $false; error = $null })
  srv = [hashtable]::Synchronized(@{ state = 'stopped' })
  ready = $false; stop = $false; stopped = $false; error = $null; hw = $null
})

$ps = [powershell]::Create()
[void]$ps.AddScript($ServerCode).AddArgument($sync)
$handle = $ps.BeginInvoke()

$waited = 0
while (-not $sync.ready -and -not $sync.error -and $waited -lt 100) { Start-Sleep -Milliseconds 100; $waited++ }
if ($sync.error -or -not $sync.ready) {
  $msg = $sync.error; if (-not $msg) { $msg = 'Halo Lab could not start.' }
  try { foreach ($e in $ps.Streams.Error) { $msg += "`n" + $e.ToString() } } catch {}
  if ($IsWin) { Add-Type -AssemblyName System.Windows.Forms; . ([scriptblock]::Create('[void][Windows.Forms.MessageBox]::Show($msg, "Halo Lab")')) } else { Write-Host $msg }
  exit 1
}
if (-not $NoBrowser) { Start-Process $Url }
Write-Host "Halo Lab is running at $Url"

if ($IsWin) {
  # tray icon: Open / Quit (built at run time so the file also loads on non-Windows test machines)
  $TrayCode = @'
  # tray icon: Open / Quit
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $ni = New-Object Windows.Forms.NotifyIcon
  $ico = Join-Path $Root 'Halo Lab.ico'
  if (Test-Path $ico) { $ni.Icon = New-Object Drawing.Icon($ico) } else { $ni.Icon = [Drawing.SystemIcons]::Application }
  $ni.Text = 'Halo Lab'
  $menu = New-Object Windows.Forms.ContextMenuStrip
  $open = $menu.Items.Add('Open Halo Lab'); $open.add_Click({ Start-Process $Url })
  $unl = $menu.Items.Add('Unload model (free GPU memory)')
  $unl.add_Click({ try { Invoke-WebRequest -UseBasicParsing -Method Post -TimeoutSec 5 ($Url + 'api/hl/unload') | Out-Null } catch {} })
  [void]$menu.Items.Add('-')
  $quit = $menu.Items.Add('Quit Halo Lab')
  $quit.add_Click({
    try { Invoke-WebRequest -UseBasicParsing -Method Post -TimeoutSec 5 ($Url + 'api/hl/quit') | Out-Null } catch {}
    $sync.stop = $true
    [Windows.Forms.Application]::Exit()
  })
  $ni.ContextMenuStrip = $menu
  $ni.add_DoubleClick({ Start-Process $Url })
  $ni.Visible = $true
  $ni.ShowBalloonTip(4000, 'Halo Lab is running', 'Right-click this icon to open or quit Halo Lab.', [Windows.Forms.ToolTipIcon]::Info)
  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = 1000
  $timer.add_Tick({ if ($sync.stop) { [Windows.Forms.Application]::Exit() } })
  $timer.Start()
  [Windows.Forms.Application]::Run()
  $timer.Stop(); $ni.Visible = $false; $ni.Dispose()
  $sync.stop = $true
  try { Invoke-WebRequest -UseBasicParsing -Method Post -TimeoutSec 3 ($Url + 'api/hl/quit') | Out-Null } catch {}
'@
  . ([scriptblock]::Create($TrayCode))
} else {
  while (-not $sync.stop) { Start-Sleep -Milliseconds 300 }
}
$w = 0; while (-not $sync.stopped -and $w -lt 30) { Start-Sleep -Milliseconds 100; $w++ }
