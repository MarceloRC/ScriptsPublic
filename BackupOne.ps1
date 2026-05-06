param (
    [String] $SourceFolder = 'pasta',
    [String] $SourceFolderLog = 'c:\rclone\logs\',
    [String] $Transfers = '80',
    [String] $AccountName = 'bucket',
    [String] $AccountNameLog = 'backup_logs_zener',
    [String] $BucketName = 'bucket-unifi',
    [String] $BucketNameLog = 'backup-logs-zener',
    [String] $DestFolder = 'controller-unifi',
    [String] $CustomerName = 'cliente',
    [String] $ExtraArgs = "",
    [int] $MaxRetries = 1
)

# ===== FIX UTF8 =====
chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ================= CONFIG FIXA =================
$ErrorActionPreference = "Continue"

$CurrentDate  = Get-Date -Format "yyyy-MM-dd"
$ZabbixServer = "192.168.10.1"
$HostName     = "srv-dc01.dominio.local"

$RcloneExe    = "c:\rclone\rclone.exe"
$ZabbixSender = "C:\Program Files\Zabbix Agent 2\zabbix_sender.exe"
$RcloneConfig = "C:\Users\Administrator\AppData\Roaming\rclone\rclone.conf"

$LogPath = "c:\rclone\logs\$CurrentDate"
$LogFile = "$LogPath\$DestFolder.log"

New-Item -ItemType Directory -Force -Path $LogPath | Out-Null

# ================= FUNÇÃO ZABBIX SIMPLES =================
function Send-Zabbix ($Key, $Value) {
    & $ZabbixSender -z $ZabbixServer -s $HostName -p 10051 -k $Key -o $Value 2>$null
}

# ================= FUNÇÃO DISCOVERY =================
function Send-ZabbixDiscovery {
    param ([string]$DestFolder)
    
    Write-Host "`n========== DISCOVERY ==========" -ForegroundColor Magenta
    Write-Host "[$DestFolder] Enviando discovery..."
    
    $JsonContent = '{"data":[{"{#BACKUPNAME}":"' + $DestFolder + '"}]}'
    $TempFile = [System.IO.Path]::GetTempFileName()
    "$HostName backup.discovery $JsonContent" | Out-File -FilePath $TempFile -Encoding ASCII -NoNewline
    
    & $ZabbixSender -z $ZabbixServer -p 10051 -i $TempFile 2>&1 | Out-Null
    Remove-Item $TempFile -Force -ErrorAction SilentlyContinue
}

# ================= FUNÇÃO PARA VERIFICAR ERROS NO LOG =================
function Test-RcloneErrors {
    param ([string]$LogFile)
    
    if (Test-Path $LogFile) {
        $LogContent = Get-Content $LogFile -Raw
        # Verifica se tem erros de "arquivo não encontrado" (ignoráveis)
        if ($LogContent -match "cannot find the file specified|The system cannot find the file|failed to open source object") {
            return $true
        }
    }
    return $false
}

# ================= INÍCIO =================
Write-Host "`n======================================"
Write-Host "[$DestFolder] Iniciando backup"
Write-Host "======================================"

# DISCOVERY
Send-ZabbixDiscovery $DestFolder

# AGUARDA
Write-Host "[$DestFolder] Aguardando 30s..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

# INÍCIO DO BACKUP
$StartTime = Get-Date
Send-Zabbix "backup.running_[$DestFolder]" "1"

$RetryCount = 0
$ExitCode   = 1

try {
    while ($RetryCount -le $MaxRetries -and $ExitCode -ne 0) {
        Write-Host "[$DestFolder] Executando rclone (tentativa $($RetryCount+1))..."
        
        & $RcloneExe `
            sync "$SourceFolder" "$AccountName`:$BucketName/$DestFolder" `
            --transfers $Transfers `
            --filter-from 'c:\rclone\filters.txt' `
            --fast-list `
            --create-empty-src-dirs `
            --checkers 16 `
            --timeout 1h `
            --contimeout 30s `
            --retries 3 `
            --low-level-retries 10 `
            --log-level INFO `
            --min-age 10m `
            --log-file "$LogFile" `
            $ExtraArgs 2>&1 | Out-Null

        $ExitCode = $LASTEXITCODE
        Write-Host "[$DestFolder] Rclone exit code: $ExitCode"

        if ($ExitCode -ne 0) {
            $RetryCount++
            if ($RetryCount -le $MaxRetries) {
                Write-Host "[$DestFolder] Tentativa $RetryCount falhou. Aguardando 10s..."
                Start-Sleep -Seconds 10
            }
        }
    }

    # SYNC LOGS (só executa uma vez, não importa o exit code)
    & $RcloneExe `
        sync "$SourceFolderLog" "$AccountNameLog`:$BucketNameLog/$CustomerName" `
        --log-level INFO 2>&1 | Out-Null
}
catch {
    Write-Host "[$DestFolder] Erro: $_"
    $ExitCode = 99
}
# ================= NO FINAL DO SCRIPT =================
finally {
    $EndTime  = Get-Date
    $Duration = [int]($EndTime - $StartTime).TotalSeconds
    $NowUnix  = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # ================= VERIFICA ERROS NO LOG =================
    $HasFileNotFound = Test-RcloneErrors -LogFile $LogFile
    
    # ================= NOVA LÓGICA DE STATUS (COM EXIT CODE 6) =================
    if ($ExitCode -eq 0) {
        $Status = 1           # Sucesso total
        $StatusText = "SUCESSO TOTAL"
        Write-Host "[$DestFolder] ✅ SUCESSO TOTAL" -ForegroundColor Green
    } 
    elseif ($ExitCode -eq 6 -or $ExitCode -eq 3 -or ($ExitCode -eq 1 -and $HasFileNotFound)) {
        $Status = 6           # Rodou com erros (inclui exit code 6)
        $StatusText = "RODOU COM ERROS"
        Write-Host "[$DestFolder] ⚠️ RODOU COM ERROS (Status 6, Exit: $ExitCode)" -ForegroundColor Yellow
    }
    else {
        $Status = 0           # Falha real
        $StatusText = "FALHA"
        Write-Host "[$DestFolder] ❌ FALHA (Status 0, Exit: $ExitCode)" -ForegroundColor Red
    }

    Write-Host "[$DestFolder] Backup finalizado: $StatusText"
    Write-Host "[$DestFolder] Duração: $Duration segundos"

    # MÉTRICAS FINAIS
    Send-Zabbix "backup.status_[$DestFolder]"    "$Status"
    Send-Zabbix "backup.timestamp_[$DestFolder]" "$NowUnix"
    Send-Zabbix "backup.duration_[$DestFolder]"  "$Duration"
    Send-Zabbix "backup.running_[$DestFolder]"   "0"
    Send-Zabbix "backup.exitcode_[$DestFolder]"  "$ExitCode"
}

# ================= LIMPEZA LOGS ANTIGOS =================
Get-ChildItem "c:\rclone\logs" -Directory |
Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-30) } |
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# ================= GERAR JSON =================
$Result = [PSCustomObject]@{
    cliente       = $CustomerName
    rotina        = $DestFolder
    source        = $SourceFolder
    bucket        = $BucketName
    data_execucao = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    status        = $Status
    exitcode      = $ExitCode
    duracao_seg   = $Duration
    retries       = $RetryCount
}

$JsonPath = "$LogPath\backup-status-$DestFolder.json"
$Result | ConvertTo-Json -Depth 3 | Out-File -Encoding utf8 $JsonPath

& $RcloneExe `
    copy "$JsonPath" "$AccountNameLog`:$BucketNameLog/$CustomerName/" `
    --log-level ERROR 2>&1 | Out-Null

Write-Host "[$DestFolder] Script finalizado!"
