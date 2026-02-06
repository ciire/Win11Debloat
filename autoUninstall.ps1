# ---------------------------------------------------------
# DEPENDENCIES (Required for the Checkbox GUI)
# ---------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

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
    Write-Host "Aggregating user-removable applications..." -ForegroundColor Cyan

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $regApps = Get-ItemProperty $registryPaths -ErrorAction SilentlyContinue | 
        Where-Object { $_.DisplayName -and ($_.UninstallString -or $_.QuietUninstallString) -and ($_.SystemComponent -ne 1) } |
        Select-Object @{Name="DisplayName"; Expression={$_.DisplayName}}, 
                      @{Name="Id"; Expression={$_.PSChildName}}, 
                      @{Name="Type"; Expression={"Win32/64"}},
                      UninstallString

    $appxApps = Get-AppxPackage -AllUsers | 
        Where-Object { 
            $_.IsFramework -eq $false -and $_.IsResourcePackage -eq $false -and 
            $_.IsBundle -eq $false -and $_.NonRemovable -eq $false -and
            $_.SignatureKind -ne "System" -and $_.Name -notmatch "Extension"
        } |
        Select-Object @{Name="DisplayName"; Expression={
                          $n = $_.Name -replace 'Microsoft\.', '' -replace 'Windows\.', ''
                          $n = [regex]::Replace($n, '([a-z])([A-Z])', '$1 $2')
                          $n.Replace('.', ' ')
                      }}, 
                      @{Name="Id"; Expression={$_.PackageFullName}}, 
                      @{Name="Type"; Expression={"UWP"}},
                      @{Name="UninstallString"; Expression={"Remove-AppxPackage"}}

    return ($regApps + $appxApps) | Sort-Object DisplayName
}

function Show-Checklist {
    param($AppList)

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="App Uninstaller" Height="600" Width="400" Background="#121212" WindowStartupLocation="CenterScreen">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <TextBlock Text="Select Bloatware" Foreground="#00fbff" FontSize="18" Margin="0,0,0,10" FontWeight="Bold"/>
        
        <ListBox x:Name="AppList" Grid.Row="1" Background="#1e1e1e" Foreground="White" BorderThickness="0">
            <ListBox.ItemTemplate>
                <DataTemplate>
                    <StackPanel Orientation="Horizontal" Margin="2">
                        <CheckBox IsChecked="{Binding IsChecked}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding DisplayName}" VerticalAlignment="Center" FontSize="13"/>
                    </StackPanel>
                </DataTemplate>
            </ListBox.ItemTemplate>
        </ListBox>

        <CheckBox x:Name="SaveToggle" Grid.Row="2" Content="Save this selection to apps_to_remove.txt" 
                  Foreground="Gray" Margin="0,15,0,0" IsChecked="True" VerticalAlignment="Center"/>
        
        <Button x:Name="BtnStart" Grid.Row="3" Content="UNINSTALL SELECTED" Height="35" Margin="0,10,0,0" 
                Background="#ff3333" Foreground="White" FontWeight="Bold"/>
    </Grid>
</Window>
"@
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $wrappedList = foreach($app in $AppList) { [PSCustomObject]@{ DisplayName = $app.DisplayName; IsChecked = $false; Original = $app } }
    ($window.FindName("AppList")).ItemsSource = $wrappedList
    
    $saveToggle = $window.FindName("SaveToggle")
    ($window.FindName("BtnStart")).Add_Click({ $window.DialogResult = $true; $window.Close() })
    
    if ($window.ShowDialog()) { 
        return [PSCustomObject]@{
            AppsToUninst = $wrappedList | Where-Object { $_.IsChecked } | Select-Object -ExpandProperty Original
            SaveRequested = $saveToggle.IsChecked
        }
    }
}
function Invoke-SimulatedManualRemoval {
    param ([Parameter(Mandatory=$true)] $App)
    $name = $App.DisplayName
    Write-Host "`n[ACTION] Triggering uninstall for: $name" -ForegroundColor Cyan
    try {
        if ($App.Type -eq "UWP") {
            $procName = ($name -replace "\s+", "")
            Stop-Process -Name "*$procName*" -ErrorAction SilentlyContinue
            Remove-AppxPackage -AllUsers -Package $App.Id -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match $App.DisplayName } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        } else {
            $uninst = $App.UninstallString -replace '"', ''
            if ($uninst -match "msiexec") {
                Start-Process "msiexec.exe" -ArgumentList "/x $($App.Id)" -Wait
            } else {
                if ($uninst -match ".exe") {
                    $path = ($uninst -split ".exe")[0] + ".exe"; $args = ($uninst -split ".exe")[1]
                    Start-Process -FilePath $path -ArgumentList $args -Verb RunAs -Wait
                } else {
                    Start-Process cmd.exe -ArgumentList "/c `"$uninst`"" -Verb RunAs -Wait
                }
            }
        }
        Start-Sleep -Seconds 3
        $stillExists = Get-UnifiedAppList | Where-Object { $_.DisplayName -eq $name }
        if ($stillExists) { Write-Host " [!] $name is still in the list." -ForegroundColor Red } 
        else { Write-Host " [+] Successfully removed $name." -ForegroundColor Green }
    } catch { Write-Host " [!] Error: Could not trigger uninstaller for $name." -ForegroundColor Red }
}

# ---------------------------------------------------------
# MAIN EXECUTION
# ---------------------------------------------------------

Test-Admin

$configPath = Join-Path $PSScriptRoot "apps_to_remove.txt"
$selectedApps = @()

# 1. CHECK FOR CONFIG FILE
if (Test-Path $configPath) {
    Write-Host "[CONFIG] Found apps_to_remove.txt. Skipping selection..." -ForegroundColor Green
    $savedNames = Get-Content $configPath
    $allApps = Get-UnifiedAppList
    $selectedApps = $allApps | Where-Object { $savedNames -contains $_.DisplayName }
} 
else {
    # 2. SELECTION GUI
    $allApps = Get-UnifiedAppList
    $guiResult = Show-Checklist -AppList $allApps

    if ($guiResult.AppsToUninst) {
        $selectedApps = $guiResult.AppsToUninst
        
        # 3. OPTIONAL SAVE LOGIC
        if ($guiResult.SaveRequested) {
            $selectedApps.DisplayName | Out-File $configPath -Force
            Write-Host "[CONFIG] Selection saved to $configPath" -ForegroundColor Gray
        }
    }
}

# 4. RUN THE UNINSTALLER
if (-not $selectedApps) {
    Write-Host "No apps to uninstall. Exiting." -ForegroundColor Yellow
} else {
    foreach ($item in $selectedApps) {
        Invoke-SimulatedManualRemoval -App $item
    }
    Write-Host "`nCleanup completed." -ForegroundColor White
}

Pause