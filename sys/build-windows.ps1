param(
  [Parameter(Mandatory)]
  [ValidateSet('x64', 'arm64')]
  [string]$Architecture
)

$ErrorActionPreference = 'Stop'
$cxxFlags = @()
if ($Architecture -eq 'arm64') {
  # Swift 6.4 bundles Clang 21, while MSVC 14.52 requires Clang 22 for C++.
  $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
  $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.14.44.17.14.ARM64 -property installationPath
  if ($LASTEXITCODE -ne 0 -or !$visualStudio) { throw 'Visual Studio with MSVC 14.44 ARM64 was not found' }
  $tools = Get-ChildItem "$visualStudio/VC/Tools/MSVC" -Directory -Filter '14.44.*' |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
  if (!$tools) { throw 'MSVC 14.44 ARM64 toolset was not found' }
  Write-Host "Using MSVC $($tools.Name) for C++"
  $cxxFlags = @('-Xcxx', '-Xmicrosoft-visualc-tools-root', '-Xcxx', $tools.FullName)
}

swift build --package-path MaiCore --configuration release -debug-info-format none --disable-index-store --disable-prefetching --product pmai -Xswiftc -Osize -Xlinker /DEBUG:NONE @cxxFlags
exit $LASTEXITCODE
