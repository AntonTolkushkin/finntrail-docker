$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $RootDir ".env"
$BaseCompose = Join-Path $RootDir "docker-compose.yml"
$LocalCompose = Join-Path $RootDir "docker-compose.override.yml"

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw ".env is missing. Run scripts\init-env.ps1 first."
}

if (Select-String -LiteralPath $EnvFile -Pattern "CHANGE_ME_" -Quiet) {
    throw ".env still contains placeholder secrets."
}

$envContent = Get-Content -LiteralPath $EnvFile
if (-not ($envContent -contains "APP_ENV=local")) {
    throw "APP_ENV must be local in .env."
}

$certificate = Join-Path $RootDir "confs\nginx\certs\finntrail.local\fullchain.pem"
$privateKey = Join-Path $RootDir "confs\nginx\certs\finntrail.local\privkey.pem"
if (-not (Test-Path -LiteralPath $certificate) -or -not (Test-Path -LiteralPath $privateKey)) {
    throw "Local certificate is missing. Run scripts\setup-local-cert.ps1."
}

function Invoke-Compose {
    param([string[]]$ComposeArguments)

    & docker compose `
        --env-file $EnvFile `
        -f $BaseCompose `
        -f $LocalCompose `
        @ComposeArguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose command failed: $($ComposeArguments -join ' ')"
    }
}

Push-Location $RootDir
try {
    Invoke-Compose -ComposeArguments @("config", "--quiet")
    Invoke-Compose -ComposeArguments @("pull")
    Invoke-Compose -ComposeArguments @("run", "--rm", "--no-deps", "php", "php-fpm", "-t")
    Invoke-Compose -ComposeArguments @("up", "-d", "mysql", "redis", "php")
    Invoke-Compose -ComposeArguments @("run", "--rm", "--no-deps", "nginx", "nginx", "-t")
    Invoke-Compose -ComposeArguments @("up", "-d", "--remove-orphans")
    Invoke-Compose -ComposeArguments @("ps")
}
finally {
    Pop-Location
}
