# Install the latest Windows pmai release without administrator privileges.
# Requires Windows PowerShell 5.1 or PowerShell 7.
# Optional environment variables: PMAI_VERSION, PMAI_INSTALL_DIR, PMAI_RELEASE_BASE.

& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'

  if ($env:OS -ne 'Windows_NT') { throw 'pmai: this installer requires Windows' }

  # Use the native OS architecture, including from a 32-bit PowerShell process.
  $machine = $env:PROCESSOR_ARCHITEW6432
  if (!$machine) { $machine = $env:PROCESSOR_ARCHITECTURE }
  $architecture = switch ($machine) {
    'AMD64' { 'x64' }
    'ARM64' { 'arm64' }
    default { throw "pmai: unsupported CPU architecture: $machine" }
  }

  $installDir = $env:PMAI_INSTALL_DIR
  if (!$installDir) { $installDir = Join-Path $env:LOCALAPPDATA 'Programs\pmai' }
  $installDir = [IO.Path]::GetFullPath($installDir)
  $version = $env:PMAI_VERSION
  if (!$version) { $version = 'latest' }

  # Windows PowerShell may otherwise negotiate an older TLS version with GitHub.
  $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
  $tempDir = $null
  try {
    [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ($version -eq 'latest') {
      $release = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/trufae/pmai/releases/latest'
      $version = $release.tag_name
    }
    if (!$version -or $version -notmatch '^[A-Za-z0-9_-][A-Za-z0-9._-]*$') {
      throw 'pmai: PMAI_VERSION contains unsupported characters'
    }
    $releaseBase = "https://github.com/trufae/pmai/releases/download/$version"
    if ($env:PMAI_RELEASE_BASE) { $releaseBase = $env:PMAI_RELEASE_BASE.TrimEnd('/') }
    $asset = "pmai-windows-$architecture.zip"
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("pmai-install-" + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $archive = Join-Path $tempDir $asset
    $checksums = Join-Path $tempDir 'SHA256SUMS'

    Write-Host "pmai: downloading $asset ($version)"
    Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/$asset" -OutFile $archive
    Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/SHA256SUMS" -OutFile $checksums
    $expected = $null
    foreach ($line in Get-Content -LiteralPath $checksums) {
      if ($line -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($asset) + '$')) {
        $expected = $Matches[1]
        break
      }
    }
    if (!$expected) { throw "pmai: no checksum was published for $asset" }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) {
      throw "pmai: checksum verification failed for $asset"
    }
    Write-Host 'pmai: checksum verified'

    $payload = Join-Path $tempDir 'payload'
    Expand-Archive -LiteralPath $archive -DestinationPath $payload
    $binaries = @(Get-ChildItem -LiteralPath $payload -Recurse -File -Filter 'pmai.exe')
    if ($binaries.Count -ne 1) { throw 'pmai: the release must contain exactly one pmai.exe' }
    & $binaries[0].FullName --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'pmai: the release failed its startup check' }

    # Keep all bundled Swift and Visual C++ DLLs beside the executable.
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Get-ChildItem -LiteralPath $binaries[0].DirectoryName | Copy-Item -Destination $installDir -Recurse -Force
    $target = Join-Path $installDir 'pmai.exe'

    # Persist only the user PATH; never copy the combined process PATH into it.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';').TrimEnd('\') -notcontains $installDir.TrimEnd('\')) {
      $newPath = (@($userPath -split ';' | Where-Object { $_ }) + $installDir) -join ';'
      [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
    if (($env:PATH -split ';').TrimEnd('\') -notcontains $installDir.TrimEnd('\')) {
      $env:PATH = "$installDir;$env:PATH"
    }
    Write-Host "pmai: installed windows/$architecture version $version to $target"
    Write-Host 'pmai: ready - run: pmai'
    Write-Host 'pmai: to update, run: pmai -U'
  } finally {
    [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
      Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
  }
}
