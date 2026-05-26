[CmdletBinding()]
param(
    [string]$OutputDir = "",
    [string]$PackageName = "MoneyPrinterTurbo-windows-portable",
    [switch]$SkipDependencySync,
    [switch]$IncludeStorage,
    [switch]$IncludeModels,
    [switch]$IncludeGit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    return (Resolve-Path (Join-Path $scriptDir "..")).Path
}

function Assert-CommandExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Assert-RepoShape {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $requiredPaths = @(
        "pyproject.toml",
        "uv.lock",
        "config.example.toml",
        "webui\Main.py"
    )

    foreach ($relativePath in $requiredPaths) {
        $fullPath = Join-Path $RepoRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            throw "Required project file not found: $relativePath"
        }
    }
}

function Get-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return $fullPath.TrimEnd([char]0x5c, [char]0x2f)
}

function Copy-ProjectFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$StageDir,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [bool]$IncludeStorage,
        [bool]$IncludeModels,
        [bool]$IncludeGit
    )

    $excludedNames = @(
        ".venv",
        "venv",
        "dist",
        "logs",
        ".idea",
        ".vscode",
        "node_modules",
        "__pycache__",
        "config.toml",
        "AGENTS.md",
        "CLAUDE.md",
        "GEMINI.md"
    )

    if (-not $IncludeStorage) {
        $excludedNames += "storage"
    }

    if (-not $IncludeModels) {
        $excludedNames += "models"
    }

    if (-not $IncludeGit) {
        $excludedNames += ".git"
    }

    $normalizedOutputDir = Get-NormalizedPath $OutputDir
    $normalizedStageDir = Get-NormalizedPath $StageDir

    foreach ($item in Get-ChildItem -LiteralPath $RepoRoot -Force) {
        $itemPath = Get-NormalizedPath $item.FullName

        if ($excludedNames -contains $item.Name) {
            Write-Host "Skip $($item.Name)"
            continue
        }

        if (($itemPath -eq $normalizedOutputDir) -or ($itemPath -eq $normalizedStageDir)) {
            Write-Host "Skip package output $($item.Name)"
            continue
        }

        Copy-Item `
            -LiteralPath $item.FullName `
            -Destination (Join-Path $StageDir $item.Name) `
            -Recurse `
            -Force
    }
}

function Initialize-ConfigFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StageDir
    )

    $configPath = Join-Path $StageDir "config.toml"
    $examplePath = Join-Path $StageDir "config.example.toml"

    if ((-not (Test-Path -LiteralPath $configPath)) -and (Test-Path -LiteralPath $examplePath)) {
        Copy-Item -LiteralPath $examplePath -Destination $configPath
    }
}

function Write-LauncherFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StageDir
    )

    $startBat = @'
@echo off
setlocal
cd /d "%~dp0"
set "PYTHONPATH=%CD%"

if not exist ".venv\Scripts\streamlit.exe" (
  echo [ERROR] Missing .venv\Scripts\streamlit.exe.
  echo Run update.bat first, or rebuild the portable package without -SkipDependencySync.
  pause
  exit /b 1
)

if not exist "config.toml" (
  if exist "config.example.toml" (
    copy /Y "config.example.toml" "config.toml" >nul
  )
)

".venv\Scripts\streamlit.exe" run ".\webui\Main.py" --browser.gatherUsageStats=False --server.enableCORS=True
pause
'@

    $updateBat = @'
@echo off
setlocal
cd /d "%~dp0"
set "PYTHONPATH=%CD%"

where uv >nul 2>nul
if errorlevel 1 (
  echo [ERROR] uv is required to update dependencies.
  echo Install uv from https://docs.astral.sh/uv/
  pause
  exit /b 1
)

if exist ".git" (
  where git >nul 2>nul
  if errorlevel 1 (
    echo [WARN] Git is not installed; skipping code update.
  ) else (
    git pull --ff-only
    if errorlevel 1 (
      echo [ERROR] git pull failed.
      pause
      exit /b 1
    )
  )
) else (
  echo [INFO] .git directory not found; skipping code update.
)

uv sync --frozen
if errorlevel 1 (
  echo [ERROR] uv sync --frozen failed.
  pause
  exit /b 1
)

pause
'@

    Set-Content -LiteralPath (Join-Path $StageDir "start.bat") -Value $startBat -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $StageDir "update.bat") -Value $updateBat -Encoding ASCII
}

function Sync-Dependencies {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StageDir
    )

    Push-Location $StageDir
    try {
        & uv sync --frozen
        if ($LASTEXITCODE -ne 0) {
            throw "uv sync --frozen failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

$repoRoot = Get-RepoRoot
Assert-RepoShape $repoRoot
Assert-CommandExists "uv"

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "dist"
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$stageDir = Join-Path $OutputDir $PackageName
$zipPath = Join-Path $OutputDir "$PackageName.zip"

if ((Get-NormalizedPath $stageDir) -eq (Get-NormalizedPath $repoRoot)) {
    throw "Stage directory must not be the repository root."
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

if (Test-Path -LiteralPath $stageDir) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force
}

New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

Write-Host "Copy project files..."
Copy-ProjectFiles `
    -RepoRoot $repoRoot `
    -StageDir $stageDir `
    -OutputDir $OutputDir `
    -IncludeStorage ([bool]$IncludeStorage) `
    -IncludeModels ([bool]$IncludeModels) `
    -IncludeGit ([bool]$IncludeGit)

Initialize-ConfigFile $stageDir
Write-LauncherFiles $stageDir

if ($SkipDependencySync) {
    Write-Warning "SkipDependencySync is enabled. start.bat will not work until update.bat or uv sync --frozen creates .venv."
}
else {
    Write-Host "Install locked dependencies into the portable package..."
    Sync-Dependencies $stageDir
}

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Write-Host "Create zip package..."
Compress-Archive -Path $stageDir -DestinationPath $zipPath -Force

Write-Host "Package created: $zipPath"
Write-Host "Unzip it on Windows, then double-click start.bat."
