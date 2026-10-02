# Mole Windows - Safety Tests
# Guards that keep cleanup away from user data: links, personal folders,
# drive roots, running applications and the confirmation prompt.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    $script:BinDir = Join-Path $script:WindowsDir "bin"

    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"

    function New-TestJunction {
        param([string]$Link, [string]$Target)
        New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
    }
}

Describe "Links are never followed" {
    BeforeEach {
        Set-DryRunMode -Enabled $false
        Reset-CleanupStats

        $script:Root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $script:Precious = Join-Path $script:Root "precious"
        $script:Cache = Join-Path $script:Root "cache"

        New-Item -ItemType Directory -Path "$script:Precious\nested" -Force | Out-Null
        Set-Content -LiteralPath "$script:Precious\important.docx" -Value "keep me"
        Set-Content -LiteralPath "$script:Precious\nested\photo.jpg" -Value "keep me too"

        New-Item -ItemType Directory -Path $script:Cache -Force | Out-Null
        Set-Content -LiteralPath "$script:Cache\junk.tmp" -Value "junk"
        New-TestJunction -Link "$script:Cache\link" -Target $script:Precious
    }

    AfterEach {
        # Unlink first so cleanup of the test drive cannot reach through it either
        $link = Join-Path $script:Cache "link"
        if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link, $false) }
    }

    It "Remove-SafeItem removes the directory and only unlinks the junction" {
        Remove-SafeItem -Path $script:Cache -Recurse | Should -Be $true

        Test-Path -LiteralPath $script:Cache | Should -Be $false
        Test-Path -LiteralPath "$script:Precious\important.docx" | Should -Be $true
        Test-Path -LiteralPath "$script:Precious\nested\photo.jpg" | Should -Be $true
    }

    It "Clear-DirectoryContents unlinks a junction child without touching its target" {
        $null = Clear-DirectoryContents -Path $script:Cache -Description "test cache"

        Test-Path -LiteralPath $script:Cache | Should -Be $true
        Test-Path -LiteralPath "$script:Cache\junk.tmp" | Should -Be $false
        Test-Path -LiteralPath "$script:Cache\link" | Should -Be $false
        Test-Path -LiteralPath "$script:Precious\important.docx" | Should -Be $true
    }

    It "Clear-DirectoryContents skips a cache folder that is itself a junction" {
        $linkedCache = Join-Path $script:Root "linked-cache"
        New-TestJunction -Link $linkedCache -Target $script:Precious

        try {
            $result = Clear-DirectoryContents -Path $linkedCache -Description "linked"
            $result.Removed | Should -Be 0
            Test-Path -LiteralPath "$script:Precious\important.docx" | Should -Be $true
            Test-Path -LiteralPath "$script:Precious\nested\photo.jpg" | Should -Be $true
        }
        finally {
            [System.IO.Directory]::Delete($linkedCache, $false)
        }
    }

    It "Remove-SafeItem on a junction removes only the link" {
        Remove-SafeItem -Path "$script:Cache\link" | Should -Be $true

        Test-Path -LiteralPath "$script:Cache\link" | Should -Be $false
        Test-Path -LiteralPath "$script:Precious\important.docx" | Should -Be $true
    }

    It "Get-PathSize does not count data behind a junction" {
        $junkSize = (Get-Item -LiteralPath "$script:Cache\junk.tmp").Length
        Get-PathSize -Path $script:Cache | Should -Be $junkSize
    }

    It "Remove-EmptyDirectories does not remove a junction to an empty folder" {
        $emptyTarget = Join-Path $script:Root "empty-target"
        New-Item -ItemType Directory -Path $emptyTarget | Out-Null
        New-TestJunction -Link "$script:Cache\empty-link" -Target $emptyTarget

        try {
            $null = Remove-EmptyDirectories -Path $script:Cache
            Test-Path -LiteralPath "$script:Cache\empty-link" | Should -Be $true
            Test-Path -LiteralPath $emptyTarget | Should -Be $true
        }
        finally {
            [System.IO.Directory]::Delete("$script:Cache\empty-link", $false)
        }
    }
}

Describe "Protected locations" {
    Context "Drive roots" {
        It "Should protect drive roots" {
            Test-ProtectedPath -Path "C:\" | Should -Be $true
            Test-ProtectedPath -Path "D:\" | Should -Be $true
            Test-ProtectedPath -Path "D:" | Should -Be $true
        }

        It "Should reject relative and drive-relative paths" {
            Test-ProtectedPath -Path "Cache" | Should -Be $true
            Test-ProtectedPath -Path ".\Cache" | Should -Be $true
            Test-ProtectedPath -Path "D:Cache" | Should -Be $true
            Test-ProtectedPath -Path "\Temp\Cache" | Should -Be $true
            Test-SafePath -Path "Cache" | Should -Be $false
        }

        It "Should protect UNC share roots" {
            Test-ProtectedPath -Path "\\server\share" | Should -Be $true
        }

        It "Should protect the AppData roots themselves" {
            Test-ProtectedPath -Path $env:LOCALAPPDATA | Should -Be $true
            Test-ProtectedPath -Path $env:APPDATA | Should -Be $true
            Test-ProtectedPath -Path "$env:LOCALAPPDATA\SomeApp\Cache" | Should -Be $false
        }
    }

    Context "Personal folders" {
        BeforeAll {
            $script:OriginalUserDataPaths = $script:UserDataPaths
        }

        AfterAll {
            $script:UserDataPaths = $script:OriginalUserDataPaths
        }

        BeforeEach {
            Set-DryRunMode -Enabled $false
            $script:FakeDocuments = Join-Path $TestDrive ("Documents-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path "$script:FakeDocuments\project\node_modules" -Force | Out-Null
            Set-Content -LiteralPath "$script:FakeDocuments\report.docx" -Value "keep"
            Set-Content -LiteralPath "$script:FakeDocuments\project\node_modules\dep.js" -Value "x"
            $script:UserDataPaths = @($script:FakeDocuments)
        }

        It "Should detect the real personal folders" {
            $detected = @(Get-MoleUserDataPaths)
            $documents = [Environment]::GetFolderPath('MyDocuments')
            if ($documents) {
                $detected | Should -Contain ([System.IO.Path]::GetFullPath($documents).TrimEnd('\'))
            }
            $detected | Should -Not -Contain ([System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'))
        }

        It "Should block anything inside a personal folder by default" {
            Test-SafePath -Path "$script:FakeDocuments\report.docx" | Should -Be $false
            Remove-SafeItem -Path "$script:FakeDocuments\report.docx" | Should -Be $false
            Test-Path -LiteralPath "$script:FakeDocuments\report.docx" | Should -Be $true
        }

        It "Should block clearing a cache-looking folder inside a personal folder" {
            $result = Clear-DirectoryContents -Path "$script:FakeDocuments\project\node_modules"
            $result.Removed | Should -Be 0
            Test-Path -LiteralPath "$script:FakeDocuments\project\node_modules\dep.js" | Should -Be $true
        }

        It "Should allow explicit opt-in features inside a personal folder" {
            Remove-SafeItem -Path "$script:FakeDocuments\project\node_modules" -Recurse -AllowUserData | Should -Be $true
            Test-Path -LiteralPath "$script:FakeDocuments\project\node_modules" | Should -Be $false
            Test-Path -LiteralPath "$script:FakeDocuments\report.docx" | Should -Be $true
        }

        It "Should never remove the personal folder itself, even with opt-in" {
            Test-ProtectedPath -Path $script:FakeDocuments -AllowUserData | Should -Be $true
            Remove-SafeItem -Path $script:FakeDocuments -Recurse -AllowUserData | Should -Be $false
            Test-Path -LiteralPath $script:FakeDocuments | Should -Be $true
        }
    }
}

Describe "Literal path handling" {
    BeforeEach {
        Set-DryRunMode -Enabled $false
        $script:Dir = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
    }

    It "Should remove a file whose name contains wildcard brackets" {
        $file = Join-Path $script:Dir "log[1].txt"
        $sibling = Join-Path $script:Dir "log1.txt"
        [System.IO.File]::WriteAllText($file, "a")
        [System.IO.File]::WriteAllText($sibling, "b")

        Remove-SafeItem -Path $file | Should -Be $true
        [System.IO.File]::Exists($file) | Should -Be $false
        [System.IO.File]::Exists($sibling) | Should -Be $true
    }
}

Describe "Dry-run statistics" {
    It "Should count what a real run would free" {
        $dir = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir "a.bin"), (New-Object byte[] 4096))

        Reset-CleanupStats
        Set-DryRunMode -Enabled $true
        try {
            $null = Clear-DirectoryContents -Path $dir -Description "dry"
        }
        finally {
            Set-DryRunMode -Enabled $false
        }

        (Get-CleanupStats).TotalSizeKB | Should -Be 4
        Test-Path -LiteralPath (Join-Path $dir "a.bin") | Should -Be $true
    }
}

Describe "Running applications" {
    It "Should skip when the app is running" {
        $self = (Get-Process -Id $PID).ProcessName
        Test-SkipRunningApp -AppName "Self" -ProcessNames $self | Should -Be $true
    }

    It "Should not skip when the app is not running" {
        Test-SkipRunningApp -AppName "Nothing" -ProcessNames "mole-no-such-process-$([Guid]::NewGuid().ToString('N'))" | Should -Be $false
    }
}

Describe "Clean confirmation" {
    It "Should mention --yes in help" {
        $result = & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:BinDir\clean.ps1" -ShowHelp 2>&1
        $result -join "`n" | Should -Match "--yes"
    }

    It "Should not start deleting without confirmation" {
        # Piped stdin: either refused as non-interactive, or the "n" answers the prompt.
        # Both paths stop before any cleanup module runs.
        $output = "n" | & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:BinDir\clean.ps1" 2>&1 | Out-String

        $output | Should -Match "(No interactive console|Nothing was deleted)"
        $output | Should -Not -Match "User essentials"
    }
}

Describe "Cleanup output" {
    It "Should not leak return values from cleanup calls to the console" {
        # A bare call prints its result hashtable (Size/Removed/Failed) between progress lines
        $pattern = '^\s*(Clear-DirectoryContents|Remove-SafeItems?|Remove-OldFiles|Remove-EmptyDirectories)\b'
        $files = Get-ChildItem -Path "$script:LibDir\clean", $script:BinDir -Filter *.ps1
        $bare = @($files | Select-String -Pattern $pattern | ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
        $bare | Should -BeNullOrEmpty
    }
}

Describe "Error report cleanup" {
    BeforeAll {
        . "$script:LibDir\clean\user.ps1"
    }

    BeforeEach {
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $script:SavedUserProfile = $env:USERPROFILE

        $fake = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $env:LOCALAPPDATA = Join-Path $fake "Local"
        $env:USERPROFILE = Join-Path $fake "Profile"

        $archive = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER\ReportArchive\AppCrash_1"
        $crashDumps = Join-Path $env:LOCALAPPDATA "CrashDumps"
        New-Item -ItemType Directory -Path $archive, $crashDumps, $env:USERPROFILE -Force | Out-Null

        $old = (Get-Date).AddDays(-30)
        foreach ($file in @("$archive\Report.wer", "$crashDumps\app.exe.1234.dmp", "$env:USERPROFILE\old.dmp")) {
            [System.IO.File]::WriteAllBytes($file, (New-Object byte[] 1024))
            (Get-Item -LiteralPath $file).LastWriteTime = $old
        }
        [System.IO.File]::WriteAllBytes("$crashDumps\fresh.dmp", (New-Object byte[] 1024))

        Reset-CleanupStats
        Set-DryRunMode -Enabled $true
    }

    AfterEach {
        Set-DryRunMode -Enabled $false
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:USERPROFILE = $script:SavedUserProfile
    }

    It "Should count each old file once and leave recent reports" {
        $output = @(Clear-ErrorReports -DaysOld 7)

        $output | Should -BeNullOrEmpty
        $stats = Get-CleanupStats
        $stats.FilesCleaned | Should -Be 3
        $stats.TotalSizeKB | Should -Be 3
    }
}
