$ErrorActionPreference = 'Stop'

$bin = swift build --package-path MaiCore --configuration debug --disable-prefetching --show-bin-path
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$package = Join-Path $env:RUNNER_TEMP 'pmai-windows-x64'
New-Item -ItemType Directory -Force $package | Out-Null
Copy-Item (Join-Path $bin 'pmai.exe') $package
Copy-Item 'LICENSE.txt' $package

$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$visualStudio) { throw 'Visual C++ tools not found' }
$dumpbin = Get-ChildItem "$visualStudio/VC/Tools/MSVC/*/bin/Hostx64/x64/dumpbin.exe" |
  Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
if (!$dumpbin) { throw 'dumpbin.exe not found' }
$runtime = swiftc -print-target-info | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$redist = Get-ChildItem "$visualStudio/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT" -Directory |
  Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName
$search = @($bin) + @($runtime.paths.runtimeLibraryPaths) + @($redist) + @($env:PATH -split ';')
$pending = [System.Collections.Generic.Queue[string]]::new()
$pending.Enqueue((Join-Path $package 'pmai.exe'))
$seen = @{}

# Follow transitive imports so the ZIP runs without an installed Swift toolchain.
while ($pending.Count) {
  $imports = & $dumpbin /nologo /dependents ($pending.Dequeue())
  if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect DLL dependencies' }
  foreach ($line in $imports) {
    if ($line -notmatch '^\s+([\w.+-]+\.dll)\s*$') { continue }
    $name = $Matches[1]
    if ($seen.ContainsKey($name) -or $name -match '^(api|ext)-ms-win-') { continue }
    $seen[$name] = $true
    $source = $null
    foreach ($directory in $search) {
      if (!$directory) { continue }
      $candidate = Join-Path $directory $name
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $source = $candidate
        break
      }
    }
    if (!$source) {
      if (Test-Path -LiteralPath "$env:WINDIR/System32/$name") { continue }
      throw "Missing runtime dependency: $name"
    }
    if ([IO.Path]::GetFullPath($source).StartsWith("$env:WINDIR\", [StringComparison]::OrdinalIgnoreCase)) { continue }
    Copy-Item -LiteralPath $source -Destination $package
    $pending.Enqueue((Join-Path $package $name))
  }
}

@'
pmai for Windows x64 (beta)

Extract the ZIP, open PowerShell in pmai-windows-x64 and run .\pmai.exe.
Keep the bundled DLLs beside pmai.exe. No Swift installation is needed.
This debug build provides initial Windows support; some Unix features are unavailable.
'@ | Set-Content (Join-Path $package 'README.txt')
Compress-Archive -Path $package -DestinationPath 'pmai-windows-x64.zip' -Force
