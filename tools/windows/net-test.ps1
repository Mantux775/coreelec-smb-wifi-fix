# net-test.ps1 - raw TCP throughput between this PC and the box (no Samba involved).
# If PowerShell says "running scripts is disabled on this system" (the Windows default), start it as
#   powershell -ExecutionPolicy Bypass -File .\net-test.ps1 <parameters>
#
# 1. On the box (SSH), start the counterpart from tools/nettest.py:
#      PC sends  ->  python3 nettest.py sink 5201
#      box sends ->  python3 nettest.py source 5201 1073741824
# 2. On the PC:
#      .\net-test.ps1 -Box 192.168.1.50 -Dir up            # PC -> box
#      .\net-test.ps1 -Box 192.168.1.50 -Dir down          # box -> PC  (give the same size: -MiB 1024)
param(
  [Parameter(Mandatory)][string]$Box,
  [ValidateSet('up','down')][string]$Dir = 'up',
  [int]$MiB = 1024,
  [int]$Port = 5201
)
$ErrorActionPreference = 'Stop'
$total = [int64]$MiB * 1MB
$c = New-Object Net.Sockets.TcpClient($Box, $Port)
$c.SendBufferSize = 4MB; $c.ReceiveBufferSize = 4MB
$s = $c.GetStream()
$buf = New-Object byte[] (1MB)
$n = [int64]0
$sw = [Diagnostics.Stopwatch]::StartNew()
if ($Dir -eq 'up') {
  while ($n -lt $total) { $s.Write($buf, 0, $buf.Length); $n += $buf.Length }
  $c.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
  $null = $s.Read($buf, 0, 1)          # wait until the box has read everything
} else {
  while ($n -lt $total) { $r = $s.Read($buf, 0, $buf.Length); if ($r -le 0) { break }; $n += $r }
}
$sw.Stop(); $c.Close()
'{0}: {1:N1} MB/s ({2:N0} MiB in {3:N1} s)' -f $(if ($Dir -eq 'up') { 'PC -> box' } else { 'box -> PC' }), ($n / 1MB / $sw.Elapsed.TotalSeconds), ($n / 1MB), $sw.Elapsed.TotalSeconds
