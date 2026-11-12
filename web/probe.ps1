# iof probe: can this PC reach the iof nodes? (Island of Freedom, iof audit probe)
#
# The iof-web panel builds this script for one check. Embedded below: the nodes, their temporary
# probe targets with certificate fingerprints, a token for the targets and a one-time ticket for
# the report. The script only collects a raw trace per layer and sends it back to the panel; the
# verdict is computed on the control server (iof audit probe import).
#
# Layers per node: ping, TCP, TLS (the target certificate is checked by fingerprint), 256 KB of
# data, UDP, UDP that looks like QUIC, the Hysteria2 port (QUIC version negotiation) and, if you
# agree, a real Hysteria2 tunnel with hysteria.exe and the hy2:// links you copied on the
# Hysteria2 page. Two control lists of sites show whether this PC has internet at all and whether
# the provider filters. Passwords from the links never leave this PC.
#
# Turn VPN and proxy off on this PC first: the point is to see what your provider lets through.
# Save it to a file and run it with -File, as the panel suggests. Do not pipe it into iex: antivirus
# software rightly blocks download-and-run, and a file can be read before it is run.
# Works in Windows PowerShell 5.1 and PowerShell 7. Environment variables:
#   IOF_HYSTERIA   path to hysteria.exe (default: current folder, then PATH)
#   IOF_PROBE_MAP  node=host:port[:hy2port],... replaces node addresses (iof test stand only)
#
# This file is plain ASCII on purpose: Windows PowerShell 5.1 reads scripts without BOM in the
# ANSI code page.

$IofProbeConfig = '__IOF_PROBE_CONFIG__'

$IofFull = 262144

function Get-IofNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Get-IofRandom([int]$n) {
  $b = New-Object byte[] $n
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  return ,$b
}

function Get-IofHex([byte[]]$b) { ([BitConverter]::ToString($b) -replace '-', '').ToLowerInvariant() }

# Short reason from an error record: timeout, refused, reset, unreachable or the message
function Get-IofError($e) {
  $x = $e
  if ($e -is [Management.Automation.ErrorRecord]) { $x = $e.Exception }
  while ($x.InnerException) { $x = $x.InnerException }
  if ($x -is [Net.Sockets.SocketException]) {
    switch ($x.SocketErrorCode.ToString()) {
      'TimedOut' { return 'timeout' }
      'ConnectionRefused' { return 'refused' }
      'ConnectionReset' { return 'reset' }
      'HostUnreachable' { return 'unreachable' }
      'NetworkUnreachable' { return 'unreachable' }
      default { return $x.SocketErrorCode.ToString().ToLowerInvariant() }
    }
  }
  if ($x -is [Security.Authentication.AuthenticationException]) { return 'handshake failed' }
  $m = [string]$x.Message
  if ($m.Length -gt 60) { $m = $m.Substring(0, 60) }
  return $m.ToLowerInvariant()
}

function Get-IofMap {
  $map = @{}
  if (-not $env:IOF_PROBE_MAP) { return $map }
  foreach ($item in $env:IOF_PROBE_MAP.Split(',')) {
    if ($item.Trim() -match '^([A-Za-z0-9._-]+)=([A-Za-z0-9.-]+):([0-9]+)(?::([0-9]+))?$') {
      $hy2 = 0
      if ($Matches[4]) { $hy2 = [int]$Matches[4] }
      $map[$Matches[1]] = @{ host = $Matches[2]; port = [int]$Matches[3]; hy2 = $hy2 }
    } elseif ($item.Trim()) {
      Write-Host "IOF_PROBE_MAP: skipped '$item', expected node=host:port[:hy2port]" -ForegroundColor Yellow
    }
  }
  return $map
}

function Test-IofIcmp([string]$ip) {
  $p = New-Object Net.NetworkInformation.Ping
  $got = 0
  $sum = 0
  for ($i = 0; $i -lt 3; $i++) {
    try {
      $x = $p.Send($ip, 2000)
      if ($x.Status -eq [Net.NetworkInformation.IPStatus]::Success) { $got++; $sum += [int]$x.RoundtripTime }
    } catch { }
  }
  $avg = 0
  if ($got) { $avg = [int]($sum / $got) }
  return [ordered]@{ sent = 3; got = $got; ms = $avg }
}

# TLS on a connected stream, the token line, then "OK <source IP>" and 256 KB. Fills $r
function Invoke-IofExchange($stream, [string]$ip, [string]$fp, [string]$token, $r) {
  $accept = [Net.Security.RemoteCertificateValidationCallback]{ $true }
  $ssl = New-Object Net.Security.SslStream($stream, $false, $accept)
  $ssl.ReadTimeout = 6000
  $ssl.WriteTimeout = 6000
  $stage = 'tls'
  $n = 0
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    # An IP address as the target name: no SNI, the same as the control check on the server
    $ssl.AuthenticateAsClient($ip, $null, [Security.Authentication.SslProtocols]::Tls12, $false)
    $r.tls = [int]$sw.ElapsedMilliseconds
    $sha = [Security.Cryptography.SHA256]::Create()
    if ((Get-IofHex $sha.ComputeHash($ssl.RemoteCertificate.GetRawCertData())) -eq $fp) { $r.fp = 'match' } else { $r.fp = 'mismatch' }
    $stage = 'data'
    $sw.Restart()
    $line = [Text.Encoding]::ASCII.GetBytes("IOF-PROBE $token`n")
    $ssl.Write($line, 0, $line.Length)
    $ssl.Flush()
    $buf = New-Object byte[] 65536
    $head = New-Object IO.MemoryStream
    $inHead = $true
    while (($inHead -or $n -lt $IofFull) -and $sw.ElapsedMilliseconds -lt 20000) {
      $k = $ssl.Read($buf, 0, $buf.Length)
      if ($k -le 0) { $r.err = 'data: closed'; break }
      if (-not $inHead) { $n += $k; continue }
      $nl = [Array]::IndexOf($buf, [byte]10, 0, $k)
      if ($nl -lt 0) {
        $head.Write($buf, 0, $k)
        if ($head.Length -gt 128) { break }
        continue
      }
      $head.Write($buf, 0, $nl)
      $inHead = $false
      $n += $k - $nl - 1
    }
    $h = [Text.Encoding]::ASCII.GetString($head.ToArray())
    if ($inHead -or -not $h.StartsWith('OK ')) {
      if (-not $r.err) { $r.err = 'data: no answer' }
    } else {
      $r.src = $h.Substring(3).Trim()
      if ($n -lt $IofFull -and -not $r.err) { $r.err = 'data: timeout' }
    }
  } catch {
    $r.err = $stage + ': ' + (Get-IofError $_)
  } finally {
    if ($stage -eq 'data') { $r.bytes = [Math]::Min($n, $IofFull); $r.ms = [int]$sw.ElapsedMilliseconds }
    $ssl.Dispose()
  }
}

function New-IofConnResult { [ordered]@{ tcp = $null; tls = $null; fp = ''; bytes = 0; ms = 0; src = ''; err = '' } }

function Test-IofConn([string]$ip, [int]$port, [string]$fp, [string]$token) {
  $r = New-IofConnResult
  $c = New-Object Net.Sockets.TcpClient
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ar = $c.BeginConnect($ip, $port, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne(5000)) {
      $r.err = 'tcp: timeout'
    } else {
      $c.EndConnect($ar)
      $r.tcp = [int]$sw.ElapsedMilliseconds
      Invoke-IofExchange $c.GetStream() $ip $fp $token $r
    }
  } catch {
    $r.err = 'tcp: ' + (Get-IofError $_)
  } finally {
    $c.Close()
  }
  return $r
}

# The same packets as the control check (iof AUDIT_NET_PY): the mark IOFP<token> and a nonce,
# either small or 1200 bytes behind a QUIC v1 Initial-like header. The target sends the packet
# back with the token zeroed
function New-IofPacket([bool]$quic, [byte[]]$mark, [byte[]]$nonce) {
  $ms = New-Object IO.MemoryStream
  if ($quic) {
    $h = [byte[]](0xC3, 0, 0, 0, 1, 8)
    $ms.Write($h, 0, $h.Length)
    $x = Get-IofRandom 8
    $ms.Write($x, 0, 8)
    $ms.WriteByte(8)
    $x = Get-IofRandom 8
    $ms.Write($x, 0, 8)
    $h = [byte[]](0, 0x44, 0xB0)
    $ms.Write($h, 0, 3)
  }
  $ms.Write($mark, 0, $mark.Length)
  $ms.Write($nonce, 0, $nonce.Length)
  $pad = 24
  if ($quic) { $pad = 1200 - [int]$ms.Length }
  $x = Get-IofRandom $pad
  $ms.Write($x, 0, $pad)
  return ,$ms.ToArray()
}

function Test-IofUdp([string]$ip, [int]$port, [string]$token, [bool]$quic) {
  $mark = [Text.Encoding]::ASCII.GetBytes('IOFP' + $token)
  $at = 0
  if ($quic) { $at = 26 }
  $sent = @{}
  $got = @{}
  $closed = $false
  $u = New-Object Net.Sockets.UdpClient
  try {
    $u.Connect($ip, $port)
    for ($i = 0; $i -lt 5; $i++) {
      $nonce = Get-IofRandom 8
      $sent[(Get-IofHex $nonce)] = $true
      $p = New-IofPacket $quic $mark $nonce
      try { [void]$u.Send($p, $p.Length) } catch { $closed = $true }
      Start-Sleep -Milliseconds 50
    }
    $u.Client.ReceiveTimeout = 300
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 2000 -and $got.Count -lt 5) {
      $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
      try { $d = $u.Receive([ref]$ep) } catch { if ((Get-IofError $_) -eq 'reset') { $closed = $true }; continue }
      if ($d.Length -lt $at + 44 -or [Text.Encoding]::ASCII.GetString($d, $at, 4) -ne 'IOFP') { continue }
      $zero = $true
      for ($j = 4; $j -lt 36; $j++) { if ($d[$at + $j] -ne 0) { $zero = $false; break } }
      if (-not $zero) { continue }
      $hex = Get-IofHex ([byte[]]$d[($at + 36)..($at + 43)])
      if ($sent.ContainsKey($hex)) { $got[$hex] = $true }
    }
  } catch {
    $closed = $true
  } finally {
    $u.Close()
  }
  return [ordered]@{ sent = 5; got = $got.Count; closed = $closed }
}

# QUIC packet with a reserved version: a QUIC server must answer with Version Negotiation.
# vn - it did, reply - something else answered, silent - nothing (Salamander or filtered), closed
function Test-IofQuicVn([string]$ip, [int]$port) {
  $seen = 'silent'
  for ($t = 0; $t -lt 3; $t++) {
    $u = New-Object Net.Sockets.UdpClient
    try {
      $u.Client.ReceiveTimeout = 1500
      $u.Connect($ip, $port)
      $scid = Get-IofRandom 8
      $ms = New-Object IO.MemoryStream
      $ms.WriteByte([byte](0xC0 -bor ((Get-IofRandom 1)[0] -band 0x0F)))
      $h = [byte[]](0x1a, 0x2a, 0x3a, 0x4a, 8)
      $ms.Write($h, 0, $h.Length)
      $x = Get-IofRandom 8
      $ms.Write($x, 0, 8)
      $ms.WriteByte(8)
      $ms.Write($scid, 0, 8)
      $x = Get-IofRandom (1200 - [int]$ms.Length)
      $ms.Write($x, 0, $x.Length)
      $p = $ms.ToArray()
      [void]$u.Send($p, $p.Length)
      $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
      $d = $u.Receive([ref]$ep)
      if ($d.Length -ge 14 -and ($d[0] -band 0x80) -and $d[1] -eq 0 -and $d[2] -eq 0 -and $d[3] -eq 0 -and $d[4] -eq 0 `
          -and $d[5] -eq 8 -and (Get-IofHex ([byte[]]$d[6..13])) -eq (Get-IofHex $scid)) { return 'vn' }
      $seen = 'reply'
    } catch {
      if ((Get-IofError $_) -eq 'reset') { $seen = 'closed' }
    } finally {
      $u.Close()
    }
  }
  return $seen
}

# A site from the control lists: DNS, TCP 443 and a TLS handshake with a valid certificate
function Test-IofSite([string]$name, [string]$list) {
  $r = [ordered]@{ host = $name; list = $list; ok = $false; err = '' }
  $a = $null
  try { $a = [Net.Dns]::GetHostAddresses($name) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 } catch { }
  if (-not $a) { $r.err = 'dns'; return $r }
  $c = New-Object Net.Sockets.TcpClient
  $stage = 'tcp'
  try {
    $ar = $c.BeginConnect($a, 443, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne(5000)) { $r.err = 'tcp: timeout'; return $r }
    $c.EndConnect($ar)
    $stage = 'tls'
    $state = @{ errors = 'None' }
    $check = [Net.Security.RemoteCertificateValidationCallback]({ param($s, $cert, $chain, $errs) $state.errors = [string]$errs; $true }.GetNewClosure())
    $ssl = New-Object Net.Security.SslStream($c.GetStream(), $false, $check)
    $ssl.ReadTimeout = 6000
    $ssl.WriteTimeout = 6000
    $ssl.AuthenticateAsClient($name, $null, [Security.Authentication.SslProtocols]::Tls12, $false)
    if ($state.errors -ne 'None') { $r.err = 'cert: ' + $state.errors.ToLowerInvariant() } else { $r.ok = $true }
    $ssl.Dispose()
  } catch {
    $r.err = $stage + ': ' + (Get-IofError $_)
  } finally {
    $c.Close()
  }
  return $r
}

# Adapters that look like a VPN (only their descriptions go into the report) and the system proxy
function Get-IofClient {
  $vpn = New-Object Collections.ArrayList
  try {
    foreach ($a in (Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
      if ("$($a.Name) $($a.InterfaceDescription)" -match 'WireGuard|Wintun|TAP-Windows|OpenVPN|Amnezia|Hysteria|sing-box|Clash|Outline|V2Ray|Xray|\bTUN\b|VPN') {
        [void]$vpn.Add([string]$a.InterfaceDescription)
      }
    }
  } catch { }
  $proxy = 'none'
  try {
    $is = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    if ($is.AutoConfigURL) { $proxy = 'pac' } elseif ($is.ProxyEnable -eq 1) { $proxy = 'manual' }
  } catch { }
  return [ordered]@{ os = 'Windows ' + [Environment]::OSVersion.Version.ToString(); ps = $PSVersionTable.PSVersion.ToString(); vpn = $vpn; proxy = $proxy }
}

function Find-IofHysteria {
  $paths = @()
  if ($env:IOF_HYSTERIA) { $paths += $env:IOF_HYSTERIA }
  $here = (Get-Location).ProviderPath
  $paths += (Join-Path $here 'hysteria.exe'), (Join-Path $here 'hysteria-windows-amd64.exe')
  foreach ($p in $paths) {
    if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return (Resolve-Path -LiteralPath $p).ProviderPath }
  }
  foreach ($name in 'hysteria.exe', 'hysteria-windows-amd64.exe') {
    $g = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.Source }
  }
  return ''
}

# Which nodes get the tunnel test: hy2:// links from the clipboard matched by address and port.
# Relay links have another address or port and are skipped
function Get-IofTunnelPlan($targets, $map) {
  $plan = @{ exe = ''; links = @{}; reason = '' }
  $exe = Find-IofHysteria
  if (-not $exe) { $plan.reason = 'nohysteria'; return $plan }
  $clip = ''
  try { $clip = [string](Get-Clipboard -Raw) } catch { }
  foreach ($m in [regex]::Matches($clip, '(?:hy2|hysteria2)://\S+')) {
    $link = $m.Value
    if ($link -notmatch '^[a-z0-9]+://[^@/\s]*@([^/?#]+)') { continue }
    $hp = $Matches[1]
    $h = $hp
    $p = ''
    if ($hp -match '^(.+):([0-9,-]+)$') { $h = $Matches[1]; $p = $Matches[2] }
    foreach ($t in $targets) {
      if ($plan.links.ContainsKey([string]$t.node)) { continue }
      if ($h -ne [string]$t.addr -and $h -ne [string]$t.ip) { continue }
      if ($p -match '^[0-9]+$' -and [int]$p -ne [int]$t.hy2) { continue }
      $use = $link
      if ($map.ContainsKey([string]$t.node)) {
        if (-not $map[[string]$t.node].hy2) { continue }
        $use = $link.Replace("@$hp", '@' + $map[[string]$t.node].host + ':' + $map[[string]$t.node].hy2)
      }
      $plan.links[[string]$t.node] = $use
    }
  }
  if ($plan.links.Count -eq 0) { $plan.reason = 'nolinks'; return $plan }
  Write-Host ''
  Write-Host "Found hy2:// links for $($plan.links.Count) node(s) in the clipboard and $exe."
  Write-Host 'The tunnel layer runs the real Hysteria2 client with these links. The passwords stay on this PC:'
  Write-Host 'each link goes into a temporary config that is deleted right after its test, and is not sent anywhere.'
  $answer = ''
  try { $answer = Read-Host 'Test real Hysteria2 tunnels? [y/N]' } catch { }
  if ($answer -notmatch '^(y|yes)$') { $plan.reason = 'declined'; $plan.links = @{}; return $plan }
  $plan.exe = $exe
  return $plan
}

function Read-IofExact($s, [int]$n) {
  $b = New-Object byte[] $n
  $got = 0
  while ($got -lt $n) {
    $k = $s.Read($b, $got, $n - $got)
    if ($k -le 0) { throw 'socks: closed' }
    $got += $k
  }
  return ,$b
}

function Connect-IofSocks([int]$socks, [string]$ip, [int]$port) {
  $c = New-Object Net.Sockets.TcpClient
  $c.Connect('127.0.0.1', $socks)
  $s = $c.GetStream()
  $s.ReadTimeout = 10000
  $s.WriteTimeout = 10000
  $hello = [byte[]](5, 1, 0)
  $s.Write($hello, 0, 3)
  $b = Read-IofExact $s 2
  if ($b[0] -ne 5 -or $b[1] -ne 0) { throw 'socks: no usable auth method' }
  $req = [byte[]](@(5, 1, 0, 1) + [Net.IPAddress]::Parse($ip).GetAddressBytes() + @([byte]($port -shr 8), [byte]($port -band 255)))
  $s.Write($req, 0, $req.Length)
  $b = Read-IofExact $s 4
  if ($b[1] -ne 0) { throw "socks: reply $($b[1])" }
  switch ($b[3]) {
    1 { [void](Read-IofExact $s 6) }
    4 { [void](Read-IofExact $s 18) }
    3 { $l = (Read-IofExact $s 1)[0]; [void](Read-IofExact $s ($l + 2)) }
  }
  return $c
}

function Get-IofLogTail([string[]]$files) {
  $line = ''
  foreach ($f in $files) {
    try { $t = Get-Content -LiteralPath $f -Tail 3 -ErrorAction Stop | Where-Object { $_.Trim() } | Select-Object -Last 1; if ($t) { $line = [string]$t } } catch { }
  }
  $line = $line -replace '(?:hy2|hysteria2)://\S+', '<link>'
  if ($line.Length -gt 120) { $line = $line.Substring(0, 120) }
  return $line
}

# The real tunnel: hysteria.exe with the node link and a local SOCKS5, then through it to the node's
# own target (TLS, token, 256 KB). The target sees the node itself as the source
function Test-IofTunnel($plan, $t, [string]$token) {
  if (-not $plan.exe) { return [ordered]@{ tested = $false; reason = $plan.reason } }
  if (-not $plan.links.ContainsKey([string]$t.node)) { return [ordered]@{ tested = $false; reason = 'nolink' } }
  $r = [ordered]@{ tested = $true; ok = $false; ms = 0; bytes = 0; src = ''; err = '' }
  $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $l.Start()
  $socks = $l.LocalEndpoint.Port
  $l.Stop()
  $base = Join-Path $env:TEMP ('iof-probe-' + (Get-IofHex (Get-IofRandom 6)))
  $files = @("$base.yaml", "$base.out.log", "$base.err.log")
  $proc = $null
  $c = $null
  try {
    $link = $plan.links[[string]$t.node].Replace('"', '%22')
    [IO.File]::WriteAllText($files[0], "server: `"$link`"`nsocks5:`n  listen: 127.0.0.1:$socks`n")
    $proc = Start-Process -FilePath $plan.exe -ArgumentList @('client', '-c', "`"$($files[0])`"") -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $files[1] -RedirectStandardError $files[2]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $up = $false
    while ($sw.ElapsedMilliseconds -lt 12000 -and -not $proc.HasExited) {
      try { $probe = New-Object Net.Sockets.TcpClient; $probe.Connect('127.0.0.1', $socks); $probe.Close(); $up = $true; break } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $up) {
      $why = Get-IofLogTail $files[1..2]
      if (-not $why) { $why = 'no answer' }
      $r.err = 'client: ' + $why
      return $r
    }
    $conn = New-IofConnResult
    $sw.Restart()
    $c = Connect-IofSocks $socks ([string]$t.ip) ([int]$t.port)
    Invoke-IofExchange $c.GetStream() ([string]$t.ip) ([string]$t.fp) $token $conn
    $r.ms = [int]$sw.ElapsedMilliseconds
    $r.bytes = $conn.bytes
    $r.src = $conn.src
    $r.err = $conn.err
    $r.ok = ($conn.bytes -ge $IofFull -and $conn.fp -eq 'match')
  } catch {
    $r.err = 'tunnel: ' + (Get-IofError $_)
  } finally {
    if ($c) { $c.Close() }
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill(); [void]$proc.WaitForExit(3000) } catch { } }
    Remove-Item -LiteralPath $files -Force -ErrorAction SilentlyContinue
  }
  return $r
}

function Format-IofLine($r) {
  $tcp = @($r.conn | Where-Object { $null -ne $_.tcp }).Count
  $tls = @($r.conn | Where-Object { $null -ne $_.tls }).Count
  $data = @($r.conn | Where-Object { $_.bytes -ge $IofFull }).Count
  $s = "ping $($r.icmp.got)/$($r.icmp.sent)  tcp $tcp/3  tls $tls/3  data $data/3  udp $($r.udp.got)/5  quic $($r.quic.got)/5"
  if (@($r.conn | Where-Object { $_.fp -eq 'mismatch' }).Count) { $s += '  CERT REPLACED' }
  if ($r.hy2) { $s += "  hy2 $($r.hy2)" }
  if ($r.tunnel.tested) { if ($r.tunnel.ok) { $s += '  tunnel ok' } else { $s += '  tunnel failed' } }
  return $s
}

function Send-IofReport($cfg, $report) {
  $json = $report | ConvertTo-Json -Depth 8 -Compress
  Write-Host ''
  Write-Host "Sending the report to $($cfg.origin) ..." -NoNewline
  try {
    $req = [Net.HttpWebRequest]::Create("$($cfg.origin)/api/probe/result?t=$($cfg.ticket)")
    $req.Method = 'POST'
    $req.Proxy = $null
    $req.ContentType = 'application/json'
    $req.Timeout = 30000
    $req.Headers.Add('X-IOF-Request', '1')
    $body = [Text.Encoding]::UTF8.GetBytes($json)
    $req.ContentLength = $body.Length
    $s = $req.GetRequestStream()
    $s.Write($body, 0, $body.Length)
    $s.Close()
    $req.GetResponse().Close()
    Write-Host ' done.' -ForegroundColor Green
    Write-Host 'The verdict is on the panel: page Security, card with the check from this PC.'
    return
  } catch {
    $why = Get-IofError $_
    $we = $_.Exception
    while ($we -and -not ($we -is [Net.WebException])) { $we = $we.InnerException }
    if ($we -and $we.Response) {
      try { $why = 'HTTP ' + [int]$we.Response.StatusCode + ' ' + (New-Object IO.StreamReader($we.Response.GetResponseStream())).ReadToEnd() } catch { }
    }
    Write-Host " failed: $why" -ForegroundColor Red
  }
  $file = Join-Path (Get-Location).ProviderPath 'iof-probe-report.json'
  try { [IO.File]::WriteAllText($file, $json) } catch { $file = Join-Path $env:TEMP 'iof-probe-report.json'; [IO.File]::WriteAllText($file, $json) }
  Write-Host "The report is saved to $file"
  Write-Host 'Copy it to the control server and run there: sudo iof audit probe import < iof-probe-report.json'
}

function Invoke-IofProbe {
  $ErrorActionPreference = 'Stop'
  if ($IofProbeConfig.StartsWith('__')) {
    Write-Host 'This is the template. Get the script for your check from the iof-web panel, page Security.' -ForegroundColor Red
    return
  }
  try {
    $cfg = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($IofProbeConfig)) | ConvertFrom-Json
  } catch {
    Write-Host 'The embedded check data is damaged: get the script from the panel again.' -ForegroundColor Red
    return
  }
  $token = [string]$cfg.token
  $map = Get-IofMap
  $targets = @($cfg.targets)
  $until = [DateTimeOffset]::FromUnixTimeSeconds([int64]$cfg.expires).LocalDateTime.ToString('HH:mm')
  Write-Host "iof probe: check $($cfg.session), nodes: $($targets.Count), targets live until $until"
  Write-Host 'Turn off VPN and proxy on this PC for the check: it must go through your provider.'
  if ($map.Count) { Write-Host 'IOF_PROBE_MAP is set: node addresses are replaced (test stand).' -ForegroundColor Yellow }
  if ((Get-IofNow) -gt [int64]$cfg.expires) { Write-Host 'The targets have expired already: the result will show nothing useful.' -ForegroundColor Yellow }

  $report = [ordered]@{
    v = 1; session = [string]$cfg.session; started = (Get-IofNow); finished = 0; remap = ($map.Count -gt 0)
    client = (Get-IofClient); lists = (New-Object Collections.ArrayList); targets = (New-Object Collections.ArrayList)
  }
  Write-Host ''
  Write-Host 'Control sites ...' -NoNewline
  foreach ($kind in 'white', 'black') {
    foreach ($name in @($cfg.lists.$kind)) { if ($name) { [void]$report.lists.Add((Test-IofSite ([string]$name) $kind)) } }
  }
  $w = @($report.lists | Where-Object { $_.list -eq 'white' })
  $b = @($report.lists | Where-Object { $_.list -eq 'black' })
  Write-Host (" usual sites open: {0}/{1}, blocked sites open: {2}/{3}" -f @($w | Where-Object { $_.ok }).Count, $w.Count,
    @($b | Where-Object { $_.ok }).Count, $b.Count)

  $plan = Get-IofTunnelPlan $targets $map
  Write-Host ''
  foreach ($t in $targets) {
    $ip = [string]$t.ip
    $port = [int]$t.port
    $hy2 = [int]$t.hy2
    if ($map.ContainsKey([string]$t.node)) {
      $m = $map[[string]$t.node]
      $ip = $m.host
      $port = $m.port
      $hy2 = $m.hy2
    }
    Write-Host ('{0,-20} ' -f $t.node) -NoNewline
    $r = [ordered]@{ node = [string]$t.node }
    $r.icmp = Test-IofIcmp $ip
    $conn = New-Object Collections.ArrayList
    for ($i = 0; $i -lt 3; $i++) { [void]$conn.Add((Test-IofConn $ip $port ([string]$t.fp) $token)) }
    $r.conn = $conn
    $r.udp = Test-IofUdp $ip $port $token $false
    $r.quic = Test-IofUdp $ip $port $token $true
    $r.hy2 = ''
    if ($hy2 -gt 0) { $r.hy2 = Test-IofQuicVn $ip $hy2 }
    $r.tunnel = Test-IofTunnel $plan $t $token
    [void]$report.targets.Add($r)
    Write-Host (Format-IofLine $r)
  }
  $report.finished = Get-IofNow
  Send-IofReport $cfg $report
}

Invoke-IofProbe
Remove-Variable -Name IofProbeConfig -ErrorAction SilentlyContinue
