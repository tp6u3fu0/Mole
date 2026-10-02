# Mole Windows - Command Safety Tests
# purge, uninstall and optimize must not touch source code, shared folders,
# or system settings the user did not ask for.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    $script:BinDir = Join-Path $script:WindowsDir "bin"

    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"

    # Returns the source of selected functions and top-level $script: assignments,
    # so a command's helpers load without running its Main.
    function Get-ScriptDefinitions {
        param(
            [string]$Path,
            [string[]]$FunctionNames
        )

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw $parseErrors[0] }

        $parts = @()
        foreach ($statement in $ast.EndBlock.Statements) {
            if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $statement.Left.Extent.Text -like '$script:*') {
                $parts += $statement.Extent.Text
            }
        }
        foreach ($name in $FunctionNames) {
            $function = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            if (-not $function) { throw "Function not found: $name" }
            $parts += $function.Extent.Text
        }
        return ($parts -join "`n`n")
    }

    $purgeSource = Get-ScriptDefinitions -Path "$script:BinDir\purge.ps1" -FunctionNames @(
        'Find-ProjectArtifacts', 'Test-ProjectHasMarker', 'Test-GitTracksPath', 'Test-InsideNonProjectDirectory'
    )
    . ([scriptblock]::Create($purgeSource))

    $uninstallSource = Get-ScriptDefinitions -Path "$script:BinDir\uninstall.ps1" -FunctionNames @(
        'Split-UninstallCommand', 'Get-AppProperty', 'Test-AppStillInstalled', 'Wait-AppRemoved',
        'Invoke-AppUninstaller', 'Test-PathInside', 'Get-LeftoverFolder', 'Uninstall-SelectedApps'
    )
    . ([scriptblock]::Create($uninstallSource))

    function New-TestProject {
        param([string]$Name, [string[]]$Files)
        $root = Join-Path $TestDrive ("$Name-" + [Guid]::NewGuid().ToString('N'))
        foreach ($file in $Files) {
            $full = Join-Path $root $file
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            Set-Content -LiteralPath $full -Value "x"
        }
        return $root
    }
}

Describe "Purge artifact detection" {
    It "Should not treat a tracked bin folder of source scripts as build output" {
        # Same shape as this repository: go.mod plus bin\*.ps1 under git
        $project = New-TestProject -Name "scripts" -Files @("go.mod", "bin\clean.ps1", "bin\purge.ps1")
        & git -C $project init -q 2>$null
        & git -C $project add . 2>$null

        @(Find-ProjectArtifacts -ProjectPath $project) | Should -BeNullOrEmpty
    }

    It "Should find bin and obj only in .NET projects" {
        $dotnet = New-TestProject -Name "dotnet" -Files @("App.csproj", "bin\Debug\App.dll", "obj\project.assets.json")
        $node = New-TestProject -Name "node" -Files @("package.json", "bin\cli.js")

        @(Find-ProjectArtifacts -ProjectPath $dotnet).Name | Sort-Object | Should -Be @("bin", "obj")
        @(Find-ProjectArtifacts -ProjectPath $node) | Should -BeNullOrEmpty
    }

    It "Should skip git-tracked output but still offer untracked dependencies" {
        $project = New-TestProject -Name "web" -Files @("package.json", "dist\app.js", "node_modules\dep\index.js")
        Set-Content -LiteralPath (Join-Path $project ".gitignore") -Value "node_modules/"
        & git -C $project init -q 2>$null
        & git -C $project add . 2>$null

        @(Find-ProjectArtifacts -ProjectPath $project).Name | Should -Be @("node_modules")
    }

    It "Should not treat Go's committed vendor folder as PHP dependencies" {
        $project = New-TestProject -Name "go" -Files @("go.mod", "vendor\modules.txt")
        @(Find-ProjectArtifacts -ProjectPath $project) | Should -BeNullOrEmpty
    }

    It "Should never offer IDE settings" {
        $project = New-TestProject -Name "ide" -Files @("pom.xml", ".idea\workspace.xml", "target\app.jar")
        $names = @(Find-ProjectArtifacts -ProjectPath $project).Name
        $names | Should -Contain "target"
        $names | Should -Not -Contain ".idea"
    }

    It "Should ignore project markers inside dependency and output folders" {
        Test-InsideNonProjectDirectory -Path "C:\src\app\node_modules\left-pad" -SearchRoot "C:\src" | Should -Be $true
        Test-InsideNonProjectDirectory -Path "C:\src\api\.venv\Lib\site-packages\pkg" -SearchRoot "C:\src" | Should -Be $true
        Test-InsideNonProjectDirectory -Path "C:\src\app" -SearchRoot "C:\src" | Should -Be $false
    }
}

Describe "Uninstall command parsing" {
    It "Should split a quoted executable from its arguments" {
        $command = Split-UninstallCommand -CommandLine '"C:\Program Files\App\unins000.exe" /LOG'
        $command.FilePath | Should -Be 'C:\Program Files\App\unins000.exe'
        $command.Arguments | Should -Be '/LOG'
    }

    It "Should split an unquoted path containing spaces" {
        $command = Split-UninstallCommand -CommandLine 'C:\Program Files\App\uninstall.exe --remove'
        $command.FilePath | Should -Be 'C:\Program Files\App\uninstall.exe'
        $command.Arguments | Should -Be '--remove'
    }

    It "Should keep shell metacharacters as plain arguments" {
        $command = Split-UninstallCommand -CommandLine '"C:\App\u.exe" & calc.exe'
        $command.FilePath | Should -Be 'C:\App\u.exe'
        $command.Arguments | Should -Be '& calc.exe'
    }

    It "Should reject an empty command" {
        Split-UninstallCommand -CommandLine "" | Should -BeNullOrEmpty
    }
}

Describe "Uninstall verification" {
    It "Should report removed when the registry entry is gone" {
        $app = [PSCustomObject]@{ Name = "Gone"; Source = "Registry"; RegistryKey = "HKCU:\Software\Mole-Test-$([Guid]::NewGuid().ToString('N'))" }
        Test-AppStillInstalled -App $app | Should -Be $false
    }

    It "Should treat an app it cannot check as still installed" {
        # Entries cached by an older version have no RegistryKey
        $app = [PSCustomObject]@{ Name = "Old cache entry"; Source = "Registry" }
        Test-AppStillInstalled -App $app | Should -Be $true
    }
}

Describe "Uninstall leftover folders" {
    BeforeEach {
        $script:Folder = Join-Path $TestDrive ("App-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Folder | Out-Null
    }

    It "Should offer a folder that belongs only to the removed app" {
        $app = [PSCustomObject]@{ Name = "App"; InstallLocation = $script:Folder }
        (Get-LeftoverFolder -App $app -OtherApps @()).Path | Should -Be $script:Folder
    }

    It "Should keep a folder that another installed app lives in" {
        $app = [PSCustomObject]@{ Name = "Suite"; InstallLocation = $script:Folder }
        $other = [PSCustomObject]@{ Name = "Other tool"; InstallLocation = (Join-Path $script:Folder "Other") }

        $result = Get-LeftoverFolder -App $app -OtherApps @($other)
        $result.Path | Should -BeNullOrEmpty
        $result.Reason | Should -Match "Other tool"
    }

    It "Should keep a folder inside another app's folder" {
        $app = [PSCustomObject]@{ Name = "Plugin"; InstallLocation = (Join-Path $script:Folder "plugin") }
        New-Item -ItemType Directory -Path $app.InstallLocation | Out-Null
        $host_ = [PSCustomObject]@{ Name = "Host app"; InstallLocation = $script:Folder }

        (Get-LeftoverFolder -App $app -OtherApps @($host_)).Path | Should -BeNullOrEmpty
    }

    It "Should keep protected locations" {
        $app = [PSCustomObject]@{ Name = "Root"; InstallLocation = "$env:SystemDrive\" }
        (Get-LeftoverFolder -App $app -OtherApps @()).Path | Should -BeNullOrEmpty
    }
}

Describe "Uninstall flow" {
    BeforeEach {
        $script:Folder = Join-Path $TestDrive ("App-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Folder | Out-Null
        $script:App = [PSCustomObject]@{ Name = "App"; Source = "Registry"; InstallLocation = $script:Folder }

        Mock Write-Host {}
        Mock Write-Info {}
        Mock Invoke-AppUninstaller {}
        Mock Remove-SafeItem { $true }
    }

    It "Should keep files when the uninstall is not confirmed" {
        Mock Wait-AppRemoved { $false }
        Mock Read-Confirmation { $true }

        Uninstall-SelectedApps -Apps @($script:App) -AllApps @($script:App)

        Should -Invoke Read-Confirmation -Times 0 -Exactly
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
    }

    It "Should ask before deleting leftover folders and respect No" {
        Mock Wait-AppRemoved { $true }
        Mock Read-Confirmation { $false }

        Uninstall-SelectedApps -Apps @($script:App) -AllApps @($script:App)

        Should -Invoke Read-Confirmation -Times 1 -Exactly
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
    }

    It "Should delete the leftover folder after Yes" {
        Mock Wait-AppRemoved { $true }
        Mock Read-Confirmation { $true }

        Uninstall-SelectedApps -Apps @($script:App) -AllApps @($script:App)

        Should -Invoke Remove-SafeItem -Times 1 -Exactly -ParameterFilter { $Path -eq $script:Folder }
    }
}

Describe "Optimize defaults" {
    It "Should document the opt-in repairs" {
        $result = & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:BinDir\optimize.ps1" -ShowHelp 2>&1
        $text = $result -join "`n"
        $text | Should -Match "--repair"
        $text | Should -Match "--reset-network"
        $text | Should -Not -Match '^\s*"\s*$'
    }

    It "Should not change anything without confirmation" {
        # Piped stdin: refused as non-interactive, or "n" answers the prompt
        $output = "n" | & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:BinDir\optimize.ps1" 2>&1 | Out-String

        $output | Should -Match "(No interactive console|Nothing was changed)"
        $output | Should -Not -Match "DNS Cache"
    }

    It "Should run repairs and the Winsock reset only behind their opt-in switches" {
        # Structural check: a dry run takes minutes because of the health checks
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile("$script:BinDir\optimize.ps1", [ref]$tokens, [ref]$parseErrors)

        function Get-GuardConditions {
            param($Node)
            $conditions = @()
            $current = $Node.Parent
            while ($current) {
                if ($current -is [System.Management.Automation.Language.IfStatementAst]) {
                    $conditions += ($current.Clauses | ForEach-Object { $_.Item1.Extent.Text }) -join " "
                }
                $current = $current.Parent
            }
            return $conditions -join " "
        }

        $repairCalls = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -like 'Repair-*'
        }, $true))
        $repairCalls.Count | Should -BeGreaterThan 0
        foreach ($call in $repairCalls) {
            Get-GuardConditions -Node $call | Should -Match '\$Repair\b'
        }

        $winsockCalls = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'netsh' -and $node.Extent.Text -match 'winsock'
        }, $true))
        $winsockCalls.Count | Should -Be 1
        Get-GuardConditions -Node $winsockCalls[0] | Should -Match 'ResetNetwork'
    }
}
