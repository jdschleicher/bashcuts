# ============================================================================
# Azure DevOps — Field-schema cache
# ============================================================================
# Per-org work-item-type field schema cached at
# ~/.bashcuts-az-devops-app/schema/schema-<orgslug>.json. Public functions:
# az-Get-AzDevOpsSchema (read), az-Edit-AzDevOpsSchema (open in editor),
# az-Initialize-AzDevOpsSchema (introspect via `az boards work-item type show`),
# az-Test-AzDevOpsSchema (validate cached schema against live org).
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

# ---------------------------------------------------------------------------
# Local field-schema config
#
# Schema directory: $HOME/.bashcuts-az-devops-app/schema/   (separate from the
#                   auto-managed cache/ subtree under the same parent)
# Schema file:      schema-<orgslug>.json                   (per-org keyed off
#                   the configured organization URL; falls back to schema.json when unset)
#
# Public functions:
#   az-Get-AzDevOpsSchema          - print summary table of the configured
#                                  required/optional/custom fields per
#                                  work-item type. -PassThru returns objects.
#   az-Edit-AzDevOpsSchema         - open the schema file in $env:EDITOR /
#                                  code / notepad / nano. Creates a stub
#                                  if the file does not exist.
#   az-Initialize-AzDevOpsSchema   - introspect the org via
#                                  `az devops invoke --area wit --resource
#                                  workitemtypes` and write a starter schema.
#                                  User refines afterward via az-Edit-AzDevOpsSchema.
#   az-Test-AzDevOpsSchema         - validate JSON parses, every ref still
#                                  exists in the org, and picklist options
#                                  are a subset of allowedValues. Verdict:
#                                  VALID / STALE / INVALID.
#
# Internal integration point (consumed by future schema-aware updates to
# az-New-AzDevOpsUserStory, az-Get-AzDevOpsAssigned, az-Show-AzDevOpsTree, etc.):
#   Get-AzDevOpsSchemaForType   - returns the parsed schema entry for one
#                                  work-item type, or $null if no schema
#                                  is configured / type not present.
# ---------------------------------------------------------------------------

function Get-AzDevOpsSchemaValidTypes {
    return @('string', 'int', 'picklist', 'bool', 'date', 'multiline')
}


function Get-AzDevOpsSchemaWorkItemTypes {
    # Standard process-template work-item types az-Initialize-AzDevOpsSchema
    # introspects. Types not present in the org's process are skipped with
    # a warning rather than failing the whole introspection.
    return @('Epic', 'Feature', 'User Story', 'Bug', 'Task')
}


function Get-AzDevOpsSchemaSystemRefs {
    # Reference names that ship with every Azure DevOps process template
    # (Agile / Scrum / CMMI). az-Initialize-AzDevOpsSchema filters these out
    # so the produced schema only carries org-specific fields.
    return @(
        'System.Id', 'System.Title', 'System.Description', 'System.State',
        'System.Reason', 'System.AssignedTo', 'System.AreaPath',
        'System.IterationPath', 'System.WorkItemType', 'System.History',
        'System.Tags', 'System.CreatedBy', 'System.CreatedDate',
        'System.ChangedBy', 'System.ChangedDate', 'System.Parent',
        'System.Rev', 'System.AuthorizedDate', 'System.RevisedDate',
        'System.AuthorizedAs', 'System.IterationId', 'System.AreaId',
        'System.NodeName', 'System.TeamProject', 'System.BoardColumn',
        'System.BoardColumnDone', 'System.BoardLane', 'System.CommentCount',
        'System.PersonId', 'System.Watermark',
        'Microsoft.VSTS.Common.Priority',
        'Microsoft.VSTS.Common.AcceptanceCriteria',
        'Microsoft.VSTS.Scheduling.StoryPoints',
        'Microsoft.VSTS.Common.ActivatedBy',
        'Microsoft.VSTS.Common.ActivatedDate',
        'Microsoft.VSTS.Common.ResolvedBy',
        'Microsoft.VSTS.Common.ResolvedDate',
        'Microsoft.VSTS.Common.ResolvedReason',
        'Microsoft.VSTS.Common.ClosedBy',
        'Microsoft.VSTS.Common.ClosedDate',
        'Microsoft.VSTS.Common.StateChangeDate',
        'Microsoft.VSTS.Common.Risk',
        'Microsoft.VSTS.Common.Severity',
        'Microsoft.VSTS.Common.StackRank',
        'Microsoft.VSTS.Common.ValueArea',
        'Microsoft.VSTS.Common.BusinessValue',
        'Microsoft.VSTS.Common.TimeCriticality',
        'Microsoft.VSTS.Scheduling.Effort',
        'Microsoft.VSTS.Scheduling.RemainingWork',
        'Microsoft.VSTS.Scheduling.OriginalEstimate',
        'Microsoft.VSTS.Scheduling.CompletedWork',
        'Microsoft.VSTS.Scheduling.StartDate',
        'Microsoft.VSTS.Scheduling.TargetDate'
    )
}


function Get-AzDevOpsSchemaOrgSlug {
    # Per-org keying: the path-tail segment of the configured organization URL,
    # lowercased and reduced to [a-z0-9-]. Returns $null when org is not
    # configured, so Get-AzDevOpsSchemaPaths falls back to unsuffixed schema.json.
    $defaults = Get-AzDevOpsConfiguredDefaults
    if (-not $defaults.Org) {
        return $null
    }

    $segment = ($defaults.Org.TrimEnd('/') -split '/')[-1]
    if (-not $segment) {
        return $null
    }

    $slug = ($segment.ToLower() -replace '[^a-z0-9-]', '-').Trim('-')
    if (-not $slug) {
        return $null
    }

    return $slug
}


function Get-AzDevOpsSchemaPaths {
    $configDir = Join-Path (Get-AzDevOpsAppRoot) 'schema'
    $slug = Get-AzDevOpsSchemaOrgSlug

    $fileName = if ($slug) {
        "schema-$slug.json"
    }
    else {
        'schema.json'
    }

    return [PSCustomObject]@{
        Dir  = $configDir
        File = Join-Path $configDir $fileName
        Slug = $slug
    }
}


function Initialize-AzDevOpsSchemaDir {
    # Creates $HOME/.bashcuts-az-devops-app/schema with 0700 on Unix. Windows
    # gets default NTFS ACLs inherited from %USERPROFILE%, which are user-only
    # for files created under $HOME.
    $paths = Get-AzDevOpsSchemaPaths

    if (-not (Test-Path -LiteralPath $paths.Dir)) {
        New-Item -ItemType Directory -Path $paths.Dir -Force | Out-Null
    }

    if ((Get-AzDevOpsPlatform) -eq 'Posix') {
        & chmod 700 $paths.Dir 2>$null
    }

    return $paths
}


function Write-AzDevOpsSchemaFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Schema
    )

    $json = $Schema | ConvertTo-Json -Depth 6
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}


function Read-AzDevOpsSchemaFile {
    # Returns the parsed schema object, or $null when the file is missing
    # or unparseable. Used by az-Get-AzDevOpsSchema, Get-AzDevOpsSchemaForType,
    # and az-Test-AzDevOpsSchema.
    $paths = Get-AzDevOpsSchemaPaths
    if (-not (Test-Path -LiteralPath $paths.File)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $paths.File -Raw
        $schema = $raw | ConvertFrom-Json
        return $schema
    }
    catch {
        Write-Host "Could not parse schema at $($paths.File): $_" -ForegroundColor Red
        return $null
    }
}


function Get-AzDevOpsSchemaForType {
    # Internal integration point for schema-aware consumers (az-New-AzDevOpsUserStory,
    # the read commands, the tree). Returns the parsed { required = ..., optional = ... }
    # entry for one work-item type, or $null when no schema is configured / the
    # type is not present.
    param([Parameter(Mandatory)] [string] $Type)

    $schema = Read-AzDevOpsSchemaFile
    if ($null -eq $schema) {
        return $null
    }

    $prop = $schema.PSObject.Properties[$Type]
    if ($null -eq $prop) {
        return $null
    }

    $entry = $prop.Value
    return $entry
}


function New-AzDevOpsSchemaStub {
    # Empty starter schema used by az-Edit-AzDevOpsSchema when no file exists
    # yet and the user just wants to hand-edit one in. az-Initialize-AzDevOpsSchema
    # produces a richer file by introspecting the org.
    return [ordered]@{
        'User Story' = [ordered]@{
            required = @()
            optional = @()
        }

        'Feature'    = [ordered]@{
            required = @()
            optional = @()
        }

        'Bug'        = [ordered]@{
            required = @()
            optional = @()
        }
    }
}


function ConvertFrom-AzDevOpsSchemaToRows {
    # Flattens the nested schema into one PSCustomObject per field, suitable
    # for a Format-Table summary or PassThru consumption.
    param([Parameter(Mandatory)] $Schema)

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]

    foreach ($prop in $Schema.PSObject.Properties) {
        $wiType = $prop.Name
        $entry = $prop.Value

        foreach ($section in @('required', 'optional')) {
            $sectionList = $entry.$section
            if (-not $sectionList) { continue }

            foreach ($f in $sectionList) {
                $optionsText = if ($f.type -eq 'picklist' -and $f.options) {
                    ($f.options -join ', ')
                }
                else {
                    ''
                }

                $row = [PSCustomObject]@{
                    WorkItemType = $wiType
                    Field        = $f.name
                    Ref          = $f.ref
                    Required     = ($section -eq 'required')
                    FieldType    = $f.type
                    Options      = $optionsText
                }
                $rows.Add($row)
            }
        }
    }

    $result = , @($rows)
    return $result
}


function az-Get-AzDevOpsSchema {
    [CmdletBinding()]
    param([switch] $PassThru)

    $schema = Read-AzDevOpsSchemaFile
    if ($null -eq $schema) {
        $paths = Get-AzDevOpsSchemaPaths
        Write-Host "No schema configured at $($paths.File)." -ForegroundColor Yellow
        Write-Host "  Run: az-Initialize-AzDevOpsSchema   # populate from your org's work-item types" -ForegroundColor Yellow
        Write-Host "  Or:  az-Edit-AzDevOpsSchema         # create + hand-edit a stub" -ForegroundColor Yellow
        return
    }

    $rows = ConvertFrom-AzDevOpsSchemaToRows -Schema $schema

    if ($PassThru) {
        return $rows
    }

    Show-AzDevOpsRows -Rows $rows -Title "Azure DevOps schema - $(@($rows).Count) fields"
}


function Resolve-AzDevOpsEditor {
    # Editor fallback chain: $env:EDITOR -> `code` (when on PATH) -> notepad
    # on Windows, nano on macOS / Linux. Honors EDITOR strings that include
    # arguments (e.g. 'code --wait').
    if ($env:EDITOR) {
        return $env:EDITOR
    }

    if (Get-Command code -ErrorAction SilentlyContinue) {
        return 'code'
    }

    if ((Get-AzDevOpsPlatform) -eq 'Windows') {
        return 'notepad'
    }

    return 'nano'
}


function az-Edit-AzDevOpsSchema {
    [CmdletBinding()]
    param()

    $paths = Initialize-AzDevOpsSchemaDir

    if (-not (Test-Path -LiteralPath $paths.File)) {
        $stub = New-AzDevOpsSchemaStub
        Write-AzDevOpsSchemaFile -Path $paths.File -Schema $stub
        Write-Host "Created stub schema at $($paths.File)." -ForegroundColor Cyan
        Write-Host "  Edit and run az-Test-AzDevOpsSchema to validate against your org." -ForegroundColor Cyan
    }

    $editor = Resolve-AzDevOpsEditor
    $editorTokens = @($editor -split '\s+' | Where-Object { $_ })

    if ($editorTokens.Count -eq 0) {
        Write-Host "No editor resolved (EDITOR / code / notepad / nano all unavailable)." -ForegroundColor Red
        return
    }

    $cmd = $editorTokens[0]

    $extraArgs = if ($editorTokens.Count -gt 1) {
        $editorTokens[1..($editorTokens.Count - 1)]
    }
    else {
        @()
    }

    Write-Host "Opening $($paths.File) in '$editor'..." -ForegroundColor Cyan
    & $cmd @extraArgs $paths.File
}


function Invoke-AzDevOpsWorkItemTypeShow {
    # Wraps `az devops invoke --area wit --resource workitemtypes` for one
    # type. Returns Ok / Error / Type so callers can react to a missing type
    # (org's process doesn't have one of the standards) without taking down
    # the whole flow.
    param([Parameter(Mandatory)] [string] $Type)

    $result = Get-AzDevOpsWorkItemTypeDefinition -Type $Type
    if ($result.ExitCode -ne 0) {
        return [PSCustomObject]@{ Ok = $false; Error = $result.Error; Type = $null }
    }

    try {
        # -AsHashtable because the workitemtypes REST payload contains
        # properties with empty-string names (typically in _links / extension
        # blocks); PS 7's default ConvertFrom-Json refuses those with
        # "provided JSON includes a property whose name is an empty string".
        $parsed = $result.Json | ConvertFrom-Json -AsHashtable
        return [PSCustomObject]@{ Ok = $true; Error = $null; Type = $parsed }
    }
    catch {
        $msg = "parse failed: $($_.Exception.Message)"
        return [PSCustomObject]@{ Ok = $false; Error = $msg; Type = $null }
    }
}


function ConvertTo-AzDevOpsSchemaFieldEntry {
    # Maps one fieldInstances[] element to our { name, ref, type, options? }
    # shape. Type defaults to 'string' since the workitemtypes REST response
    # doesn't surface the underlying field type; presence of allowedValues
    # promotes it to 'picklist'. Users refine via az-Edit-AzDevOpsSchema.
    param([Parameter(Mandatory)] $FieldInstance)

    $name = $FieldInstance.field.name
    $ref = $FieldInstance.field.referenceName

    $allowed = @()
    if ($FieldInstance.allowedValues) {
        $allowed = @($FieldInstance.allowedValues)
    }

    $type = if ($allowed.Count -gt 0) {
        'picklist'
    }
    else {
        'string'
    }

    $entry = [ordered]@{
        name = $name
        ref  = $ref
        type = $type
    }

    if ($type -eq 'picklist') {
        $entry.options = $allowed
    }

    return $entry
}


function az-Initialize-AzDevOpsSchema {
    [CmdletBinding()]
    param()

    if (-not (Assert-AzDevOpsAuthOrAbort -CommandName 'az-Initialize-AzDevOpsSchema')) {
        return
    }

    $paths = Initialize-AzDevOpsSchemaDir
    $knownRefs = Get-AzDevOpsSchemaSystemRefs
    $wiTypes = Get-AzDevOpsSchemaWorkItemTypes

    $schema = [ordered]@{}

    foreach ($wiType in $wiTypes) {
        Write-Host "-> Introspecting '$wiType'..." -ForegroundColor Cyan

        $showResult = Invoke-AzDevOpsWorkItemTypeShow -Type $wiType
        if (-not $showResult.Ok) {
            $firstLine = Get-AzDevOpsFirstStderrLine -Stderr $showResult.Error
            if (-not $firstLine) { $firstLine = '(unknown az error)' }
            Write-Host "  ! skipped '$wiType': $firstLine" -ForegroundColor Yellow
            continue
        }

        $required = @()
        $optional = @()

        $fieldInstances = @($showResult.Type.fieldInstances)
        foreach ($fi in $fieldInstances) {
            if (-not $fi.field) { continue }
            if ($fi.field.referenceName -in $knownRefs) { continue }

            $entry = ConvertTo-AzDevOpsSchemaFieldEntry -FieldInstance $fi

            if ($fi.alwaysRequired) {
                $required += $entry
            }
            else {
                $optional += $entry
            }
        }

        $schema[$wiType] = [ordered]@{
            required = $required
            optional = $optional
        }

        Write-Host "  OK  '$wiType' - $($required.Count) required, $($optional.Count) optional custom field(s)" -ForegroundColor Green
    }

    Write-AzDevOpsSchemaFile -Path $paths.File -Schema $schema

    Write-Host ""
    Write-Host "Wrote $($paths.File)" -ForegroundColor Cyan
    Write-Host "Refine field types and picklist options via az-Edit-AzDevOpsSchema, then run az-Test-AzDevOpsSchema." -ForegroundColor Cyan
}


function az-Test-AzDevOpsSchema {
    [CmdletBinding()]
    param()

    $paths = Get-AzDevOpsSchemaPaths
    if (-not (Test-Path -LiteralPath $paths.File)) {
        Write-Host "No schema configured at $($paths.File). Run az-Initialize-AzDevOpsSchema." -ForegroundColor Yellow
        return
    }

    $schema = Read-AzDevOpsSchemaFile
    if ($null -eq $schema) {
        Write-Host "INVALID - schema could not be loaded (see message above)" -ForegroundColor Red
        return
    }

    if (-not (Assert-AzDevOpsAuthOrAbort -CommandName 'az-Test-AzDevOpsSchema')) {
        return
    }

    $validTypes = Get-AzDevOpsSchemaValidTypes
    $unknownRefs = New-Object System.Collections.Generic.List[string]
    $picklistMismatches = New-Object System.Collections.Generic.List[string]
    $unknownTypes = New-Object System.Collections.Generic.List[string]

    foreach ($wiTypeProp in $schema.PSObject.Properties) {
        $wiType = $wiTypeProp.Name
        $entry = $wiTypeProp.Value

        $showResult = Invoke-AzDevOpsWorkItemTypeShow -Type $wiType
        if (-not $showResult.Ok) {
            Write-Host "  ! could not introspect '$wiType' - skipping ref check" -ForegroundColor Yellow
            continue
        }

        $orgFields = @{}
        foreach ($fi in @($showResult.Type.fieldInstances)) {
            if ($fi.field -and $fi.field.referenceName) {
                $orgFields[$fi.field.referenceName] = $fi
            }
        }

        foreach ($section in @('required', 'optional')) {
            $sectionList = $entry.$section
            if (-not $sectionList) { continue }

            foreach ($f in $sectionList) {
                if ($f.type -and ($f.type -notin $validTypes)) {
                    $unknownTypes.Add("$wiType.$($f.ref) (type='$($f.type)')")
                }

                if (-not $orgFields.ContainsKey($f.ref)) {
                    $unknownRefs.Add("$wiType.$($f.ref)")
                    continue
                }

                if ($f.type -eq 'picklist' -and $f.options) {
                    $allowed = @($orgFields[$f.ref].allowedValues)
                    foreach ($opt in $f.options) {
                        if ($opt -notin $allowed) {
                            $picklistMismatches.Add("$wiType.$($f.ref) option '$opt' not in org allowedValues")
                        }
                    }
                }
            }
        }
    }

    if ($unknownTypes.Count -gt 0) {
        Write-Host "  ! Unknown field types (treated as 'string'):" -ForegroundColor Yellow
        foreach ($t in $unknownTypes) {
            Write-Host "    - $t"
        }
    }

    if ($unknownRefs.Count -eq 0 -and $picklistMismatches.Count -eq 0) {
        Write-Host "VALID - schema parses, all refs exist, picklist options check out" -ForegroundColor Green
        return
    }

    if ($picklistMismatches.Count -eq 0) {
        Write-Host "STALE - unknown refs in $($paths.File):" -ForegroundColor Yellow
        foreach ($r in $unknownRefs) {
            Write-Host "  - $r"
        }
        return
    }

    Write-Host "INVALID - schema does not match org:" -ForegroundColor Red
    if ($unknownRefs.Count -gt 0) {
        Write-Host "  Unknown refs:"
        foreach ($r in $unknownRefs) {
            Write-Host "    - $r"
        }
    }
    if ($picklistMismatches.Count -gt 0) {
        Write-Host "  Picklist option mismatches:"
        foreach ($m in $picklistMismatches) {
            Write-Host "    - $m"
        }
    }
}
