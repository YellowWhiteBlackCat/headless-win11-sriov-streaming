# bootstrap.ps1
# Runs during the specialize pass of Windows Setup, as SYSTEM.
# Job: VirtIO drivers + QEMU Guest Agent + OpenSSH Server + SSH key.

$ErrorActionPreference = "Stop"

$root   = $PSScriptRoot
$logDir = "C:\Windows\Setup\Scripts"
$log    = Join-Path $logDir "bootstrap.log"

if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try {
        Add-Content -LiteralPath $log -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Logging must never abort the bootstrap.
    }
    Write-Host $line
}

try {
    Write-Log "==== bootstrap.ps1 start (root=$root) ===="

    # ---------------------------------------------------------------
    # 0. Locate virtio-win media (drive letter must not be hardcoded)
    # ---------------------------------------------------------------
    $virtio = $null
    foreach ($cd in Get-CimInstance Win32_CDROMDrive) {
        if (Test-Path -LiteralPath (Join-Path $cd.Drive "virtio-win-guest-tools.exe")) {
            $virtio = $cd.Drive
            break
        }
    }
    if (-not $virtio) {
        foreach ($cd in Get-CimInstance Win32_CDROMDrive) {
            if (Test-Path -LiteralPath (Join-Path $cd.Drive "guest-agent\qemu-ga-x86_64.msi")) {
                $virtio = $cd.Drive
                break
            }
        }
    }
    if (-not $virtio) { throw "virtio-win media not found on any CD-ROM" }
    Write-Log "virtio-win media: $virtio"

    # ---------------------------------------------------------------
    # 1. VirtIO drivers (viostor / NetKVM / vioserial / balloon / ...)
    # ---------------------------------------------------------------
    foreach ($driverDir in Get-ChildItem -LiteralPath $virtio -Directory -ErrorAction SilentlyContinue) {
        foreach ($arch in @("w11\amd64", "2k25\amd64")) {
            $infDir = Join-Path $driverDir.FullName $arch
            if (Test-Path -LiteralPath $infDir) {
                Get-ChildItem -LiteralPath $infDir -Filter *.inf -File -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        Write-Log ("pnputil: " + $_.FullName)
                        & pnputil.exe /add-driver $_.FullName /install 2>&1 |
                            ForEach-Object { Write-Log ("  " + $_) }
                    }
            }
        }
    }
    Write-Log "VirtIO driver staging finished"

    # ---------------------------------------------------------------
    # 2. QEMU Guest Agent (needs vioserial driver from step 1)
    # ---------------------------------------------------------------
    $qga = Join-Path $virtio "guest-agent\qemu-ga-x86_64.msi"
    $qgaOk = $false
    if (Test-Path -LiteralPath $qga) {
        # qga-vss.dll's COM registration fails with 1722 when the COM+
        # services are not up yet; start them before (and between) tries.
        foreach ($svcName in @("EventSystem", "COMSysApp")) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne "Running") {
                try {
                    Start-Service -Name $svcName -ErrorAction Stop
                    Write-Log "started COM+ service $svcName"
                } catch {
                    Write-Log "WARN: could not start $svcName : $($_.Exception.Message)"
                }
            }
        }

        $qgaLog = Join-Path $logDir "qemu-ga-install.log"
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-Log "installing QEMU Guest Agent (attempt $attempt): $qga"
            $p = Start-Process msiexec.exe -ArgumentList @("/i", $qga, "/qn", "/norestart", "/l*v", $qgaLog) -Wait -PassThru
            Write-Log "qemu-ga msiexec exit code: $($p.ExitCode)"
            if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
                $qgaOk = $true
                break
            }
            if ($p.ExitCode -eq 1603 -and $attempt -lt 3) {
                # COM+ may still be coming up; retry after a short wait.
                Start-Sleep -Seconds 15
                foreach ($svcName in @("EventSystem", "COMSysApp")) {
                    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -ne "Running") {
                        try { Start-Service -Name $svcName -ErrorAction Stop } catch { }
                    }
                }
            } else {
                break
            }
        }
    } else {
        Write-Log "WARN: qemu-ga-x86_64.msi not found"
    }

    if (-not $qgaOk) {
        # Last resort: extract the MSI without running it and register
        # qemu-ga.exe as a service manually (skips the VSS provider, which
        # is not needed for guest-ping / guest-network-get-interfaces).
        Write-Log "QEMU Guest Agent MSI failed; falling back to manual service install"
        $qgaExtract = Join-Path $env:ProgramData "qemu-ga-extract"
        if (Test-Path -LiteralPath $qgaExtract) {
            Remove-Item -LiteralPath $qgaExtract -Recurse -Force
        }
        New-Item -ItemType Directory -Path $qgaExtract -Force | Out-Null
        $adminArgs = @("/a", $qga, "/qn", "TARGETDIR=`"$qgaExtract`"")
        $p = Start-Process msiexec.exe -ArgumentList $adminArgs -Wait -PassThru
        Write-Log "qemu-ga admin-extract exit code: $($p.ExitCode)"
        if ($p.ExitCode -ne 0) {
            throw "qemu-ga admin extract failed with exit code $($p.ExitCode)"
        }

        # The MSI cabinet may contain qemu-ga.exe or qemu_ga.exe.
        $srcExe = Get-ChildItem -LiteralPath $qgaExtract -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @("qemu-ga.exe", "qemu_ga.exe") } |
            Select-Object -First 1
        if (-not $srcExe) {
            throw "qemu-ga.exe/qemu_ga.exe not found after admin extract"
        }

        $qgaDest = Join-Path $env:ProgramFiles "Qemu-ga"
        if (-not (Test-Path -LiteralPath $qgaDest)) {
            New-Item -ItemType Directory -Path $qgaDest -Force | Out-Null
        }
        Get-ChildItem -LiteralPath $srcExe.DirectoryName -File |
            Copy-Item -Destination $qgaDest -Force
        $gaExe = Join-Path $qgaDest "qemu-ga.exe"
        $gaExeAlt = Join-Path $qgaDest "qemu_ga.exe"
        if (-not (Test-Path -LiteralPath $gaExe) -and (Test-Path -LiteralPath $gaExeAlt)) {
            Rename-Item -LiteralPath $gaExeAlt -NewName "qemu-ga.exe"
        }
        if (-not (Test-Path -LiteralPath $gaExe)) {
            throw "qemu-ga.exe missing after copy"
        }

        # The failed MSI transaction can leave a half-rolled-back QEMU-GA
        # service behind; remove it before trying to create our own.
        if (Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue) {
            & sc.exe stop "QEMU-GA" 2>&1 | ForEach-Object { Write-Log ("sc stop: " + $_) }
            & sc.exe delete "QEMU-GA" 2>&1 | ForEach-Object { Write-Log ("sc delete: " + $_) }
            Start-Sleep -Seconds 3
            if (Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue) {
                & reg.exe delete "HKLM\SYSTEM\CurrentControlSet\Services\QEMU-GA" /f 2>&1 |
                    ForEach-Object { Write-Log ("reg delete: " + $_) }
                Start-Sleep -Seconds 1
            }
        }

        try {
            $installOut = & $gaExe -s install 2>&1
            $installCode = $LASTEXITCODE
        } catch {
            $installOut = $_.Exception.Message
            $installCode = -1
        }
        Write-Log "qemu-ga -s install exit code: $installCode"
        $installOut | ForEach-Object { Write-Log ("qemu-ga -s install: " + $_) }

        if ($installCode -ne 0) {
            # New-Service handles argument quoting correctly in PowerShell
            # 5.1 (unlike a direct sc.exe call).
            Write-Log "qemu-ga -s install failed; creating service via New-Service"
            $binPath = '"' + $gaExe + '" -d --retry-path'
            try {
                New-Service -Name "QEMU-GA" -DisplayName "QEMU Guest Agent" `
                    -BinaryPathName $binPath -StartupType Automatic -ErrorAction Stop |
                    Out-Null
                Write-Log "QEMU-GA service created via New-Service"
            } catch {
                Write-Log "New-Service failed: $($_.Exception.Message)"
                # Last resort: sc.exe through cmd.exe, which preserves quotes.
                $cmdLine = 'sc.exe create QEMU-GA binPath= "\"C:\Program Files\Qemu-ga\qemu-ga.exe\" -d --retry-path" start= auto DisplayName= "QEMU Guest Agent" obj= LocalSystem'
                & cmd.exe /d /s /c $cmdLine 2>&1 |
                    ForEach-Object { Write-Log ("sc.exe create: " + $_) }
                Write-Log "sc.exe create fallback exit code: $LASTEXITCODE"
            }
        }
        $gaSvc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
        if ($gaSvc) {
            Set-Service -Name "QEMU-GA" -StartupType Automatic
            try {
                Start-Service -Name "QEMU-GA" -ErrorAction Stop
                Write-Log "QEMU-GA service started"
            } catch {
                Write-Log "WARN: QEMU-GA service did not start: $($_.Exception.Message)"
            }
            $qgaOk = $true
        } else {
            throw "QEMU Guest Agent service could not be created"
        }
    }

    # ---------------------------------------------------------------
    # 3. Local admin user (SSH target)
    # ---------------------------------------------------------------
    $user        = "vmadmin"
    $tempPassword = $env:BOOTSTRAP_ADMIN_PASSWORD
    if (-not $tempPassword) {
        $envFile = Join-Path $root "bootstrap.env"
        if (Test-Path -LiteralPath $envFile) {
            foreach ($line in Get-Content -LiteralPath $envFile) {
                if ($line -match '^\s*ADMIN_PASSWORD=(.*)$') {
                    $tempPassword = $Matches[1].Trim()
                }
            }
        }
    }
    if (-not $tempPassword) {
        $tempPassword = "CHANGE-ME-ADMIN-PASSWORD"
        Write-Log "WARNING: no ADMIN_PASSWORD provided; using insecure placeholder"
    }
    if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
        $secure = ConvertTo-SecureString $tempPassword -AsPlainText -Force
        # Note: Windows PowerShell 5.1's New-LocalUser has no
        # -PasswordNeverExpires parameter; keep the basic set.
        New-LocalUser -Name $user -Password $secure `
            -FullName "VM Admin" -Description "Admin user (SSH)" | Out-Null
        $adminsGroup = (Get-LocalGroup -SID "S-1-5-32-544").Name
        Add-LocalGroupMember -Group $adminsGroup -Member $user
        Write-Log "created local user $user"
    } else {
        Write-Log "local user $user already exists"
    }

    # ---------------------------------------------------------------
    # 4. OpenSSH Server (offline MSI first, Windows capability fallback)
    # ---------------------------------------------------------------
    $sshInstalled = $false
    $msi = Get-ChildItem -LiteralPath $root -Filter "OpenSSH-Win64-*.msi" -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($msi) {
        $sshLog = Join-Path $logDir "openssh-install.log"
        Write-Log "installing OpenSSH from MSI: $($msi.FullName)"
        $p = Start-Process msiexec.exe -ArgumentList @("/i", $msi.FullName, "/qn", "/norestart", "/l*v", $sshLog) -Wait -PassThru
        Write-Log "openssh msiexec exit code: $($p.ExitCode)"
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { $sshInstalled = $true }
    }

    if (-not $sshInstalled) {
        Write-Log "MSI unavailable/failed; trying Windows capability (online)"
        $cap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
            Where-Object Name -Like "OpenSSH.Server*" | Select-Object -First 1
        if ($cap) {
            for ($i = 1; $i -le 5; $i++) {
                try {
                    Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
                    Write-Log "OpenSSH.Server capability installed (attempt $i)"
                    $sshInstalled = $true
                    break
                } catch {
                    Write-Log ("capability attempt $i failed: " + $_.Exception.Message)
                    Start-Sleep -Seconds 20
                }
            }
        }
    }

    if (-not $sshInstalled) { throw "OpenSSH Server could not be installed" }

    if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
        $installScript = "C:\Program Files\OpenSSH\install-sshd.ps1"
        if (Test-Path -LiteralPath $installScript) {
            Write-Log "sshd service missing; running install-sshd.ps1"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript | Out-Null
        } else {
            throw "sshd service missing and no install-sshd.ps1"
        }
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd -ErrorAction SilentlyContinue
    Write-Log "sshd service configured"

    # ---------------------------------------------------------------
    # 5. Firewall: TCP/22
    # ---------------------------------------------------------------
    if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
            -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        Write-Log "firewall rule OpenSSH-Server-In-TCP created"
    } else {
        Write-Log "firewall rule already exists"
    }

    # ---------------------------------------------------------------
    # 6. SSH public key for Administrators
    # ---------------------------------------------------------------
    $pubFile = Join-Path $root "admin_ed25519.pub"
    if (-not (Test-Path -LiteralPath $pubFile)) { throw "admin_ed25519.pub not found on bootstrap media" }
    $key = (Get-Content -LiteralPath $pubFile -Raw).Trim()

    $sshDir = "$env:ProgramData\ssh"
    if (-not (Test-Path -LiteralPath $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    $keyFile = Join-Path $sshDir "administrators_authorized_keys"
    Set-Content -LiteralPath $keyFile -Value $key -Encoding ascii -NoNewline
    icacls.exe $keyFile /inheritance:r /grant "*S-1-5-32-544:(F)" /grant "SYSTEM:(F)" | Out-Null
    Write-Log "administrators_authorized_keys written + ACL fixed"

    Restart-Service -Name sshd -Force
    Write-Log "sshd restarted"

    # ---------------------------------------------------------------
    # Done
    # ---------------------------------------------------------------
    Set-Content -LiteralPath (Join-Path $logDir "bootstrap.done") `
        -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii
    Write-Log "==== bootstrap.ps1 done ===="
}
catch {
    $msg = "BOOTSTRAP FAILED: $($_.Exception.Message)"
    try {
        Add-Content -LiteralPath $log -Value $msg -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host $msg
    }
    Write-Host $msg
    exit 1
}
