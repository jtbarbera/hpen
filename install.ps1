# ==========================================================
# HeyPocket Export Tool - Minimal Setup
# ==========================================================

Write-Host "Setting up HeyPocket Export Tool..."

# Create directories
$base = Join-Path $PSScriptRoot "data"
$dirs = @(
    $base,
    (Join-Path $base "output"),
    (Join-Path $base "logs")
)

foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d | Out-Null
        Write-Host "Created: $d"
    }
}

# Create empty checkpoint file if missing
$checkpoint = Join-Path $base "processed_ids.txt"
if (-not (Test-Path $checkpoint)) {
    New-Item -ItemType File -Path $checkpoint | Out-Null
    Write-Host "Created: processed_ids.txt"
}

# Create optional config template
$config = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path $config)) {
@"
# Copy values here if not using environment variables

# $HEYPOCKET_API_TOKEN = ""
# $MS_TRANSLATOR_KEY   = ""
# $MS_TRANSLATOR_REGION = "westus2"
"@ | Out-File -Encoding utf8 $config

    Write-Host "Created: config.ps1 template"
}

Write-Host ""
Write-Host "✅ Setup complete"
Write-Host "Next: Set environment variables OR edit config.ps1"