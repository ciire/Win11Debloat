# ---------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------

function Test-Admin {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-NOT $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "Elevating privileges..." -ForegroundColor Yellow
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Exit
    }
}

function Get-UnifiedAppList {
    Write-Host "Aggregating all installed applications..." -ForegroundColor Cyan

    # 1. SCAN REGISTRY (Win32 and Win64 apps like Docker)
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $regApps = Get-ItemProperty $registryPaths -ErrorAction SilentlyContinue | 
        Where-Object { $_.DisplayName -and ($_.UninstallString -or $_.QuietUninstallString) } |
        Select-Object @{Name="DisplayName"; Expression={$_.DisplayName}}, 
                      @{Name="Id"; Expression={$_.PSChildName}}, 
                      @{Name="Type"; Expression={"Win32/64"}},
                      UninstallString

    # 2. SCAN APPX (Windows Store apps like Solitaire/Xbox)
    $appxApps = Get-AppxPackage -AllUsers | 
        Select-Object @{Name="DisplayName"; Expression={$_.Name}}, 
                      @{Name="Id"; Expression={$_.PackageFullName}}, 
                      @{Name="Type"; Expression={"UWP"}},
                      @{Name="UninstallString"; Expression={"Remove-AppxPackage"}}

    # 3. MERGE AND SORT
    return ($regApps + $appxApps) | Sort-Object DisplayName
}

function Invoke-SimulatedManualRemoval {
    param ([Parameter(Mandatory=$true)] $App)
    
    $name = $App.DisplayName
    Write-Host "`n[ACTION] Triggering uninstall for: $name" -ForegroundColor Cyan

    try {
        # --- CATEGORY 1: STORE APPS (Evernote, Solitaire, etc.) ---
        if ($App.Type -eq "UWP") {
            Write-Host " -> Attempting to unregister Store App..." -ForegroundColor Gray
            
            # Kill Evernote specifically if it's hanging the process
            $procName = ($name -replace "\s+", "")
            Stop-Process -Name "*$procName*" -ErrorAction SilentlyContinue

            # Run the removal as a background task so PowerShell doesn't "hang" forever
            $task = Remove-AppxPackage -AllUsers -Package $App.Id -ErrorAction SilentlyContinue
            
            # Deprovision so it doesn't come back
            Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match $App.DisplayName } | 
                Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        } 
        
        # --- CATEGORY 2: REGISTRY / DRIVERS (Realtek, Acrobat, etc.) ---
        else {
            $uninst = $App.UninstallString -replace '"', ''

            if ($uninst -match "msiexec") {
                Write-Host " -> Opening Windows Installer Wizard..." -ForegroundColor Yellow
                # Forces the MSI wizard to the front
                Start-Process "msiexec.exe" -ArgumentList "/x $($App.Id)" -Wait
            } 
            else {
                Write-Host " -> Launching Uninstaller (Check for a blinking icon in your taskbar!)..." -ForegroundColor Yellow
                
                # 'RunAs' forces the "Yes/No" UAC prompt for things like Realtek Drivers
                if ($uninst -match ".exe") {
                    # Split the path and arguments if the driver uses them
                    $path = ($uninst -split ".exe")[0] + ".exe"
                    $args = ($uninst -split ".exe")[1]
                    Start-Process -FilePath $path -ArgumentList $args -Verb RunAs -Wait
                } else {
                    Start-Process cmd.exe -ArgumentList "/c `"$uninst`"" -Verb RunAs -Wait
                }
            }
        }

        # --- VERIFICATION ---
        Start-Sleep -Seconds 3
        $stillExists = Get-UnifiedAppList | Where-Object { $_.DisplayName -eq $name }
        
        if ($stillExists) {
            Write-Host " [!] $name is still in the list. Check for a minimized window!" -ForegroundColor Red
        } else {
            Write-Host " [+] Successfully removed $name." -ForegroundColor Green
        }
    }
    catch {
        Write-Host " [!] Error: Could not trigger uninstaller for $name. (Admin permission denied?)" -ForegroundColor Red
    }
}

# ---------------------------------------------------------
# MAIN EXECUTION
# ---------------------------------------------------------

Test-Admin

$allApps = Get-UnifiedAppList
# The selection window you wanted to keep
$selectedApps = $allApps | Out-GridView -Title "Select Bloatware to Nuking (Hold Ctrl to select multiple)" -PassThru

if (-not $selectedApps) {
    Write-Host "No apps selected. Exiting." -ForegroundColor Yellow
} else {
    foreach ($item in $selectedApps) {
        Invoke-SimulatedManualRemoval -App $item
    }
    Write-Host "`nCleanup completed. Some apps may require a restart to disappear from the Start Menu." -ForegroundColor White
}

Pause