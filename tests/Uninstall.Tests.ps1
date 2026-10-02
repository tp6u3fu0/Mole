# Mole Windows - Uninstall selection regression tests

BeforeAll {
    # Load only Main so tests never scan installed apps or run an uninstaller.
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) "bin\uninstall.ps1"
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw $parseErrors[0] }
    $main = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Main"
    }, $false)
    . ([scriptblock]::Create($main.Extent.Text))

    $DebugMode = $false
    $ShowHelp = $false
    $Rescan = $false
    $script:Icons = @{ List = "-" }
    $script:TestApps = @(
        [PSCustomObject]@{ Name = "First app"; SizeHuman = "1MB" }
        [PSCustomObject]@{ Name = "Second app"; SizeHuman = "2MB" }
    )

    function Get-InstalledApplications { param([switch]$ForceRescan) }
    function Show-AppSelectionMenu { param([array]$Apps) }
    function Uninstall-SelectedApps { param([array]$Apps, [array]$AllApps) throw "Real uninstall must never run" }
    function Write-Info { param([string]$Message) }
    function Write-MoleWarning { param([string]$Message) }
}

Describe "Uninstall selection under strict mode" {
    BeforeEach {
        Mock Clear-Host {}
        Mock Write-Host {}
        Mock Write-Info {}
        Mock Write-MoleWarning {}
        Mock Get-InstalledApplications { $script:TestApps }
        Mock Show-AppSelectionMenu { $script:TestApps[0] }
        Mock Read-Host { "y" }
        Mock Uninstall-SelectedApps {}
    }

    It "Confirms and passes a single selected app to the uninstaller" {
        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Read-Host -Times 1 -Exactly
        Should -Invoke Uninstall-SelectedApps -Times 1 -Exactly -ParameterFilter {
            $Apps.Count -eq 1 -and $Apps[0].Name -eq "First app"
        }
    }

    It "Returns without confirmation when the selection is cancelled" {
        Mock Show-AppSelectionMenu { return @() }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq "No applications selected" }
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Uninstall-SelectedApps -Times 0 -Exactly
    }

    It "Preserves multiple selected apps" {
        Mock Show-AppSelectionMenu { $script:TestApps }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Uninstall-SelectedApps -Times 1 -Exactly -ParameterFilter {
            $Apps.Count -eq 2 -and $Apps[0].Name -eq "First app" -and $Apps[1].Name -eq "Second app"
        }
    }

    It "Does not uninstall when confirmation is declined" {
        Mock Read-Host { "n" }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Read-Host -Times 1 -Exactly
        Should -Invoke Uninstall-SelectedApps -Times 0 -Exactly
    }

    It "Handles a single discovered app" {
        Mock Get-InstalledApplications { $script:TestApps[0] }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Show-AppSelectionMenu -Times 1 -Exactly -ParameterFilter { $Apps.Count -eq 1 }
        Should -Invoke Uninstall-SelectedApps -Times 1 -Exactly
    }

    It "Returns without showing the menu when no apps are discovered" {
        Mock Get-InstalledApplications { return @() }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Write-MoleWarning -Times 1 -Exactly -ParameterFilter { $Message -eq "No applications found" }
        Should -Invoke Show-AppSelectionMenu -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Uninstall-SelectedApps -Times 0 -Exactly
    }
}
