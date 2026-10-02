# Mole - User Cleanup Module
# Cleans user-level temporary files, caches, and downloads

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_USER_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_USER_LOADED) { return }
$script:MOLE_CLEAN_USER_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"

# ============================================================================
# Windows Temp Files Cleanup
# ============================================================================

function Clear-UserTempFiles {
    <#
    .SYNOPSIS
        Clean user temporary files
    #>
    param([int]$DaysOld = 7)
    
    Start-Section "User temp files"
    
    # User temp directory
    $userTemp = $env:TEMP
    if (Test-Path $userTemp) {
        $null = Remove-OldFiles -Path $userTemp -DaysOld $DaysOld -Description "User temp files"
    }
    
    # Windows Temp (if accessible)
    $winTemp = "$env:WINDIR\Temp"
    if ((Test-Path $winTemp) -and (Test-IsAdmin)) {
        $null = Remove-OldFiles -Path $winTemp -DaysOld $DaysOld -Description "Windows temp files"
    }
    
    Stop-Section
}

# ============================================================================
# Downloads Folder Cleanup
# ============================================================================

function Clear-OldDownloads {
    <#
    .SYNOPSIS
        Clean old files from Downloads folder (with user confirmation pattern)
    #>
    param([int]$DaysOld = 30)
    
    $downloadsPath = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
    
    if (-not (Test-Path $downloadsPath)) {
        return
    }
    
    # Find old installers and archives
    $patterns = @('*.exe', '*.msi', '*.zip', '*.7z', '*.rar', '*.tar.gz', '*.iso')
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)
    
    $oldFiles = @()
    foreach ($pattern in $patterns) {
        $files = Get-ChildItem -Path $downloadsPath -Filter $pattern -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -lt $cutoffDate }
        if ($files) {
            $oldFiles += $files
        }
    }
    
    if ($oldFiles.Count -gt 0) {
        $paths = $oldFiles | ForEach-Object { $_.FullName }
        $null = Remove-SafeItems -Paths $paths -Description "Old downloads (>${DaysOld}d)" -AllowUserData
    }
}

# ============================================================================
# Recycle Bin Cleanup
# ============================================================================

function Clear-RecycleBin {
    <#
    .SYNOPSIS
        Empty the Recycle Bin
    #>
    
    if (Test-DryRunMode) {
        Write-DryRun "Recycle Bin (would empty)"
        Set-SectionActivity
        return
    }
    
    try {
        # Use Shell.Application COM object
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.Namespace(0xA)  # Recycle Bin
        $items = $recycleBin.Items()
        
        if ($items.Count -gt 0) {
            # Calculate size
            $totalSize = 0
            foreach ($item in $items) {
                $totalSize += $item.Size
            }
            
            # Clear using Clear-RecycleBin cmdlet (Windows 10+)
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            
            $sizeHuman = Format-ByteSize -Bytes $totalSize
            Write-Success "Recycle Bin $($script:Colors.Green)($sizeHuman)$($script:Colors.NC)"
            Set-SectionActivity
        }
    }
    catch {
        Write-Debug "Could not clear Recycle Bin: $_"
    }
}

# ============================================================================
# Recent Files Cleanup
# ============================================================================

function Clear-RecentFiles {
    <#
    .SYNOPSIS
        Clean old recent file shortcuts
    #>
    param([int]$DaysOld = 30)
    
    $recentPath = "$env:APPDATA\Microsoft\Windows\Recent"
    
    if (Test-Path $recentPath) {
        $null = Remove-OldFiles -Path $recentPath -DaysOld $DaysOld -Filter "*.lnk" -Description "Old recent shortcuts"
    }
    
    # AutomaticDestinations (jump lists)
    $autoDestPath = "$recentPath\AutomaticDestinations"
    if (Test-Path $autoDestPath) {
        $null = Remove-OldFiles -Path $autoDestPath -DaysOld $DaysOld -Description "Old jump list entries"
    }
}

# ============================================================================
# Thumbnail Cache Cleanup
# ============================================================================

function Clear-ThumbnailCache {
    <#
    .SYNOPSIS
        Clean Windows thumbnail cache
    #>
    
    $thumbCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    
    if (-not (Test-Path $thumbCachePath)) {
        return
    }
    
    # Thumbnail cache files (thumbcache_*.db)
    $thumbFiles = Get-ChildItem -Path $thumbCachePath -Filter "thumbcache_*.db" -File -ErrorAction SilentlyContinue
    
    if ($thumbFiles) {
        $paths = $thumbFiles | ForEach-Object { $_.FullName }
        $null = Remove-SafeItems -Paths $paths -Description "Thumbnail cache"
    }
    
    # Icon cache
    $iconCache = "$env:LOCALAPPDATA\IconCache.db"
    if (Test-Path $iconCache) {
        $null = Remove-SafeItem -Path $iconCache -Description "Icon cache"
    }
}

# ============================================================================
# Windows Error Reports Cleanup
# ============================================================================

function Clear-ErrorReports {
    <#
    .SYNOPSIS
        Clean Windows Error Reporting files
    #>
    param([int]$DaysOld = 7)
    
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)

    # Files only: listing folders too would count every file twice (folder size + file)
    $werPaths = @(
        "$env:LOCALAPPDATA\Microsoft\Windows\WER"
        "$env:LOCALAPPDATA\CrashDumps"
    )

    $reportFiles = foreach ($path in $werPaths) {
        if (Test-Path -LiteralPath $path) {
            Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoffDate } |
                ForEach-Object { $_.FullName }
        }
    }
    $reportFiles = @($reportFiles | Select-Object -Unique)
    if ($reportFiles.Count -gt 0) {
        $null = Remove-SafeItems -Paths $reportFiles -Description "Error reports (>${DaysOld}d old)"
    }

    # Memory dumps left in the profile root (CrashDumps is covered above)
    $dumps = @(Get-ChildItem -LiteralPath $env:USERPROFILE -Filter "*.dmp" -File -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -lt $cutoffDate } |
               ForEach-Object { $_.FullName })
    if ($dumps.Count -gt 0) {
        $null = Remove-SafeItems -Paths $dumps -Description "Memory dumps (>${DaysOld}d old)"
    }
}

# ============================================================================
# Windows Prefetch Cleanup (requires admin)
# ============================================================================

function Clear-Prefetch {
    <#
    .SYNOPSIS
        Clean Windows Prefetch files (requires admin)
    #>
    param([int]$DaysOld = 14)
    
    if (-not (Test-IsAdmin)) {
        Write-Debug "Skipping Prefetch cleanup - requires admin"
        return
    }
    
    $prefetchPath = "$env:WINDIR\Prefetch"
    
    if (Test-Path $prefetchPath) {
        $null = Remove-OldFiles -Path $prefetchPath -DaysOld $DaysOld -Description "Prefetch files"
    }
}

# ============================================================================
# Log Files Cleanup
# ============================================================================

function Clear-UserLogs {
    <#
    .SYNOPSIS
        Clean old log files from common locations
    #>
    param([int]$DaysOld = 7)
    
    $logLocations = @(
        "$env:LOCALAPPDATA\Temp\*.log"
        "$env:APPDATA\*.log"
        "$env:USERPROFILE\*.log"
    )
    
    foreach ($location in $logLocations) {
        $parent = Split-Path -Parent $location
        $filter = Split-Path -Leaf $location
        
        if (Test-Path $parent) {
            $logs = Get-ChildItem -Path $parent -Filter $filter -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$DaysOld) }
            
            if ($logs) {
                $paths = $logs | ForEach-Object { $_.FullName }
                $null = Remove-SafeItems -Paths $paths -Description "Old log files"
            }
        }
    }
}

# ============================================================================
# Clipboard History Cleanup
# ============================================================================

function Clear-ClipboardHistory {
    <#
    .SYNOPSIS
        Clear Windows clipboard history
    #>
    
    if (Test-DryRunMode) {
        Write-DryRun "Clipboard history (would clear)"
        return
    }
    
    try {
        # Load Windows Forms assembly for clipboard access
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        
        # Clear current clipboard
        [System.Windows.Forms.Clipboard]::Clear()
        
        # Clear clipboard history (Windows 10 1809+)
        $clipboardPath = "$env:LOCALAPPDATA\Microsoft\Windows\Clipboard"
        if (Test-Path $clipboardPath) {
            $null = Clear-DirectoryContents -Path $clipboardPath -Description "Clipboard history"
        }
    }
    catch {
        Write-Debug "Could not clear clipboard: $_"
    }
}

# ============================================================================
# Main User Cleanup Function
# ============================================================================

function Invoke-UserCleanup {
    <#
    .SYNOPSIS
        Run all user-level cleanup tasks
    #>
    param(
        [int]$TempDaysOld = 7,
        [int]$DownloadsDaysOld = 30,
        [int]$LogDaysOld = 7,
        [switch]$IncludeDownloads,
        [switch]$IncludeRecycleBin
    )
    
    Start-Section "User essentials"
    
    # Always clean these
    Clear-UserTempFiles -DaysOld $TempDaysOld
    Clear-RecentFiles -DaysOld 30
    Clear-ThumbnailCache
    Clear-ErrorReports -DaysOld 7
    Clear-UserLogs -DaysOld $LogDaysOld
    Clear-Prefetch -DaysOld 14
    
    # Optional: Downloads cleanup
    if ($IncludeDownloads) {
        Clear-OldDownloads -DaysOld $DownloadsDaysOld
    }
    
    # Optional: Recycle Bin
    if ($IncludeRecycleBin) {
        Clear-RecycleBin
    }
    
    Stop-Section
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-UserTempFiles, Clear-OldDownloads, Clear-RecycleBin, etc.
