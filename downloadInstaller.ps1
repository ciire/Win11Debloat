# 1. Setup Paths
$subFolder = "installation2"
$destinationFolder = Join-Path -Path $PSScriptRoot -ChildPath $subFolder

# Create the folder if it doesn't exist
if (-not (Test-Path $destinationFolder)) {
    New-Item -ItemType Directory -Path $destinationFolder | Out-Null
    Write-Host "Created folder: $destinationFolder" -ForegroundColor Gray
}

# 2. Define Apps to Download
$apps = @(
    @{ ID = "Perplexity.Comet"; Name = "Comet" },
    @{ ID = "TheDocumentFoundation.LibreOffice"; Name = "LibreOffice" },
    @{ ID = "Adobe.Acrobat.Reader.64-bit"; Name = "AdobeReader" }
)

Write-Host "--- Starting Forced Downloads to \$subFolder ---" -ForegroundColor Yellow

foreach ($app in $apps) {
    Write-Host "`nProcessing: $($app.Name)..." -ForegroundColor White
    
    # Attempt Winget Download first for all
    winget download --id $($app.ID) --download-directory $destinationFolder --accept-source-agreements --ignore-security-hash

    if ($LASTEXITCODE -ne 0 -or $app.Name -eq "AdobeReader") {
        Write-Host "Applying specific download logic for $($app.Name)..." -ForegroundColor Cyan
        
        switch ($app.Name) {
            "Comet" {
                $url = "https://www.perplexity.ai/rest/browser/download?platform=win_x64&channel=stable"
                $out = Join-Path $destinationFolder "CometSetup.exe"
                Invoke-WebRequest -Uri $url -OutFile $out
                Write-Host "Downloaded Comet manually." -ForegroundColor Green
            }
            "LibreOffice" {
                # Note: This is a direct link to the latest stable x64 MSI
                $url = "https://download.documentfoundation.org/libreoffice/stable/24.8.4/win/x86_64/LibreOffice_24.8.4_Win_x86-64.msi"
                $out = Join-Path $destinationFolder "LibreOffice_Setup.msi"
                Invoke-WebRequest -Uri $url -OutFile $out
                Write-Host "Downloaded LibreOffice manually." -ForegroundColor Green
            }
            "AdobeReader" {
                # This URL is a more direct path to the latest 64-bit MUI installer
                $url = "https://ardownload2.adobe.com/pub/adobe/reader/win/AcrobatDC/2500121111/AcroRdrDCx642500121111_MUI.exe"
                $out = Join-Path $destinationFolder "AcroRdrDCx64_MUI.exe"
                
                Write-Host "Fetching Adobe Offline Installer (Version 25.001.21111)..." -ForegroundColor Yellow
                try {
                    Invoke-WebRequest -Uri $url -OutFile $out -ErrorAction Stop
                    Write-Host "Success: Downloaded Adobe Offline Installer." -ForegroundColor Green
                } catch {
                    Write-Host "Manual URL failed. Trying the Enterprise redirect..." -ForegroundColor Cyan
                    # Fallback to the redirector URL if the direct path changes again
                    $fallbackUrl = "https://get.adobe.com/reader/enterprise/"
                    Write-Host "Please download manually from: $fallbackUrl" -ForegroundColor Yellow
                }
            }   
        }
    }
}

Write-Host "`n--- All downloads completed ---" -ForegroundColor Green