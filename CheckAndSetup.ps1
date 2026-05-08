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
New-Item -ItemType Directory -Force -Path "$pathRclone\logs"            | Out-Null
New-Item -ItemType Directory -Force -Path "$pathRclone\log-compactado"  | Out-Null

Write-Log "===== RCLONE DEPLOY INICIADO =====" "Cyan"
Write-Log "Computador: $env:COMPUTERNAME | Usuario: $env:USERNAME"

# =========================
# DOWNLOADS DO GITHUB
# =========================
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

# =========================
# DOWNLOAD E EXTRACAO DO RCLONE
# =========================
$rcloneZip = "$env:TEMP\rclone.zip"
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

if (Test-Path $rcloneExe) {
    $version = & "$rcloneExe" version 2>&1 | Select-Object -First 1
    Write-Log "Rclone instalado com sucesso: $version" "Green"
} else {
    Write-Log "ERRO: rclone.exe nao encontrado apos extracao." "Red"
    exit 1
}

# =========================
# TASK AGENDADA - BACKUP
# =========================
Write-Log "Configurando task de Backup..." "Cyan"

# Capturar usuario logado atual (quem rodou o script como admin)
# InteractiveLogon pega o usuario da sessao desktop ativa
$loggedUser = (Get-CimInstance Win32_ComputerSystem).UserName

if (-not $loggedUser) {
    # Fallback: usuario que executou o script
    $loggedUser = "$env:USERDOMAIN\$env:USERNAME"
}

Write-Log "Task sera criada para o usuario: $loggedUser" "Yellow"
Write-Log "ATENCAO: o usuario precisar ter permissao para executar tarefas agendadas." "Yellow"

# Perguntar quantas vezes por dia
$vezes = Read-Host "Quantas vezes deseja rodar o backup por dia? (1 ou 2) [Padrao: 2x - 11:30 e 22:00]"

$triggers = @()

if ($vezes -eq "1") {
    $hora = Read-Host "Digite o horario (ex: 14:00)"
    $triggers += New-ScheduledTaskTrigger -Daily -At $hora
    Write-Log "Backup agendado para: $hora"
} else {
    $alterarHorario = Read-Host "Usar horario padrao 11:30 e 22:00? (Y/N)"

    if ($alterarHorario -match "^[Nn]$") {
        $hora1 = Read-Host "Digite o primeiro horario (ex: 10:00)"
        $hora2 = Read-Host "Digite o segundo horario (ex: 22:00)"
        $triggers += New-ScheduledTaskTrigger -Daily -At $hora1
        $triggers += New-ScheduledTaskTrigger -Daily -At $hora2
        Write-Log "Backup agendado para: $hora1 e $hora2"
    } else {
        $triggers += New-ScheduledTaskTrigger -Daily -At "11:30"
        $triggers += New-ScheduledTaskTrigger -Daily -At "22:00"
        Write-Log "Backup agendado para horario padrao: 11:30 e 22:00"
    }
}

$backupAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\rclone\BackupAll.ps1"

# Principal identico ao configurado manualmente:
# "Run whether user is logged on or not" + "Run with highest privileges"
# LogonType S4U = roda com ou sem usuario logado, sem armazenar senha
$backupPrincipal = New-ScheduledTaskPrincipal `
    -UserId $loggedUser `
    -LogonType S4U `
    -RunLevel Highest

$taskSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable

try {
    Register-ScheduledTask `
        -TaskName "Rclone-BackupAll" `
        -Action $backupAction `
        -Trigger $triggers `
        -Principal $backupPrincipal `
        -Settings $taskSettings `
        -Force | Out-Null

    Write-Log "Task 'Rclone-BackupAll' criada para usuario '$loggedUser' com privilegios altos." "Green"
} catch {
    Write-Log "ERRO ao criar task de backup: $($_.Exception.Message)" "Red"
    Write-Log "Tente criar manualmente pelo Agendador de Tarefas do Windows." "Yellow"
}

# =========================
# FINALIZACAO
# =========================
Write-Log "===== DEPLOY FINALIZADO =====" "Cyan"
Write-Log "Log salvo em: $DeployLog"
Write-Host ""
Write-Host "RCLONE INSTALADO E CONFIGURADO" -ForegroundColor Green
Write-Host "IMPORTANTE: Configure o rclone com 'rclone config' antes do primeiro backup." -ForegroundColor Yellow
