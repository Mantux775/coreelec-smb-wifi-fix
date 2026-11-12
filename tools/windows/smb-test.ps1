# smb-test.ps1 - times an Explorer-style copy to and from a Samba share.
# If PowerShell says "running scripts is disabled on this system" (the Windows default), start it as
#   powershell -ExecutionPolicy Bypass -File .\smb-test.ps1 <parameters>
#
#   .\smb-test.ps1 -Share \\COREELEC\MyDisk -File D:\some-big-file.mkv
#   .\smb-test.ps1 -Share \\COREELEC\MyDisk -File D:\some-big-file.mkv -ReadFile '\\COREELEC\MyDisk\Movies\other.mkv'
#   .\smb-test.ps1 -Share \\COREELEC\MyDisk -File D:\some-big-file.mkv -Keep
#
# -File      local test file (1 GB or more gives stable numbers). It is copied into a folder
#            "_speedtest" on the share and deleted again.
# -Keep      do not delete the copy, so that you can verify it on the box with sha256sum
#            (the script prints the checksum of the source). Delete the folder yourself afterwards.
# -ReadFile  optional: a file that already exists on the share and has NOT been read or written
#            from this PC recently (otherwise Windows answers from its own cache). It is copied to
#            %TEMP% and deleted again.
# Copy-Item uses the same Windows copy engine as Explorer, including setting the final file size
# before the first write.
param(
  [Parameter(Mandatory)][string]$Share,
  [Parameter(Mandatory)][string]$File,
  [string]$ReadFile,
  [switch]$Keep
)
$ErrorActionPreference = 'Stop'
$len = (Get-Item -LiteralPath $File).Length
$dir = Join-Path $Share '_speedtest'
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory $dir | Out-Null }
$dst = Join-Path $dir ('w-' + [IO.Path]::GetFileName($File))

$sw = [Diagnostics.Stopwatch]::StartNew(); Copy-Item -LiteralPath $File -Destination $dst; $sw.Stop()
'write: {0:N1} MB/s ({1:N0} MiB in {2:N1} s)' -f ($len / 1MB / $sw.Elapsed.TotalSeconds), ($len / 1MB), $sw.Elapsed.TotalSeconds
if ($Keep) {
  'source SHA256: ' + (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLower()
  "kept: $dst  (compare with sha256sum on the box, then delete the _speedtest folder)"
} else {
  Remove-Item -LiteralPath $dst; Remove-Item -LiteralPath $dir -ErrorAction SilentlyContinue
}

if ($ReadFile) {
  $rlen = (Get-Item -LiteralPath $ReadFile).Length
  $tmp = Join-Path $env:TEMP ('smbtest-' + [IO.Path]::GetFileName($ReadFile))
  $sw = [Diagnostics.Stopwatch]::StartNew(); Copy-Item -LiteralPath $ReadFile -Destination $tmp; $sw.Stop()
  'read:  {0:N1} MB/s ({1:N0} MiB in {2:N1} s)' -f ($rlen / 1MB / $sw.Elapsed.TotalSeconds), ($rlen / 1MB), $sw.Elapsed.TotalSeconds
  Remove-Item -LiteralPath $tmp
}
