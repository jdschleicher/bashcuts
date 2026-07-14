# ============================================================================
# Jidoka guard — no assignment to read-only automatic variables
# ============================================================================
# PowerShell variable names are case-insensitive, so a descriptive local like
# $isWindows silently aliases the built-in read-only $IsWindows automatic
# variable. Assigning to it throws "Cannot overwrite variable ... because it is
# read-only or constant" the moment the function runs (issue #182).
#
# This Pester spec parses every committed PowerShell file via the AST and fails
# if any assignment targets a read-only / constant automatic variable, so the
# regression cannot silently reappear in any file. $null is intentionally
# excluded: `$null = <expr>` is the sanctioned discard idiom and never throws.
#
# This is an opt-in developer check, not a profile-load gate. Run it ad hoc:
#   t-run-file   (defined in powcuts_by_cli/pester.ps1) -> point it at this file
#   or:  Invoke-Pester -Output Detailed <path-to-this-file>

Describe 'Read-only automatic variables' {

    BeforeAll {
        # Automatic variables that are ReadOnly or Constant — assigning to any of
        # them throws at runtime. $null is deliberately absent ($null = ... is a
        # legal discard). Matched case-insensitively via -contains below, so the
        # exact-casing footgun ($isWindows vs $IsWindows) is still caught.
        $script:ReadOnlyAutomaticVariables = @(
            'true'
            'false'
            'IsWindows'
            'IsLinux'
            'IsMacOS'
            'IsCoreCLR'
            'PID'
            'Host'
            'Home'
            'PSHome'
            'PSVersionTable'
            'PSEdition'
            'PSCulture'
            'PSUICulture'
            'ExecutionContext'
            'ShellId'
        )

        function Get-AssignmentTargetName {
            # Unwrap an optional [type] cast and return the bare variable name
            # (scope prefix stripped), or $null when the target isn't a plain
            # variable: a property ($obj.Prop), an index ($arr[0]), or a
            # drive-qualified variable ($env:HOME, $function:foo) whose
            # assignment is legal and must never be flagged.
            param(
                [Parameter(Mandatory)] $LeftAst
            )

            $target = $LeftAst

            if ($target -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                $target = $target.Child
            }

            if ($target -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                return $null
            }

            # $env:HOME / $function:foo parse as variables, but assigning them is
            # legal; skip drive-qualified paths so an env var whose name collides
            # with a read-only automatic (e.g. $env:Host) isn't a false positive.
            if ($target.VariablePath.IsDriveQualified) {
                return $null
            }

            $userPath = $target.VariablePath.UserPath
            $leaf = ($userPath -split ':')[-1]
            return $leaf
        }


        function Get-ReadOnlyAssignment {
            # Parse one file and return readable offense strings for every
            # assignment whose target is a read-only automatic variable.
            param(
                [Parameter(Mandatory)] [string] $Path
            )

            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

            $isAssignment = {
                param($node)
                $result = $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                return $result
            }

            $assignments = $ast.FindAll($isAssignment, $true)

            $offenses = New-Object System.Collections.Generic.List[string]

            foreach ($assignment in $assignments) {
                $name = Get-AssignmentTargetName -LeftAst $assignment.Left

                if ($null -eq $name) {
                    continue
                }

                if ($script:ReadOnlyAutomaticVariables -contains $name) {
                    $line = $assignment.Extent.StartLineNumber
                    $offenses.Add("line ${line}: `$$name")
                }
            }

            return ,$offenses
        }

        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    }

    It 'no committed PowerShell file assigns to a read-only automatic variable' {
        $files = New-Object System.Collections.Generic.List[object]

        Get-ChildItem -Path (Join-Path $script:RepoRoot 'powcuts_by_cli') -Filter '*.ps1' -File |
            ForEach-Object { $files.Add($_) }

        $homeEntry = Get-Item -Path (Join-Path $script:RepoRoot 'powcuts_home.ps1')
        $files.Add($homeEntry)

        $allOffenses = New-Object System.Collections.Generic.List[string]

        foreach ($file in $files) {
            $offenses = Get-ReadOnlyAssignment -Path $file.FullName

            foreach ($offense in $offenses) {
                $allOffenses.Add("$($file.Name) $offense")
            }
        }

        $allOffenses |
            Should -BeNullOrEmpty -Because "assigning to a read-only automatic variable throws at runtime (issue #182). Offenders: $($allOffenses -join '; ')"
    }
}
