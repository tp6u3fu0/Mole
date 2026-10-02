# Mole - Safe File Operations Module
# Provides safe file deletion and manipulation functions with protection checks

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_FILEOPS_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_FILEOPS_LOADED) { return }
$script:MOLE_FILEOPS_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\base.ps1"
. "$scriptDir\log.ps1"

# ============================================================================
# Global State
# ============================================================================

$script:MoleDryRunMode = $env:MOLE_DRY_RUN -eq "1"
$script:TotalSizeCleaned = 0
$script:FilesCleaned = 0
$script:TotalItems = 0

# ============================================================================
# Safety Validation Functions
# ============================================================================

function Test-SafePath {
    <#
    .SYNOPSIS
        Validate that a path is safe to operate on
    .DESCRIPTION
        Checks against protected paths and whitelist
    .OUTPUTS
        $true if safe, $false if protected
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowUserData
    )

    # Must have a path
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Debug "Empty path rejected"
        return $false
    }

    # Resolve to full path
    $fullPath = Resolve-SafePath -Path $Path
    if (-not $fullPath) {
        Write-Debug "Could not resolve path: $Path"
        return $false
    }

    # Check protected paths (on the raw path, so relative paths are still rejected)
    if (Test-ProtectedPath -Path $Path -AllowUserData:$AllowUserData) {
        Write-Debug "Protected path rejected: $fullPath"
        return $false
    }

    # Check whitelist
    if (Test-Whitelisted -Path $fullPath) {
        Write-Debug "Whitelisted path rejected: $fullPath"
        return $false
    }

    return $true
}

function Test-IsReparsePoint {
    <#
    .SYNOPSIS
        True for junctions, symbolic links and other reparse points
    #>
    param(
        [Parameter(Mandatory)]
        [System.IO.FileSystemInfo]$Item
    )

    return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Get-SafeFileSystemItem {
    <#
    .SYNOPSIS
        Get-Item without wildcard expansion; $null when the path is missing or unreadable
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Remove-ReparsePointLink {
    <#
    .SYNOPSIS
        Remove a junction or symbolic link itself, never the data it points to
    #>
    param(
        [Parameter(Mandatory)]
        [System.IO.FileSystemInfo]$Item
    )

    if ($Item -is [System.IO.DirectoryInfo]) {
        # Non-recursive delete removes only the link; on a real non-empty
        # directory it throws instead of descending.
        [System.IO.Directory]::Delete($Item.FullName, $false)
    }
    else {
        [System.IO.File]::Delete($Item.FullName)
    }
}

function Test-SkipRunningApp {
    <#
    .SYNOPSIS
        Report and skip an app's cache while the app is running
    .DESCRIPTION
        Deleting caches under a running app fails half-way on locked files and can
        leave the app in an inconsistent state. Returns $true when the caller should skip.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$AppName,

        [Parameter(Mandatory)]
        [string[]]$ProcessNames
    )

    $running = @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) {
        return $false
    }

    Write-MoleWarning "$AppName is running - skipped (close it and run again)"
    Set-SectionActivity
    return $true
}

function Get-PathSize {
    <#
    .SYNOPSIS
        Get the size of a file or directory in bytes
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $item = Get-SafeFileSystemItem -Path $Path
    if ($null -eq $item) {
        return 0
    }

    if ($item -is [System.IO.FileInfo]) {
        return [long]$item.Length
    }

    if (Test-IsReparsePoint -Item $item) {
        return 0
    }

    $tree = Get-SafeDirectoryTreeItems -Path $Path -SkipSafetyCheck
    return Get-TreeFileSize -Items $tree.Items
}

function Get-PathSizeKB {
    <#
    .SYNOPSIS
        Get the size of a file or directory in kilobytes
    #>
    param([string]$Path)

    $bytes = Get-PathSize -Path $Path
    return [Math]::Ceiling($bytes / 1024)
}

function Get-TreeFileSize {
    <#
    .SYNOPSIS
        Sum file sizes from an enumerated tree, excluding links
    #>
    param([object[]]$Items)

    $total = [long]0
    foreach ($item in @($Items)) {
        if ($item -is [System.IO.FileInfo] -and -not (Test-IsReparsePoint -Item $item)) {
            $total += $item.Length
        }
    }
    return $total
}

# ============================================================================
# Safe Removal Functions
# ============================================================================

function Get-SafeDirectoryTreeItems {
    <#
    .SYNOPSIS
        Enumerate and validate every child before recursive directory removal.
    .DESCRIPTION
        Walks the tree without entering junctions or directory symlinks, so the
        removal can never reach data outside the directory being cleaned.
        Link entries are returned as items; removal unlinks them.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowUserData,

        # Size calculation only needs the listing, not the protection check.
        [switch]$SkipSafetyCheck
    )

    $failed = @{
        Success = $false
        Items   = @()
    }

    try {
        $root = [System.IO.DirectoryInfo]::new($Path)
        if (-not $root.Exists) {
            return $failed
        }
    }
    catch {
        Write-Debug "Could not open directory before removal: $Path - $_"
        return $failed
    }

    $items = [System.Collections.Generic.List[System.IO.FileSystemInfo]]::new()
    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push($root)

    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        try {
            $children = $dir.GetFileSystemInfos()
        }
        catch {
            Write-Debug "Could not enumerate directory before removal: $($dir.FullName) - $_"
            return $failed
        }

        foreach ($child in $children) {
            if (-not $SkipSafetyCheck -and -not (Test-SafePath -Path $child.FullName -AllowUserData:$AllowUserData)) {
                Write-Debug "Protected/whitelisted child rejected before recursive removal: $($child.FullName)"
                return $failed
            }

            $items.Add($child)

            if ($child -is [System.IO.DirectoryInfo] -and -not (Test-IsReparsePoint -Item $child)) {
                $pending.Push($child)
            }
        }
    }

    return @{
        Success = $true
        Items   = $items.ToArray()
    }
}

function Remove-SafeDirectoryTree {
    <#
    .SYNOPSIS
        Remove a directory only after all descendants pass safety checks.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [hashtable]$ValidatedTree = $null,

        [switch]$AllowUserData
    )

    $tree = if ($null -ne $ValidatedTree) {
        $ValidatedTree
    }
    else {
        Get-SafeDirectoryTreeItems -Path $Path -AllowUserData:$AllowUserData
    }

    if (-not $tree.Success) {
        return $false
    }

    $orderedItems = @()
    if ($null -ne $tree.Items) {
        # Deepest paths first so directories are empty when their turn comes
        $orderedItems = @($tree.Items | Sort-Object { $_.FullName.Length } -Descending)
    }

    foreach ($item in $orderedItems) {
        try {
            if (Test-IsReparsePoint -Item $item) {
                Remove-ReparsePointLink -Item $item
            }
            else {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            }
            Write-Debug "Removed child item: $($item.FullName)"
        }
        catch {
            Write-Debug "Failed to remove child item: $($item.FullName) - $_"
            return $false
        }
    }

    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Write-Debug "Removed directory root: $Path"
        return $true
    }
    catch {
        Write-Debug "Failed to remove directory root: $Path - $_"
        return $false
    }
}

function Invoke-SafeRemoval {
    <#
    .SYNOPSIS
        Validate one path and (unless dry-run) remove it
    .OUTPUTS
        @{ Success; Size } - Success is $true when removed or when dry-run would remove it
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowUserData
    )

    $result = @{ Success = $false; Size = [long]0 }

    if (-not (Test-SafePath -Path $Path -AllowUserData:$AllowUserData)) {
        Write-Debug "Skipping protected/whitelisted path: $Path"
        return $result
    }

    $item = Get-SafeFileSystemItem -Path $Path
    if ($null -eq $item) {
        Write-Debug "Path does not exist: $Path"
        return $result
    }

    $isLink = Test-IsReparsePoint -Item $item
    $validatedTree = $null

    if ($isLink) {
        # A link costs no space; removing it must not touch its target.
        $size = [long]0
    }
    elseif ($item -is [System.IO.DirectoryInfo]) {
        $validatedTree = Get-SafeDirectoryTreeItems -Path $item.FullName -AllowUserData:$AllowUserData
        if (-not $validatedTree.Success) {
            return $result
        }
        $size = Get-TreeFileSize -Items $validatedTree.Items
    }
    else {
        $size = [long]$item.Length
    }

    $result.Size = $size

    if ($script:MoleDryRunMode) {
        $result.Success = $true
        return $result
    }

    try {
        if ($isLink) {
            Remove-ReparsePointLink -Item $item
        }
        elseif ($null -ne $validatedTree) {
            if (-not (Remove-SafeDirectoryTree -Path $item.FullName -ValidatedTree $validatedTree)) {
                return $result
            }
        }
        else {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
        }
        $result.Success = $true
    }
    catch {
        Write-Debug "Failed to remove $Path : $_"
    }

    return $result
}

function Remove-SafeItem {
    <#
    .SYNOPSIS
        Safely remove a file or directory with all protection checks
    .DESCRIPTION
        This is the main safe deletion function. It:
        - Validates the path is not protected
        - Checks against whitelist
        - Never follows junctions or symbolic links
        - Supports dry-run mode
        - Tracks cleanup statistics
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Description = "",

        [switch]$Force,

        [switch]$Recurse,

        # Allow paths inside personal folders (Documents, Downloads, ...) for explicit user-chosen features
        [switch]$AllowUserData
    )

    $removal = Invoke-SafeRemoval -Path $Path -AllowUserData:$AllowUserData
    if (-not $removal.Success) {
        return $false
    }

    $size = $removal.Size
    $sizeKB = [Math]::Ceiling($size / 1024)
    $sizeHuman = Format-ByteSize -Bytes $size
    $name = if ($Description) { $Description } else { Split-Path -Leaf $Path }

    # Statistics count in dry-run too, so the preview summary shows what a real run would free
    $script:TotalSizeCleaned += $sizeKB
    $script:FilesCleaned++
    $script:TotalItems++

    if ($script:MoleDryRunMode) {
        Write-DryRun "$name $($script:Colors.Yellow)($sizeHuman dry)$($script:Colors.NC)"
    }
    else {
        Write-Success "$name $($script:Colors.Green)($sizeHuman)$($script:Colors.NC)"
    }
    Set-SectionActivity

    return $true
}

function Remove-SafeItems {
    <#
    .SYNOPSIS
        Safely remove multiple items with a collective description
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths,

        [string]$Description = "Items",

        [switch]$AllowUserData
    )

    $totalSize = [long]0
    $removedCount = 0
    $failedCount = 0

    foreach ($path in $Paths) {
        if (-not (Test-SafePath -Path $path -AllowUserData:$AllowUserData)) {
            continue
        }

        if ($null -eq (Get-SafeFileSystemItem -Path $path)) {
            continue
        }

        $removal = Invoke-SafeRemoval -Path $path -AllowUserData:$AllowUserData
        if ($removal.Success) {
            $totalSize += $removal.Size
            $removedCount++
        }
        else {
            $failedCount++
        }
    }

    if ($removedCount -gt 0) {
        $sizeKB = [Math]::Ceiling($totalSize / 1024)
        $sizeHuman = Format-ByteSize -Bytes $totalSize

        $script:TotalSizeCleaned += $sizeKB
        $script:FilesCleaned += $removedCount
        $script:TotalItems++

        if ($script:MoleDryRunMode) {
            Write-DryRun "$Description $($script:Colors.Yellow)($removedCount items, $sizeHuman dry)$($script:Colors.NC)"
        }
        else {
            Write-Success "$Description $($script:Colors.Green)($removedCount items, $sizeHuman)$($script:Colors.NC)"
        }
        Set-SectionActivity
    }

    return @{
        Removed = $removedCount
        Failed  = $failedCount
        Size    = $totalSize
    }
}

# ============================================================================
# Pattern-Based Cleanup Functions
# ============================================================================

function Remove-OldFiles {
    <#
    .SYNOPSIS
        Remove files older than specified days
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$DaysOld = 7,

        [string]$Filter = "*",

        [string]$Description = "Old files",

        [switch]$AllowUserData
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Removed = 0; Size = 0 }
    }

    $cutoffDate = (Get-Date).AddDays(-$DaysOld)

    $oldFiles = Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoffDate }

    if ($oldFiles) {
        $paths = $oldFiles | ForEach-Object { $_.FullName }
        return Remove-SafeItems -Paths $paths -Description "$Description (>${DaysOld}d old)" -AllowUserData:$AllowUserData
    }

    return @{ Removed = 0; Size = 0 }
}

function Remove-EmptyDirectories {
    <#
    .SYNOPSIS
        Remove empty directories recursively
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Description = "Empty directories",

        [switch]$AllowUserData
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Removed = 0 }
    }

    $removedCount = 0
    $maxIterations = 5

    for ($i = 0; $i -lt $maxIterations; $i++) {
        # @() keeps a single empty folder an array: a lone DirectoryInfo has no
        # .Count, which Windows PowerShell 5.1 strict mode rejects.
        # Links are skipped: an "empty" junction may point at a folder that is not.
        $tree = Get-SafeDirectoryTreeItems -Path $Path -SkipSafetyCheck
        $emptyDirs = @($tree.Items | Where-Object {
                         $_ -is [System.IO.DirectoryInfo] -and
                         -not (Test-IsReparsePoint -Item $_) -and
                         @($_.GetFileSystemInfos()).Count -eq 0
                     })

        if ($emptyDirs.Count -eq 0) {
            break
        }

        $removedThisPass = 0
        foreach ($dir in $emptyDirs) {
            if (Test-SafePath -Path $dir.FullName -AllowUserData:$AllowUserData) {
                if (-not $script:MoleDryRunMode) {
                    try {
                        Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                        $removedCount++
                        $removedThisPass++
                    }
                    catch {
                        Write-Debug "Could not remove empty dir: $($dir.FullName)"
                    }
                }
                else {
                    $removedCount++
                }
            }
        }

        # Dry-run removes nothing, so another pass would only count the same folders again
        if ($script:MoleDryRunMode -or $removedThisPass -eq 0) {
            break
        }
    }

    if ($removedCount -gt 0) {
        if ($script:MoleDryRunMode) {
            Write-DryRun "$Description $($script:Colors.Yellow)($removedCount dirs dry)$($script:Colors.NC)"
        }
        else {
            Write-Success "$Description $($script:Colors.Green)($removedCount dirs)$($script:Colors.NC)"
        }
        Set-SectionActivity
    }

    return @{ Removed = $removedCount }
}

function Clear-DirectoryContents {
    <#
    .SYNOPSIS
        Clear all contents of a directory but keep the directory itself
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Description = "",

        [switch]$AllowUserData
    )

    $directory = Get-SafeFileSystemItem -Path $Path
    if ($null -eq $directory -or $directory -isnot [System.IO.DirectoryInfo]) {
        return @{ Removed = 0; Size = 0 }
    }

    # A cache folder that is itself a link points somewhere the protection
    # rules cannot vouch for; leave it alone.
    if (Test-IsReparsePoint -Item $directory) {
        Write-Debug "Skipping linked directory: $Path"
        return @{ Removed = 0; Size = 0 }
    }

    if (-not (Test-SafePath -Path $Path -AllowUserData:$AllowUserData)) {
        return @{ Removed = 0; Size = 0 }
    }

    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($items) {
        $paths = $items | ForEach-Object { $_.FullName }
        $desc = if ($Description) { $Description } else { Split-Path -Leaf $Path }
        return Remove-SafeItems -Paths $paths -Description $desc -AllowUserData:$AllowUserData
    }

    return @{ Removed = 0; Size = 0 }
}

# ============================================================================
# Statistics Functions
# ============================================================================

function Get-CleanupStats {
    <#
    .SYNOPSIS
        Get current cleanup statistics
    #>
    return @{
        TotalSizeKB   = $script:TotalSizeCleaned
        TotalSizeHuman = Format-ByteSize -Bytes ($script:TotalSizeCleaned * 1024)
        FilesCleaned  = $script:FilesCleaned
        TotalItems    = $script:TotalItems
    }
}

function Reset-CleanupStats {
    <#
    .SYNOPSIS
        Reset cleanup statistics
    #>
    $script:TotalSizeCleaned = 0
    $script:FilesCleaned = 0
    $script:TotalItems = 0
}

function Set-DryRunMode {
    <#
    .SYNOPSIS
        Enable or disable dry-run mode
    #>
    param([bool]$Enabled)
    $script:MoleDryRunMode = $Enabled
}

function Test-DryRunMode {
    <#
    .SYNOPSIS
        Check if dry-run mode is enabled
    #>
    return $script:MoleDryRunMode
}

# ============================================================================
# Exports (functions are available via dot-sourcing)
# ============================================================================
# Functions: Test-SafePath, Get-PathSize, Remove-SafeItem, etc.
