# Mole - Uninstall Command
# Interactive application uninstaller for Windows

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('d')]
    [switch]$DebugMode,
    
    [Alias('r')]
    [switch]$Rescan,
    
    [Alias('h')]
    [switch]$ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"

# Import core modules
. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\ui.ps1"
. "$libDir\core\file_ops.ps1"

# ============================================================================
# Configuration
# ============================================================================

$script:CacheDir = "$env:USERPROFILE\.cache\mole"
# v2: entries carry RegistryKey/QuietUninstallString used to verify removal
$script:AppCacheFile = "$script:CacheDir\app_scan_cache_v2.json"
$script:CacheTTLHours = 24

# ============================================================================
# Help
# ============================================================================

function Show-UninstallHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mmo uninstall$esc[0m - Interactive application uninstaller"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mo uninstall [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --rescan     Force rescan of installed applications"
    Write-Host "  --debug      Enable debug logging"
    Write-Host "  --help       Show this help message"
    Write-Host ""
    Write-Host "$esc[33mFeatures:$esc[0m"
    Write-Host "  - Scans installed programs from registry and Windows Apps"
    Write-Host "  - Shows program size and last used date"
    Write-Host "  - Interactive selection with arrow keys"
    Write-Host "  - Cleans leftover files after uninstall"
    Write-Host ""
}

# ============================================================================
# Protected Applications
# ============================================================================

$script:ProtectedApps = @(
    "Microsoft Windows"
    "Windows Feature Experience Pack"
    "Microsoft Edge"
    "Microsoft Edge WebView2"
    "Windows Security"
    "Microsoft Visual C++ *"
    "Microsoft .NET *"
    ".NET Desktop Runtime*"
    "Microsoft Update Health Tools"
    "NVIDIA Graphics Driver*"
    "AMD Software*"
    "Intel*Driver*"
)

function Test-ProtectedApp {
    param([string]$AppName)

    foreach ($pattern in $script:ProtectedApps) {
        if ($AppName -like $pattern) {
            return $true
        }
    }
    return $false
}

# ============================================================================
# Application Discovery
# ============================================================================

function Get-InstalledApplications {
    <#
    .SYNOPSIS
        Scan and return all installed applications
    #>
    param([switch]$ForceRescan)

    # Check cache
    if (-not $ForceRescan -and (Test-Path $script:AppCacheFile)) {
        $cacheInfo = Get-Item $script:AppCacheFile
        $cacheAge = (Get-Date) - $cacheInfo.LastWriteTime

        if ($cacheAge.TotalHours -lt $script:CacheTTLHours) {
            Write-Debug "Loading from cache..."
            try {
                $cached = Get-Content $script:AppCacheFile | ConvertFrom-Json
                return $cached
            }
            catch {
                Write-Debug "Cache read failed, rescanning..."
            }
        }
    }

    Write-Info "Scanning installed applications..."

    $apps = @()

    # Registry paths for installed programs
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $count = 0
    $total = $registryPaths.Count

    foreach ($path in $registryPaths) {
        $count++
        Write-Progress -Activity "Scanning applications" -Status "Registry path $count of $total" -PercentComplete (($count / $total) * 50)

        try {
            $regItems = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue

            foreach ($item in $regItems) {
                # Skip items without required properties
                $displayName = $null
                $uninstallString = $null

                try { $displayName = $item.DisplayName } catch { }
                try { $uninstallString = $item.UninstallString } catch { }

                if ([string]::IsNullOrWhiteSpace($displayName) -or [string]::IsNullOrWhiteSpace($uninstallString)) {
                    continue
                }

                if (Test-ProtectedApp $displayName) {
                    continue
                }

                # Calculate size
                $sizeKB = 0
                try {
                    if ($item.EstimatedSize) {
                        $sizeKB = [long]$item.EstimatedSize
                    }
                    elseif ($item.InstallLocation -and (Test-Path $item.InstallLocation -ErrorAction SilentlyContinue)) {
                        $sizeKB = Get-PathSizeKB -Path $item.InstallLocation
                    }
                }
                catch { }

                # Get install date
                $installDate = $null
                try {
                    if ($item.InstallDate) {
                        $installDate = [DateTime]::ParseExact($item.InstallDate, "yyyyMMdd", $null)
                    }
                }
                catch { }

                # Get other properties safely
                $publisher = $null
                $version = $null
                $installLocation = $null
                $quietUninstallString = $null

                try { $publisher = $item.Publisher } catch { }
                try { $version = $item.DisplayVersion } catch { }
                try { $installLocation = $item.InstallLocation } catch { }
                try { $quietUninstallString = $item.QuietUninstallString } catch { }

                $apps += [PSCustomObject]@{
                    Name = $displayName
                    Publisher = $publisher
                    Version = $version
                    SizeKB = $sizeKB
                    SizeHuman = Format-ByteSize -Bytes ($sizeKB * 1024)
                    InstallLocation = $installLocation
                    UninstallString = $uninstallString
                    QuietUninstallString = $quietUninstallString
                    RegistryKey = $item.PSPath
                    PackageFullName = $null
                    InstallDate = $installDate
                    Source = "Registry"
                }
            }
        }
        catch {
            Write-Debug "Error scanning registry path $path : $_"
        }
    }

    # UWP / Store Apps
    Write-Progress -Activity "Scanning applications" -Status "Scanning Windows Apps" -PercentComplete 75

    try {
        $uwpApps = Get-AppxPackage -ErrorAction SilentlyContinue |
                   Where-Object {
                       $_.IsFramework -eq $false -and
                       $_.SignatureKind -ne 'System' -and
                       -not (Test-ProtectedApp $_.Name)
                   }

        foreach ($uwp in $uwpApps) {
            # Get friendly name
            $name = $uwp.Name
            try {
                $manifest = Get-AppxPackageManifest -Package $uwp.PackageFullName -ErrorAction SilentlyContinue
                if ($manifest.Package.Properties.DisplayName -and
                    -not $manifest.Package.Properties.DisplayName.StartsWith("ms-resource:")) {
                    $name = $manifest.Package.Properties.DisplayName
                }
            }
            catch { }

            # Calculate size
            $sizeKB = 0
            if ($uwp.InstallLocation -and (Test-Path $uwp.InstallLocation)) {
                $sizeKB = Get-PathSizeKB -Path $uwp.InstallLocation
            }

            $apps += [PSCustomObject]@{
                Name = $name
                Publisher = $uwp.Publisher
                Version = $uwp.Version
                SizeKB = $sizeKB
                SizeHuman = Format-ByteSize -Bytes ($sizeKB * 1024)
                InstallLocation = $uwp.InstallLocation
                UninstallString = $null
                QuietUninstallString = $null
                RegistryKey = $null
                PackageFullName = $uwp.PackageFullName
                InstallDate = $null
                Source = "WindowsStore"
            }
        }
    }
    catch {
        Write-Debug "Could not enumerate UWP apps: $_"
    }

    Write-Progress -Activity "Scanning applications" -Completed

    # Sort by size (largest first)
    $apps = $apps | Sort-Object -Property SizeKB -Descending

    # Cache results
    if (-not (Test-Path $script:CacheDir)) {
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
    }
    $apps | ConvertTo-Json -Depth 5 | Set-Content $script:AppCacheFile

    return $apps
}

# ============================================================================
# Application Selection UI
# ============================================================================

function Show-AppSelectionMenu {
    <#
    .SYNOPSIS
        Interactive menu for selecting applications to uninstall
    #>
    param([array]$Apps)

    if ($Apps.Count -eq 0) {
        Write-MoleWarning "No applications found to uninstall"
        return @()
    }

    $esc = [char]27
    $selectedIndices = @{}
    $currentIndex = 0
    $pageSize = 15
    $pageStart = 0
    $searchTerm = ""
    $filteredApps = $Apps

    # Hide cursor (may fail in non-interactive terminals)
    try { [Console]::CursorVisible = $false } catch { }

    try {
        while ($true) {
            Clear-Host

            # Header
            Write-Host ""
            Write-Host "$esc[1;35mSelect Applications to Uninstall$esc[0m"
            Write-Host ""
            Write-Host "$esc[90mUse: $($script:Icons.NavUp)$($script:Icons.NavDown) navigate | Space select | Enter confirm | Q quit | / search$esc[0m"
            Write-Host ""

            # Search indicator
            if ($searchTerm) {
                Write-Host "$esc[33mSearch:$esc[0m $searchTerm ($($filteredApps.Count) matches)"
                Write-Host ""
            }

            # Display apps
            $pageEnd = [Math]::Min($pageStart + $pageSize, $filteredApps.Count)

            for ($i = $pageStart; $i -lt $pageEnd; $i++) {
                $app = $filteredApps[$i]
                $isSelected = $selectedIndices.ContainsKey($app.Name)
                $isCurrent = ($i -eq $currentIndex)

                # Selection indicator
                $checkbox = if ($isSelected) { "$esc[32m[$($script:Icons.Success)]$esc[0m" } else { "[ ]" }

                # Highlight current
                if ($isCurrent) {
                    Write-Host "$esc[7m" -NoNewline  # Reverse video
                }

                # App info
                $name = $app.Name
                if ($name.Length -gt 40) {
                    $name = $name.Substring(0, 37) + "..."
                }

                $size = $app.SizeHuman
                if (-not $size -or $size -eq "0B") {
                    $size = "N/A"
                }

                Write-Host ("  {0} {1,-42} {2,10}" -f $checkbox, $name, $size) -NoNewline

                if ($isCurrent) {
                    Write-Host "$esc[0m"  # Reset
                }
                else {
                    Write-Host ""
                }
            }

            # Footer
            Write-Host ""
            $selectedCount = $selectedIndices.Count
            if ($selectedCount -gt 0) {
                $totalSize = 0
                foreach ($key in $selectedIndices.Keys) {
                    $app = $Apps | Where-Object { $_.Name -eq $key }
                    if ($app.SizeKB) {
                        $totalSize += $app.SizeKB
                    }
                }
                $totalSizeHuman = Format-ByteSize -Bytes ($totalSize * 1024)
                Write-Host "$esc[33mSelected:$esc[0m $selectedCount apps ($totalSizeHuman)"
            }

            # Page indicator
            $totalPages = [Math]::Ceiling($filteredApps.Count / $pageSize)
            $currentPage = [Math]::Floor($pageStart / $pageSize) + 1
            Write-Host "$esc[90mPage $currentPage of $totalPages$esc[0m"

            # Handle input
            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                'UpArrow' {
                    if ($currentIndex -gt 0) {
                        $currentIndex--
                        if ($currentIndex -lt $pageStart) {
                            $pageStart = [Math]::Max(0, $pageStart - $pageSize)
                        }
                    }
                }
                'DownArrow' {
                    if ($currentIndex -lt $filteredApps.Count - 1) {
                        $currentIndex++
                        if ($currentIndex -ge $pageStart + $pageSize) {
                            $pageStart += $pageSize
                        }
                    }
                }
                'PageUp' {
                    $pageStart = [Math]::Max(0, $pageStart - $pageSize)
                    $currentIndex = $pageStart
                }
                'PageDown' {
                    $pageStart = [Math]::Min($filteredApps.Count - $pageSize, $pageStart + $pageSize)
                    if ($pageStart -lt 0) { $pageStart = 0 }
                    $currentIndex = $pageStart
                }
                'Spacebar' {
                    $app = $filteredApps[$currentIndex]
                    if ($selectedIndices.ContainsKey($app.Name)) {
                        $selectedIndices.Remove($app.Name)
                    }
                    else {
                        $selectedIndices[$app.Name] = $true
                    }
                }
                'Enter' {
                    if ($selectedIndices.Count -gt 0) {
                        # Return selected apps
                        $selected = $Apps | Where-Object { $selectedIndices.ContainsKey($_.Name) }
                        return $selected
                    }
                }
                'Escape' {
                    return @()
                }
                'Q' {
                    return @()
                }
                'Oem2' {  # Forward slash
                    # Search mode
                    Write-Host ""
                    Write-Host "Search: " -NoNewline
                    try { [Console]::CursorVisible = $true } catch { }
                    $searchTerm = Read-Host
                    try { [Console]::CursorVisible = $false } catch { }

                    if ($searchTerm) {
                        $filteredApps = $Apps | Where-Object { $_.Name -like "*$searchTerm*" }
                    }
                    else {
                        $filteredApps = $Apps
                    }
                    $currentIndex = 0
                    $pageStart = 0
                }
                'Backspace' {
                    if ($searchTerm) {
                        $searchTerm = ""
                        $filteredApps = $Apps
                        $currentIndex = 0
                        $pageStart = 0
                    }
                }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

# ============================================================================
# Uninstallation
# ============================================================================

function Split-UninstallCommand {
    <#
    .SYNOPSIS
        Split a registry uninstall command into executable and arguments
    .DESCRIPTION
        Runs the executable directly instead of through cmd.exe, so quoting in the
        registry value cannot be re-interpreted as shell syntax.
    #>
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }

    $command = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())

    if ($command.StartsWith('"')) {
        $end = $command.IndexOf('"', 1)
        if ($end -lt 2) {
            return $null
        }
        return @{
            FilePath  = $command.Substring(1, $end - 1)
            Arguments = $command.Substring($end + 1).Trim()
        }
    }

    # Unquoted: the executable ends at the first ".exe" (paths may contain spaces)
    $match = [regex]::Match($command, '^(.+?\.exe)(?:\s+(.*))?$', 'IgnoreCase')
    if ($match.Success) {
        return @{
            FilePath  = $match.Groups[1].Value
            Arguments = $match.Groups[2].Value.Trim()
        }
    }

    return @{
        FilePath  = $command
        Arguments = ""
    }
}

function Get-AppProperty {
    <#
    .SYNOPSIS
        Read an app property that may be missing (older cache entries) under strict mode
    #>
    param(
        [Parameter(Mandatory)]
        [object]$App,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $App.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Test-AppStillInstalled {
    <#
    .SYNOPSIS
        True while the app's registration still exists (or cannot be checked)
    #>
    param([Parameter(Mandatory)][object]$App)

    if ($App.Source -eq "WindowsStore") {
        $packageFullName = Get-AppProperty -App $App -Name "PackageFullName"
        if (-not $packageFullName) {
            return $true
        }
        return [bool](Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $packageFullName })
    }

    $registryKey = Get-AppProperty -App $App -Name "RegistryKey"
    if (-not $registryKey) {
        return $true
    }
    return Test-Path -LiteralPath $registryKey
}

function Wait-AppRemoved {
    <#
    .SYNOPSIS
        Give uninstallers that hand off to a child process a moment to finish
    #>
    param(
        [Parameter(Mandatory)][object]$App,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if (-not (Test-AppStillInstalled -App $App)) {
            return $true
        }
        if ((Get-Date) -ge $deadline) {
            return $false
        }
        Start-Sleep -Milliseconds 1000
    }
}

function Invoke-AppUninstaller {
    <#
    .SYNOPSIS
        Run an app's own uninstaller once
    .DESCRIPTION
        Uses QuietUninstallString when the vendor registered one. Otherwise the regular
        uninstaller runs once with its own UI; guessing silent switches can launch the
        uninstaller repeatedly or pass flags it misreads.
    #>
    param([Parameter(Mandatory)][object]$App)

    $esc = [char]27

    if ($App.Source -eq "WindowsStore") {
        Remove-AppxPackage -Package $App.PackageFullName -ErrorAction Stop
        return
    }

    $uninstallString = Get-AppProperty -App $App -Name "UninstallString"
    $quietUninstallString = Get-AppProperty -App $App -Name "QuietUninstallString"

    if ($uninstallString -match '(?i)msiexec') {
        $productCode = [regex]::Match($uninstallString, '\{[0-9A-Fa-f-]+\}').Value
        if (-not $productCode) {
            throw "No MSI product code in uninstall command"
        }

        $process = Start-Process -FilePath "msiexec.exe" `
            -ArgumentList "/x", $productCode, "/qn", "/norestart" `
            -Wait -PassThru -NoNewWindow

        # 0 = done, 3010 = done, restart required
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            Write-Host " $esc[33m(opening the uninstaller window)$esc[0m" -NoNewline
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/x", $productCode -Wait
        }
        return
    }

    $commandLine = if ($quietUninstallString) { $quietUninstallString } else { $uninstallString }
    $command = Split-UninstallCommand -CommandLine $commandLine
    if ($null -eq $command) {
        throw "Could not parse uninstall command"
    }

    if (-not $quietUninstallString) {
        Write-Host " $esc[33m(follow the uninstaller window)$esc[0m" -NoNewline
    }

    $startParams = @{
        FilePath = $command.FilePath
        Wait     = $true
    }
    if ($command.Arguments) {
        $startParams.ArgumentList = $command.Arguments
    }
    Start-Process @startParams
}

function Test-PathInside {
    param(
        [string]$Path,
        [string]$Parent
    )

    try {
        $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $normalizedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    }
    catch {
        return $false
    }

    return $normalizedPath -eq $normalizedParent -or
           $normalizedPath.StartsWith("$normalizedParent\", [StringComparison]::OrdinalIgnoreCase)
}

function Get-LeftoverFolder {
    <#
    .SYNOPSIS
        Decide whether an uninstalled app's install folder may be offered for removal
    .OUTPUTS
        @{ Path; Reason } - Path is $null when the folder must be kept; Reason says why
    #>
    param(
        [Parameter(Mandatory)][object]$App,
        [array]$OtherApps = @()
    )

    $location = Get-AppProperty -App $App -Name "InstallLocation"
    if ([string]::IsNullOrWhiteSpace($location)) {
        return @{ Path = $null; Reason = "no install folder registered" }
    }

    $location = $location.Trim().Trim('"').TrimEnd('\')
    if (-not (Test-Path -LiteralPath $location -PathType Container)) {
        return @{ Path = $null; Reason = "install folder already gone" }
    }

    if (-not (Test-SafePath -Path $location)) {
        return @{ Path = $null; Reason = "protected location, kept: $location" }
    }

    # A folder that also holds another app (shared "D:\Tools", a vendor folder) is not leftover
    foreach ($other in $OtherApps) {
        $otherLocation = Get-AppProperty -App $other -Name "InstallLocation"
        if ([string]::IsNullOrWhiteSpace($otherLocation)) {
            continue
        }
        $otherLocation = $otherLocation.Trim().Trim('"')
        if ((Test-PathInside -Path $otherLocation -Parent $location) -or
            (Test-PathInside -Path $location -Parent $otherLocation)) {
            return @{ Path = $null; Reason = "shared with $($other.Name), kept: $location" }
        }
    }

    return @{ Path = $location; Reason = $null }
}

function Uninstall-SelectedApps {
    <#
    .SYNOPSIS
        Uninstall the selected applications
    #>
    param(
        [array]$Apps,

        # Every installed app, used to keep folders shared with apps that stay
        [array]$AllApps = @()
    )

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[1;35mUninstalling Applications$esc[0m"
    Write-Host ""

    $successCount = 0
    $failCount = 0
    $leftovers = @()

    foreach ($app in $Apps) {
        Write-Host "$esc[34m$($script:Icons.Arrow)$esc[0m Uninstalling: $($app.Name)" -NoNewline

        try {
            Invoke-AppUninstaller -App $app

            if (Wait-AppRemoved -App $app) {
                Write-Host " $esc[32m$($script:Icons.Success)$esc[0m"
                $successCount++

                $otherApps = @($AllApps | Where-Object { $_ -ne $app -and $_.Name -ne $app.Name })
                $leftover = Get-LeftoverFolder -App $app -OtherApps $otherApps
                if ($leftover.Path) {
                    $leftovers += [PSCustomObject]@{ App = $app.Name; Path = $leftover.Path }
                }
                elseif ($leftover.Reason -and $leftover.Reason -notmatch '^(no install folder|install folder already gone)') {
                    Write-Host "  $esc[90mLeftover files: $($leftover.Reason)$esc[0m"
                }
            }
            else {
                # Cancelled, failed, or still running: its files are still in use
                Write-Host " $esc[33m(not confirmed - app is still registered, files kept)$esc[0m"
                $failCount++
            }
        }
        catch {
            Write-Host " $esc[31m$($script:Icons.Error)$esc[0m"
            Write-Debug "Uninstall failed: $_"
            $failCount++
        }
    }

    # Leftover folders are removed only after the user sees exactly which ones
    if ($leftovers.Count -gt 0) {
        Write-Host ""
        Write-Host "$esc[33mLeftover install folders:$esc[0m"
        foreach ($leftover in $leftovers) {
            $size = Format-ByteSize -Bytes (Get-PathSize -Path $leftover.Path)
            Write-Host "  $($script:Icons.List) $($leftover.Path) $esc[90m($($leftover.App), $size)$esc[0m"
        }
        Write-Host ""

        if (Read-Confirmation -Prompt "Delete these folders permanently?" -Default $false) {
            foreach ($leftover in $leftovers) {
                $null = Remove-SafeItem -Path $leftover.Path -Description "Leftover files ($($leftover.App))" -Recurse
            }
        }
        else {
            Write-Info "Leftover folders kept"
        }
    }

    # Summary
    Write-Host ""
    Write-Host "$esc[1;35mUninstall Complete$esc[0m"
    Write-Host "  Successfully uninstalled: $esc[32m$successCount$esc[0m"
    if ($failCount -gt 0) {
        Write-Host "  Not confirmed or failed: $esc[33m$failCount$esc[0m"
    }
    Write-Host ""

    # Clear cache
    if (Test-Path $script:AppCacheFile) {
        Remove-Item $script:AppCacheFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# Main Entry Point
# ============================================================================

function Main {
    # Enable debug if requested
    if ($DebugMode) {
        $env:MOLE_DEBUG = "1"
        $DebugPreference = "Continue"
    }

    # Show help
    if ($ShowHelp) {
        Show-UninstallHelp
        return
    }

    # Clear screen
    Clear-Host

    # Get installed apps
    $apps = @(Get-InstalledApplications -ForceRescan:$Rescan)

    if ($apps.Count -eq 0) {
        Write-MoleWarning "No applications found"
        return
    }

    Write-Info "Found $($apps.Count) applications"

    # Show selection menu
    $selected = @(Show-AppSelectionMenu -Apps $apps)

    if ($selected.Count -eq 0) {
        Write-Info "No applications selected"
        return
    }

    # Confirm uninstall
    $esc = [char]27
    Clear-Host
    Write-Host ""
    Write-Host "$esc[33mThe following applications will be uninstalled:$esc[0m"
    Write-Host ""

    foreach ($app in $selected) {
        Write-Host "  $($script:Icons.List) $($app.Name) ($($app.SizeHuman))"
    }

    Write-Host ""
    $confirm = Read-Host "Continue? (y/N)"

    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
        Uninstall-SelectedApps -Apps $selected -AllApps $apps
    }
    else {
        Write-Info "Cancelled"
    }
}

# Run main
Main
