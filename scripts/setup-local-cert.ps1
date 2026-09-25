[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Domain = "finntrail.local",
    [switch]$InstallTrustOnly,
    [string]$MkcertPath = ""
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-LocalTrust {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mkcert,
        [Parameter(Mandatory = $true)]
        [string]$HostName
    )

    & $Mkcert -install
    if ($LASTEXITCODE -ne 0) {
        throw "mkcert failed to install its local CA."
    }

    $hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
    $hostExists = $false
    foreach ($line in Get-Content -LiteralPath $hostsPath) {
        $trimmed = ($line -replace '#.*$', '').Trim()
        if ($trimmed.Length -eq 0) { continue }
        $parts = $trimmed -split '\s+'
        if ($parts[0] -eq "127.0.0.1" -and $parts -contains $HostName) {
            $hostExists = $true
            break
        }
    }

    if (-not $hostExists) {
        Add-Content -LiteralPath $hostsPath -Value ("`r`n127.0.0.1`t{0}" -f $HostName) -Encoding ASCII
    }

    & ipconfig.exe /flushdns | Out-Null
}

if ($MkcertPath) {
    $mkcert = $MkcertPath
}
else {
    $mkcertCommand = Get-Command mkcert -ErrorAction SilentlyContinue
    if ($null -ne $mkcertCommand) {
        $mkcert = $mkcertCommand.Source
    }
    else {
        $mkcertDirectory = Join-Path $env:LOCALAPPDATA "Programs\mkcert"
        $mkcert = Join-Path $mkcertDirectory "mkcert.exe"
        New-Item -ItemType Directory -Force -Path $mkcertDirectory | Out-Null

        if (-not (Test-Path -LiteralPath $mkcert)) {
            Write-Host "Downloading mkcert from the official distribution endpoint..."
            $oldProgressPreference = $ProgressPreference
            $ProgressPreference = "SilentlyContinue"
            try {
                Invoke-WebRequest `
                    -Uri "https://dl.filippo.io/mkcert/latest?for=windows/amd64" `
                    -OutFile $mkcert
            }
            finally {
                $ProgressPreference = $oldProgressPreference
            }
            Unblock-File -LiteralPath $mkcert
        }
    }
}

if (-not (Test-Path -LiteralPath $mkcert -PathType Leaf)) {
    throw "mkcert was not found at: $mkcert"
}

if ($InstallTrustOnly) {
    if (-not (Test-Administrator)) {
        throw "Administrator privileges are required to install the local CA and update hosts."
    }
    Install-LocalTrust -Mkcert $mkcert -HostName $Domain
    exit 0
}

if (-not (Test-Administrator)) {
    Write-Host "Requesting Administrator privileges to trust the local CA and update hosts..."

    # An elevated Windows process can lose access to \\wsl.localhost paths.
    # Run a temporary local copy only for the privileged operations, then let
    # this original process write the generated files back into WSL.
    $elevationScript = Join-Path ([IO.Path]::GetTempPath()) ("env-docker-cert-" + [Guid]::NewGuid().ToString("N") + ".ps1")
    Copy-Item -LiteralPath $PSCommandPath -Destination $elevationScript -Force
    try {
        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", ('"{0}"' -f $elevationScript),
            "-InstallTrustOnly",
            "-MkcertPath", ('"{0}"' -f $mkcert),
            "-Domain", ('"{0}"' -f $Domain)
        ) -join " "
        $process = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "The elevated certificate setup failed with exit code $($process.ExitCode)."
        }
    }
    finally {
        Remove-Item -LiteralPath $elevationScript -Force -ErrorAction SilentlyContinue
    }
}
else {
    Install-LocalTrust -Mkcert $mkcert -HostName $Domain
}

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$CertificateDirectory = Join-Path $ProjectRoot "confs\nginx\certs\$Domain"
$CertificateFile = Join-Path $CertificateDirectory "fullchain.pem"
$PrivateKeyFile = Join-Path $CertificateDirectory "privkey.pem"

New-Item -ItemType Directory -Force -Path $CertificateDirectory | Out-Null
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("finntrail-mkcert-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null

try {
    $temporaryCertificate = Join-Path $temporaryDirectory "fullchain.pem"
    $temporaryKey = Join-Path $temporaryDirectory "privkey.pem"

    & $mkcert `
        -cert-file $temporaryCertificate `
        -key-file $temporaryKey `
        $Domain localhost 127.0.0.1 "::1"
    if ($LASTEXITCODE -ne 0) {
        throw "mkcert failed to generate the certificate."
    }

    Copy-Item -LiteralPath $temporaryCertificate -Destination $CertificateFile -Force
    Copy-Item -LiteralPath $temporaryKey -Destination $PrivateKeyFile -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

if (-not (Test-Path -LiteralPath $CertificateFile -PathType Leaf) -or
    -not (Test-Path -LiteralPath $PrivateKeyFile -PathType Leaf)) {
    throw "Certificate files were not copied to the project directory: $CertificateDirectory"
}

$CaRoot = ((& $mkcert -CAROOT) | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($CaRoot)) {
    throw "mkcert failed to return its local CA directory."
}

$RootCaFile = Join-Path $CaRoot "rootCA.pem"
if (-not (Test-Path -LiteralPath $RootCaFile -PathType Leaf)) {
    throw "mkcert root CA was not found: $RootCaFile"
}

$PhpCaDirectory = Join-Path $ProjectRoot "confs\php\local-ca"
$PhpCaFile = Join-Path $PhpCaDirectory "rootCA.pem"
New-Item -ItemType Directory -Force -Path $PhpCaDirectory | Out-Null
Copy-Item -LiteralPath $RootCaFile -Destination $PhpCaFile -Force

Write-Host "Local HTTPS certificate is ready:"
Write-Host "  $CertificateFile"
Write-Host "  $PrivateKeyFile"
Write-Host "Open https://$Domain after Docker Compose starts."
