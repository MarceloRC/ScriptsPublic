# ===============================
# Rclone MSP Auto Deploy
# ===============================

# Verificar administrador
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERRO: Execute como Administrador." -ForegroundColor Red
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$pathRclone = "C:\rclone"
$baseURL    = "https://raw.githubusercontent.com/MarceloRC/ScriptsPublic/main"
$DeployLog  = "$pathRclone\logs\rclone_deploy.log"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $DeployLog -Value $line -Encoding UTF8
}

# Criar estrutura de pastas
New-Item -ItemType Directory -Force -Path "$pathRclone\logs"         | Out-Null
New-Item -ItemType Directory -Force -Path "$pathRclone\log-compactado" | Out-Null

Write-Log "===== RCLONE DEPLOY INICIADO =====" "Cyan"
Write-Log "Computador: $env:COMPUTERNAME | Usuario: $env:USERNAME"

# Downloads do GitHub
$files = @{
    "BackupOne.ps1" = "$baseURL/BackupOne.ps1"
    "BackupAll.ps1" = "$baseURL/BackupAll.ps1"
    "filters.txt"   = "$baseURL/filters.txt"
}

foreach ($file in $files.GetEnumerator()) {
    Write-Log "Baixando $($file.Key)..." "Green"
    try {
        Invoke-WebRequest -URI $file.Value -OutFile "$pathRclone\$($file.Key)" -UseBasicParsing -ErrorAction Stop
        Write-Log "OK: $($file.Key)" "Green"
    } catch {
        Write-Log "ERRO ao baixar $($file.Key): $($_.Exception.Message)" "Red"
        exit 1
    }
}

# Download e extração do Rclone
$rcloneZip = "$env:TEMP\rclone.zip"

# Verifica se já existe uma versão instalada
$rcloneExe = "$pathRclone\rclone.exe"
if (Test-Path $rcloneExe) {
    $version = & "$rcloneExe" version 2>&1 | Select-Object -First 1
    Write-Log "Rclone ja instalado: $version — atualizando..." "Yellow"
}

Write-Log "Baixando Rclone (latest)..." "Green"
try {
    Invoke-WebRequest -URI "https://downloads.rclone.org/rclone-current-windows-amd64.zip" -OutFile $rcloneZip -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Log "ERRO ao baixar Rclone: $($_.Exception.Message)" "Red"
    exit 1
}

Write-Log "Extraindo rclone.exe..." "Green"
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($rcloneZip, 'read')
    $zip.Entries | Where-Object Name -match "rclone.exe" | ForEach-Object {
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, "$pathRclone\rclone.exe", $true)
    }
    $zip.Dispose()
} catch {
    Write-Log "ERRO ao extrair rclone.exe: $($_.Exception.Message)" "Red"
    exit 1
}

# Verificacao pos-install
if (Test-Path $rcloneExe) {
    $version = & "$rcloneExe" version 2>&1 | Select-Object -First 1
    Write-Log "Rclone instalado com sucesso: $version" "Green"
} else {
    Write-Log "ERRO: rclone.exe nao encontrado apos extracao." "Red"
    exit 1
}

Write-Log "===== DEPLOY FINALIZADO =====" "Cyan"
Write-Log "Log salvo em: $DeployLog"
