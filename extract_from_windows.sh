#!/bin/bash
#===============================================================================
# Скрипт извлечения данных с Windows Server 2012 (Hyper-V)
# Извлекает: Nextcloud, Почту, Веб-сайт с SSL, Asterisk, сертификаты
#===============================================================================

set -e

# Конфигурация
WIN_SERVER="10.10.0.10"
WIN_USER="prodick.local\\admin"
WIN_PASS="F@il2511"
ALTERNATE_USER="admin"
ALTERNATE_PASS="F@il2511"
POOMIK_USER="p0mik"
POOMIK_PASS="32!p0mik!23"

LOCAL_OUTPUT_DIR="./extracted_data_$(date +%Y%m%d_%H%M%S)"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка зависимостей
check_dependencies() {
    log_info "Проверка зависимостей..."
    
    if ! command -v xfreerdp &> /dev/null; then
        log_error "xfreerdp не найден. Установка..."
        sudo apt-get update && sudo apt-get install -y freerdp2-x11 || {
            log_error "Не удалось установить freerdp. Установите вручную: sudo apt install freerdp2-x11"
            exit 1
        }
    fi
    
    if ! command -v sshpass &> /dev/null; then
        log_error "sshpass не найден. Установка..."
        sudo apt-get update && sudo apt-get install -y sshpass || {
            log_error "Не удалось установить sshpass. Установите вручную: sudo apt install sshpass"
            exit 1
        }
    fi
    
    if ! command -v 7z &> /dev/null; then
        log_error "7zip не найден. Установка..."
        sudo apt-get update && sudo apt-get install -y p7zip-full || {
            log_error "Не удалось установить 7zip. Установите вручную: sudo apt install p7zip-full"
            exit 1
        }
    fi
    
    log_info "Все зависимости установлены."
}

# Создание PowerShell скрипта для выполнения на Windows
create_windows_extraction_script() {
    local ps_script="$LOCAL_OUTPUT_DIR/extract_data.ps1"
    
    cat > "$ps_script" << 'PSEOF'
# Скрипт извлечения данных с Windows Server 2012 + Hyper-V
# Запускать от имени Administrator на хосте Hyper-V

$ErrorActionPreference = "Continue"
$OutputDir = "C:\ExtractionTemp"
$VMDataDir = "$OutputDir\VM_Data"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Скрипт извлечения данных Hyper-V" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Создание директорий
if (!(Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
if (!(Test-Path $VMDataDir)) { New-Item -ItemType Directory -Path $VMDataDir | Out-Null }

Write-Host "[*] Директория для данных: $VMDataDir" -ForegroundColor Green

# Функция для проверки доступности VM
function Test-VMAccessible {
    param($VMName, $IPAddress, $Username, $Password)
    
    Write-Host "  Проверка VM: $VMName ($IPAddress)" -ForegroundColor Yellow
    
    # Попытка подключения через PowerShell Remoting
    $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
    $creds = New-Object System.Management.Automation.PSCredential($Username, $securePass)
    
    try {
        $session = New-PSSession -ComputerName $IPAddress -Credential $creds -ErrorAction Stop
        Remove-PSSession $session
        Write-Host "  [+] VM доступна через WinRM" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [-] WinRM недоступен, пробуем SMB..." -ForegroundColor Yellow
        try {
            $testPath = "\\$IPAddress\C$"
            if (Test-Path $testPath) {
                Write-Host "  [+] SMB доступ получен" -ForegroundColor Green
                return $true
            }
        } catch {
            Write-Host "  [-] SMB также недоступен" -ForegroundColor Red
        }
    }
    return $false
}

# Функция извлечения данных из VM
function Extract-FromVM {
    param($VMName, $IPAddress, $Username, $Password, $VMDir)
    
    Write-Host "`n[*] Обработка VM: $VMName" -ForegroundColor Cyan
    Write-Host "    IP: $IPAddress" -ForegroundColor Gray
    
    $vmOutputDir = "$VMDir\$VMName"
    if (!(Test-Path $vmOutputDir)) { New-Item -ItemType Directory -Path $vmOutputDir | Out-Null }
    
    $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
    $creds = New-Object System.Management.Automation.PSCredential($Username, $securePass)
    
    try {
        # Подключение к VM
        $session = New-PSSession -ComputerName $IPAddress -Credential $creds -ErrorAction Stop
        Write-Host "  [+] Подключение к VM успешно" -ForegroundColor Green
        
        # Скрипт для выполнения внутри VM
        $vmScript = @"
`$vmOut = "C:\\TempExtraction"
if (!(Test-Path `$vmOut)) { New-Item -ItemType Directory -Path `$vmOut | Out-Null }

Write-Host "Сканирование системы..." -ForegroundColor Cyan

# 1. Поиск Nextcloud
Write-Host "Поиск Nextcloud..." -ForegroundColor Yellow
`$nextcloudPaths = @()
`$nextcloudPaths += Get-ChildItem -Path C:\ -Recurse -Directory -Filter "nextcloud" -ErrorAction SilentlyContinue | Select-Object -First 5 -ExpandProperty FullName
`$nextcloudPaths += Get-ChildItem -Path D:\ -Recurse -Directory -Filter "nextcloud" -ErrorAction SilentlyContinue | Select-Object -First 5 -ExpandProperty FullName
`$nextcloudPaths += Get-ChildItem -Path C:\inetpub -Recurse -Directory -Filter "nextcloud" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
"`$nextcloudPaths" | Out-File "$vmOut\nextcloud_paths.txt"

# Копирование конфигов Nextcloud
foreach (`$path in `$nextcloudPaths) {
    if (Test-Path `$path) {
        `$configPath = Join-Path `$path "config"
        if (Test-Path `$configPath) {
            Copy-Item -Path `$configPath -Destination "$vmOut\nextcloud_config" -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Копирование всей директории если найдена
        `$destName = (Split-Path `$path -Leaf) + "_" + (Get-Random)
        Copy-Item -Path `$path -Destination "$vmOut\nextcloud_\`$destName" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 2. Поиск почтовых серверов
Write-Host "Поиск почтовых серверов..." -ForegroundColor Yellow
`$mailPaths = @()
# MailEnable
`$mailPaths += Get-ChildItem -Path "C:\Program Files (x86)\Mail Enable" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
# SmarterMail
`$mailPaths += Get-ChildItem -Path "C:\Program Files\SmarterTools" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
# hMailServer
`$mailPaths += Get-ChildItem -Path "C:\Program Files (x86)\hMailServer" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
# Общие пути
`$mailPaths += Get-ChildItem -Path C:\ -Recurse -Directory -Filter "*mail*" -ErrorAction SilentlyContinue | Select-Object -First 10 -ExpandProperty FullName
"`$mailPaths" | Out-File "$vmOut\mail_paths.txt"

# Копирование конфигов почты
foreach (`$path in `$mailPaths) {
    if (Test-Path `$path) {
        `$parent = Split-Path `$path -Parent
        `$name = Split-Path `$path -Leaf
        `$dest = "$vmOut\mail_\$name"
        Copy-Item -Path `$path -Destination `$dest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 3. Поиск веб-сайтов и SSL сертификатов
Write-Host "Поиск веб-сайтов и SSL..." -ForegroundColor Yellow
`$webPaths = @()
`$webPaths += Get-ChildItem -Path "C:\inetpub" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
`$webPaths += Get-ChildItem -Path C:\ -Recurse -Directory -Filter "*www*" -ErrorAction SilentlyContinue | Select-Object -First 10 -ExpandProperty FullName
`$webPaths += Get-ChildItem -Path C:\ -Recurse -Directory -Filter "*site*" -ErrorAction SilentlyContinue | Select-Object -First 10 -ExpandProperty FullName
"`$webPaths" | Out-File "$vmOut\web_paths.txt"

# Копирование сайтов
foreach (`$path in `$webPaths) {
    if (Test-Path `$path -PathType Container) {
        `$name = Split-Path `$path -Leaf
        `$dest = "$vmOut\web_\$name"
        Copy-Item -Path `$path -Destination `$dest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 4. Извлечение SSL сертификатов
Write-Host "Извлечение SSL сертификатов..." -ForegroundColor Yellow
`$certExportDir = "$vmOut\SSL_Certificates"
if (!(Test-Path `$certExportDir)) { New-Item -ItemType Directory -Path `$certExportDir | Out-Null }

# Экспорт сертификатов из хранилища
`$stores = @("LocalMachine\My", "LocalMachine\Root", "LocalMachine\CA")
foreach (`$store in `$stores) {
    `$certs = Get-ChildItem -Path Cert:\`$store -ErrorAction SilentlyContinue
    foreach (`$cert in `$certs) {
        try {
            `$certName = `$cert.Subject -replace '[^a-zA-Z0-9]', '_'
            `$pfxPath = "$certExportDir\$certName.pfx"
            `$cerPath = "$certExportDir\$certName.cer"
            
            # Экспорт без приватного ключа
            `$cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert) | 
                Set-Content -Path `$cerPath -Encoding Byte -ErrorAction SilentlyContinue
            
            # Попытка экспорта с приватным ключом (требует пароля)
            # `$cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, "temp123") |
            #     Set-Content -Path `$pfxPath -Encoding Byte -ErrorAction SilentlyContinue
        } catch {
            Write-Host "Ошибка экспорта сертификата: `$(`$cert.Subject)" -ForegroundColor Red
        }
    }
}

# Поиск файлов сертификатов на диске
`$certFiles = Get-ChildItem -Path C:\ -Include *.pfx,*.p12,*.cer,*.crt,*.pem,*.key -Recurse -ErrorAction SilentlyContinue
foreach (`$file in `$certFiles) {
    try {
        Copy-Item -Path `$file.FullName -Destination `$certExportDir -Force -ErrorAction SilentlyContinue
    } catch {}
}

# 5. Поиск Asterisk
Write-Host "Поиск Asterisk..." -ForegroundColor Yellow
`$asteriskPaths = @()
# Если Asterisk установлен через Cygwin или подобную среду
`$asteriskPaths += Get-ChildItem -Path "C:\cygwin" -Recurse -Filter "*asterisk*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
`$asteriskPaths += Get-ChildItem -Path "C:\Program Files" -Recurse -Directory -Filter "*asterisk*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
`$asteriskPaths += Get-ChildItem -Path C:\ -Recurse -Directory -Filter "*asterisk*" -ErrorAction SilentlyContinue | Select-Object -First 10 -ExpandProperty FullName
"`$asteriskPaths" | Out-File "$vmOut\asterisk_paths.txt"

# Копирование конфигов Asterisk
foreach (`$path in `$asteriskPaths) {
    if (Test-Path `$path) {
        `$name = Split-Path `$path -Leaf
        `$dest = "$vmOut\asterisk_\$name"
        Copy-Item -Path `$path -Destination `$dest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Особые файлы по заданию
Write-Host "Поиск специальных файлов..." -ForegroundColor Yellow
`$specialFiles = @(
    "C:\in4_LanWanLogin.txt",
    "D:\in4_LanWanLogin.txt"
)
foreach (`$file in `$specialFiles) {
    if (Test-Path `$file) {
        Copy-Item -Path `$file -Destination `$vmOut -Force
        Write-Host "  Найден: `$file" -ForegroundColor Green
    }
}

# Поиск баз данных
Write-Host "Поиск баз данных..." -ForegroundColor Yellow
`$dbPaths = @()
`$dbPaths += Get-ChildItem -Path C:\ -Include *.mdf,*.ldf,*.ibd,*.frm,*.myd,*.myi -Recurse -ErrorAction SilentlyContinue | Select-Object -First 20
foreach (`$db in `$dbPaths) {
    try {
        `$dest = "$vmOut\databases\$(`$db.Directory.Name)"
        if (!(Test-Path `$dest)) { New-Item -ItemType Directory -Path `$dest | Out-Null }
        Copy-Item -Path `$db.FullName -Destination `$dest -Force -ErrorAction SilentlyContinue
    } catch {}
}

Write-Host "`nИзвлечение завершено!" -ForegroundColor Green
Write-Host "Данные сохранены в: `$vmOut" -ForegroundColor Cyan
"@
        
        # Копирование скрипта в VM
        Copy-Item -Path $vmScript -Destination "C$\TempExtraction\extract_vm.ps1" -Session $session -Force
        
        # Выполнение скрипта в VM
        Invoke-Command -Session $session -ScriptBlock {
            powershell.exe -ExecutionPolicy Bypass -File "C:\TempExtraction\extract_vm.ps1"
        }
        
        # Копирование результатов обратно
        $vmResultDir = "$vmOutputDir\collected"
        if (!(Test-Path $vmResultDir)) { New-Item -ItemType Directory -Path $vmResultDir | Out-Null }
        
        Copy-Item -Path "\\$IPAddress\C$\TempExtraction\*" -Destination $vmResultDir -Recurse -Force
        
        Remove-PSSession $session
        Write-Host "  [+] Данные из VM скопированы" -ForegroundColor Green
        
    } catch {
        Write-Host "  [-] Ошибка подключения к VM: $_" -ForegroundColor Red
    }
}

# Получение списка всех VM
Write-Host "`n[*] Сканирование виртуальных машин..." -ForegroundColor Cyan
$vms = Get-VM | Select-Object Name, State, @{N='IPAddress';E={(Get-VMNetworkAdapter -VMName $_.Name).IpAddresses[0]}}

foreach ($vm in $vms) {
    Write-Host "`nОбработка VM: $($vm.Name)" -ForegroundColor Cyan
    Write-Host "  Состояние: $($vm.State)" -ForegroundColor Gray
    Write-Host "  IP: $($vm.IPAddress)" -ForegroundColor Gray
    
    if ($vm.State -eq "Running" -and $vm.IPAddress) {
        # Попытка подключения с разными учетками
        $credentials = @(
            @{User="admin"; Pass="F@il2511"},
            @{User="p0mik"; Pass="32!p0mik!23"},
            @{User="user"; Pass="admin"},
            @{User="root"; Pass="root"},
            @{User="root"; Pass="admin"}
        )
        
        foreach ($cred in $credentials) {
            if (Test-VMAccessible -VMName $vm.Name -IPAddress $vm.IPAddress -Username $cred.User -Password $cred.Pass) {
                Extract-FromVM -VMName $vm.Name -IPAddress $vm.IPAddress -Username $cred.User -Password $cred.Pass -VMDir $VMDataDir
                break
            }
        }
    } elseif ($vm.State -eq "Off") {
        Write-Host "  VM выключена. Попытка монтирования VHD..." -ForegroundColor Yellow
        
        # Получение путей к VHD
        $vhdPaths = (Get-VMHardDiskDrive -VMName $vm.Name).Path
        
        foreach ($vhd in $vhdPaths) {
            if (Test-Path $vhd) {
                Write-Host "  Монтирование: $vhd" -ForegroundColor Yellow
                
                try {
                    Mount-VHD -Path $vhd -ReadOnly
                    Start-Sleep -Seconds 3
                    
                    # Получение буквы диска
                    $disk = Get-Disk | Where-Object {$_.OperationalStatus -eq "Online" -and $_.IsOffline -eq $false} | Sort-Object Number -Descending | Select-Object -First 1
                    $partitions = Get-Partition -DiskNumber $disk.Number | Where-Object {$_.DriveLetter}
                    
                    foreach ($partition in $partitions) {
                        $driveLetter = $partition.DriveLetter
                        Write-Host "  Диск смонтирован как: ${driveLetter}:" -ForegroundColor Green
                        
                        $vmOutputDir = "$VMDir\$($vm.Name)_offline"
                        if (!(Test-Path $vmOutputDir)) { New-Item -ItemType Directory -Path $vmOutputDir | Out-Null }
                        
                        # Сканирование смонтированного диска
                        Write-Host "  Сканирование диска ${driveLetter}:..." -ForegroundColor Yellow
                        
                        # Nextcloud
                        Get-ChildItem -Path "${driveLetter}:" -Recurse -Directory -Filter "nextcloud" -ErrorAction SilentlyContinue | 
                            ForEach-Object {
                                $dest = "$vmOutputDir\nextcloud_$($_.Name)"
                                Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        
                        # Почта
                        Get-ChildItem -Path "${driveLetter}:" -Recurse -Directory -Filter "*mail*" -ErrorAction SilentlyContinue | 
                            ForEach-Object {
                                $dest = "$vmOutputDir\mail_$($_.Name)"
                                Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        
                        # Веб
                        if (Test-Path "${driveLetter}:\inetpub") {
                            Copy-Item -Path "${driveLetter}:\inetpub" -Destination "$vmOutputDir\web_inetpub" -Recurse -Force -ErrorAction SilentlyContinue
                        }
                        
                        # SSL сертификаты
                        $certFiles = Get-ChildItem -Path "${driveLetter}:" -Include *.pfx,*.p12,*.cer,*.crt,*.pem,*.key -Recurse -ErrorAction SilentlyContinue
                        $certDest = "$vmOutputDir\SSL_Certificates"
                        if (!(Test-Path $certDest)) { New-Item -ItemType Directory -Path $certDest | Out-Null }
                        foreach ($cert in $certFiles) {
                            Copy-Item -Path $cert.FullName -Destination $certDest -Force -ErrorAction SilentlyContinue
                        }
                        
                        # Asterisk
                        Get-ChildItem -Path "${driveLetter}:" -Recurse -Directory -Filter "*asterisk*" -ErrorAction SilentlyContinue | 
                            ForEach-Object {
                                $dest = "$vmOutputDir\asterisk_$($_.Name)"
                                Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        
                        # in4_LanWanLogin.txt
                        if (Test-Path "${driveLetter}:\in4_LanWanLogin.txt") {
                            Copy-Item -Path "${driveLetter}:\in4_LanWanLogin.txt" -Destination $vmOutputDir -Force
                        }
                    }
                    
                    Dismount-VHD -Path $vhd
                    Write-Host "  Диск размонтирован" -ForegroundColor Green
                    
                } catch {
                    Write-Host "  Ошибка монтирования VHD: $_" -ForegroundColor Red
                    try { Dismount-VHD -Path $vhd -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
    } else {
        Write-Host "  VM в состоянии $($vm.State), пропуск" -ForegroundColor Yellow
    }
}

# Извлечение данных с хоста Hyper-V
Write-Host "`n[*] Извлечение данных с хоста Hyper-V..." -ForegroundColor Cyan
$hostOutputDir = "$VMDataDir\HyperV_Host"
if (!(Test-Path $hostOutputDir)) { New-Item -ItemType Directory -Path $hostOutputDir | Out-Null }

# Копирование in4_LanWanLogin.txt
if (Test-Path "C:\in4_LanWanLogin.txt") {
    Copy-Item -Path "C:\in4_LanWanLogin.txt" -Destination $hostOutputDir -Force
    Write-Host "  [+] in4_LanWanLogin.txt скопирован" -ForegroundColor Green
}

# Экспорт сертификатов хоста
$hostCertDir = "$hostOutputDir\SSL_Certificates"
if (!(Test-Path $hostCertDir)) { New-Item -ItemType Directory -Path $hostCertDir | Out-Null }

$stores = @("LocalMachine\My", "LocalMachine\Root", "LocalMachine\CA")
foreach ($store in $stores) {
    $certs = Get-ChildItem -Path Cert:\$store -ErrorAction SilentlyContinue
    foreach ($cert in $certs) {
        try {
            $certName = $cert.Subject -replace '[^a-zA-Z0-9]', '_'
            $cerPath = "$hostCertDir\$certName.cer"
            $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert) | 
                Set-Content -Path $cerPath -Encoding Byte -ErrorAction SilentlyContinue
        } catch {}
    }
}

# Поиск сертификатов на дисках
Get-ChildItem -Path C:\,D:\ -Include *.pfx,*.p12,*.cer,*.crt,*.pem,*.key -Recurse -ErrorAction SilentlyContinue | 
    ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $hostCertDir -Force -ErrorAction SilentlyContinue
    }

# Копирование IIS конфигов
if (Test-Path "C:\inetpub") {
    Copy-Item -Path "C:\inetpub" -Destination "$hostOutputDir\web_inetpub" -Recurse -Force -ErrorAction SilentlyContinue
}

# Экспорт конфигурации IIS
try {
    C:\Windows\System32\inetsrv\appcmd.exe add backup "ExtractionBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Write-Host "  [+] Бэкап IIS создан" -ForegroundColor Green
} catch {
    Write-Host "  [-] Не удалось создать бэкап IIS" -ForegroundColor Yellow
}

# Поиск и копирование баз данных
$dbHostDir = "$hostOutputDir\databases"
if (!(Test-Path $dbHostDir)) { New-Item -ItemType Directory -Path $dbHostDir | Out-Null }

Get-ChildItem -Path C:\,D:\ -Include *.mdf,*.ldf,*.ibd,*.frm,*.myd,*.myi -Recurse -ErrorAction SilentlyContinue | 
    Select-Object -First 50 |
    ForEach-Object {
        $dest = "$dbHostDir\$($_.Directory.Name)"
        if (!(Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
        Copy-Item -Path $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    }

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Извлечение данных завершено!" -ForegroundColor Green
Write-Host "Все данные в: $VMDataDir" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Создание архива
$archiveName = "HyperV_Extraction_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
Write-Host "`n[*] Создание архива: $archiveName" -ForegroundColor Cyan

# Добавление 7-Zip в PATH если установлен
if (Test-Path "C:\Program Files\7-Zip\7z.exe") {
    $env:Path += ";C:\Program Files\7-Zip"
}

if (Get-Command 7z -ErrorAction SilentlyContinue) {
    7z a -tzip "$OutputDir\$archiveName" "$VMDataDir\*" -mx=9
    Write-Host "  [+] Архив создан: $OutputDir\$archiveName" -ForegroundColor Green
} else {
    Write-Host "  [-] 7-Zip не найден, архив не создан" -ForegroundColor Yellow
    Write-Host "  Вручную заархивируйте: $VMDataDir" -ForegroundColor Yellow
}

Write-Host "`nГотово! Скопируйте директорию $OutputDir на вашу машину." -ForegroundColor Green
PSEOF

    log_info "PowerShell скрипт создан: $ps_script"
}

# Основная функция подключения и извлечения
main() {
    clear
    echo "=============================================="
    echo "Скрипт извлечения данных с Windows Server 2012"
    echo "Цель: $WIN_SERVER"
    echo "=============================================="
    echo ""
    
    check_dependencies
    
    # Создание локальной директории
    mkdir -p "$LOCAL_OUTPUT_DIR"
    log_info "Создана директория для данных: $LOCAL_OUTPUT_DIR"
    
    # Создание PowerShell скрипта
    create_windows_extraction_script
    
    echo ""
    log_warn "ВНИМАНИЕ: Для выполнения требуется ручной шаг!"
    echo ""
    echo "Порядок действий:"
    echo "1. Подключитесь к $WIN_SERVER через RDP:"
    echo "   xfreerdp /v:$WIN_SERVER /u:$WIN_USER /p:$WIN_PASS +clipboard"
    echo ""
    echo "2. ИЛИ используйте WinRM (если настроен):"
    echo "   evil-winrm -i $WIN_SERVER -u $WIN_USER -p '$WIN_PASS'"
    echo ""
    echo "3. Скопируйте файл extract_data.ps1 на сервер в C:\\"
    echo ""
    echo "4. Запустите на сервере от имени Administrator:"
    echo "   powershell -ExecutionPolicy Bypass -File C:\\extract_data.ps1"
    echo ""
    echo "5. После завершения скрипт создаст архив в C:\\ExtractionTemp\\"
    echo "   Скопируйте этот архив обратно на свою машину"
    echo ""
    echo "Альтернативно: можно запустить скрипт удаленно если настроен WinRM"
    echo ""
    
    # Попытка автоматического подключения через WinRM
    read -p "Попытать автоматическое подключение через WinRM? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        attempt_winrm_connection
    fi
}

attempt_winrm_connection() {
    log_info "Попытка подключения через WinRM..."
    
    # Попытка с основными учетными данными
    if command -v evil-winrm &> /dev/null; then
        log_info "Запуск evil-winrm..."
        echo "Нажмите Ctrl+C когда закончите"
        evil-winrm -i "$WIN_SERVER" -u "$WIN_USER" -p "$WIN_PASS"
    else
        log_warn "evil-winrm не найден. Используйте ручное копирование скрипта."
        log_info "Установите: gem install evil-winrm"
    fi
}

# Запуск
main "$@"
