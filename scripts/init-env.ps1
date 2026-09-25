param(
    [ValidateSet("Local", "Production")]
    [string]$Mode = "Local",
    [switch]$SkipLocalCertificate
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent $PSScriptRoot
$Target = Join-Path $RootDir ".env"
$TemplateName = if ($Mode -eq "Production") { ".env.production.example" } else { ".env.example" }
$Template = Join-Path $RootDir $TemplateName

if (Test-Path -LiteralPath $Target) {
    throw "$Target already exists; it was not overwritten."
}

function New-HexSecret {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

$content = Get-Content -LiteralPath $Template -Raw
$content = $content -replace '(?m)^MYSQL_PASSWORD=.*$', ("MYSQL_PASSWORD=" + (New-HexSecret))
$content = $content -replace '(?m)^MYSQL_ROOT_PASSWORD=.*$', ("MYSQL_ROOT_PASSWORD=" + (New-HexSecret))
$content = $content -replace '(?m)^REDIS_PASSWORD=.*$', ("REDIS_PASSWORD=" + (New-HexSecret))
[System.IO.File]::WriteAllText($Target, $content, [System.Text.UTF8Encoding]::new($false))

if ($Mode -eq "Local") {
    New-Item -ItemType Directory -Force -Path (Join-Path $RootDir "www\public_html") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $RootDir "backups") | Out-Null
    if (-not $SkipLocalCertificate) {
        & (Join-Path $PSScriptRoot "setup-local-cert.ps1") -ProjectRoot $RootDir
        if ($LASTEXITCODE -ne 0) {
            throw "Local certificate setup failed."
        }
    }
}

Write-Host "Created $Target for $Mode mode."
if ($Mode -eq "Production") {
    Write-Host "Review EDGE_MODE, paths, database sizing and resource limits before deployment."
}
