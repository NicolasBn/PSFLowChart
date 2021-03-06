<#

.DESCRIPTION
 Bootstrap and build script for PowerShell module pipeline

#>
[CmdletBinding()]
param(

    [Parameter(Position = 0)]
    [string[]]$Tasks = '.',

    [Parameter()]
    [validateScript(
        { Test-Path -Path $_ }
    )]
    $BuildConfig = './build.yaml',

    # A Specific folder to build the artefact into.
    [Parameter()]
    $OutputDirectory = 'output',

    # Can be a path (relative to $PSScriptRoot or absolute) to tell Resolve-Dependency & PSDepend where to save the required modules,
    # or use CurrentUser, AllUsers to target where to install missing dependencies
    # You can override the value for PSDepend in the Build.psd1 build manifest
    # This defaults to $OutputDirectory/modules (by default: ./output/modules)
    [Parameter()]
    $RequiredModulesDirectory = $(Join-Path 'output' 'RequiredModules'),

    # Filter which tags to run when invoking Pester tests
    # This is used in the Invoke-Pester.pester.build.ps1 tasks
    [string[]]
    [parameter()]
    $PesterTag,

    # Filter which tags to exclude when invoking Pester tests
    # This is used in the Invoke-Pester.pester.build.ps1 tasks
    [string[]]
    [parameter()]
    $PesterExcludeTag,

    $CodeCoverageThreshold = 50,

    [Parameter()]
    [Alias('bootstrap')]
    [switch]$ResolveDependency,

    [parameter(DontShow)]
    [AllowNull()]
    $BuildInfo
)

# The BEGIN block (at the end of this file) handles the Bootstrap of the Environment before Invoke-Build can run the tasks
# if the -ResolveDependency (aka Bootstrap) is specified, the modules are already available, and can be auto loaded

Process {

    if ($MyInvocation.ScriptName -notLike '*Invoke-Build.ps1') {
        # Only run the process block through InvokeBuild (Look at the Begin block at the bottom of this script)
        return
    }

    # Execute the Build Process from the .build.ps1 path.
    Push-Location -Path $PSScriptRoot -StackName BeforeBuild

    try {
        Write-Host -ForeGroundColor magenta "[build] Parsing defined tasks"

        # Load Default BuildInfo if not provided as parameter
        if (!$PSBoundParameters.ContainsKey('BuildInfo')) {
            try {
                if (Test-Path $BuildConfig) {
                    $ConfigFile = (Get-Item -Path $BuildConfig)
                    Write-Host "[build] Loading Configuration from $ConfigFile"
                    $BuildInfo = switch -Regex ($ConfigFile.Extension) {
                        # Native Support for PSD1
                        '\.psd1' {
                            Import-PowerShellDataFile -Path $BuildConfig
                        }
                        # Support for yaml when module PowerShell-Yaml is available
                        '\.[yaml|yml]' {
                            Import-Module -ErrorAction Stop -Name 'powershell-yaml'
                            ConvertFrom-Yaml -Yaml (Get-Content -Raw $ConfigFile)
                        }
                        # Native Support for JSON and JSONC (by Removing comments)
                        '\.[json|jsonc]' {
                            $JSONC = (Get-Content -Raw -Path $ConfigFile)
                            $JSON = $JSONC -replace '(?m)\s*//.*?$' -replace '(?ms)/\*.*?\*/'
                            # This should probably be converted to hashtable for splatting
                            $JSON | ConvertFrom-Json
                        }
                        default {
                            Write-Error "Extension '$_' not supported. using @{}"
                            @{ }
                        }
                    }
                }
                else {
                    Write-Host -Object "Configuration file $BuildConfig not found" -ForegroundColor Red
                    $BuildInfo = @{ }
                }
            }
            catch {
                Write-Host -Object "Error loading data from $ConfigFile" -ForegroundColor Red
                $BuildInfo = @{ }
                Write-Error $_.Exception.Message
            }
        }

        # If the Invoke-Build Task Header is specified in the Build Info, set it
        if ($BuildInfo.TaskHeader) {
            Set-BuildHeader ([scriptblock]::Create($BuildInfo.TaskHeader))
        }

        # Import Tasks from modules via their exported aliases when defined in BUild Manifest
        # https://github.com/nightroman/Invoke-Build/tree/master/Tasks/Import#example-2-import-from-a-module-with-tasks
        if ($BuildInfo.containsKey('ModuleBuildTasks')) {
            foreach ($Module in $BuildInfo['ModuleBuildTasks'].Keys) {
                try {
                    $LoadedModule = Import-Module $Module -PassThru -ErrorAction Stop
                    foreach ($TaskToExport in $BuildInfo['ModuleBuildTasks'].($Module)) {
                        $LoadedModule.ExportedAliases.GetEnumerator().Where{
                            # using -like to support wildcard
                            Write-Host -ForegroundColor DarkGray "`t Loading $($_.Key)..."
                            $_.Key -like $TaskToExport
                        }.ForEach{
                            # Dot sourcing the Tasks via their exported aliases
                            . (get-alias $_.Key)
                        }
                    }
                }
                catch {
                    Write-Host -ForegroundColor Red -Object "Could not load tasks for module $Module."
                    Write-Error $_
                }
            }
        }

        # Loading Build Tasks defined in the .build/ folder (will override the ones imported above if same task name)
        Get-ChildItem -Path ".build/" -Recurse -Include *.ps1 -ErrorAction Ignore | Foreach-Object {
            "Importing file $($_.BaseName)" | Write-Verbose
            . $_.FullName
        }

        # Synopsis: Empty task, useful to test the bootstrap process
        task noop { }

        # Define default task sequence ("."), can be overridden in the $BuildInfo
        task . {
            Write-Build Yellow "No sequence currently defined for the default task"
        }

        # Load Invoke-Build task sequences/workflows from $BuildInfo
        foreach ($Workflow in $BuildInfo.BuildWorkflow.keys) {
            Write-Verbose "Creating Build Workflow '$Workflow' with tasks $($BuildInfo.BuildWorkflow.($Workflow) -join ', ')"
            $WorkflowItem = $BuildInfo.BuildWorkflow.($Workflow)
            if ($WorkflowItem.Trim() -match '^\{(?<sb>[\w\W]*)\}$') {
                $WorkflowItem = [ScriptBlock]::Create($Matches['sb'])
            }
            Write-Host -ForegroundColor DarkGray "Adding $Workflow"
            task $Workflow $WorkflowItem
        }

        Write-Host -ForeGroundColor magenta "[build] Executing requested workflow: $($Tasks -join ', ')"

    }
    finally {
        Pop-Location -StackName BeforeBuild
    }
}

Begin {
    # Bootstrapping the environment before using Invoke-Build as task runner

    if ($MyInvocation.ScriptName -notLike '*Invoke-Build.ps1') {
        Write-Host -foregroundColor Green "[pre-build] Starting Build Init"
        Push-Location $PSScriptRoot -StackName BuildModule
    }

    if ($RequiredModulesDirectory -in @('CurrentUser', 'AllUsers')) {
        # Installing modules instead of saving them
        Write-Host -foregroundColor Green "[pre-build] Required Modules will be installed for $RequiredModulesDirectory, not saved."
        # Tell Resolve-Dependency to use provided scope as the -PSDependTarget if not overridden in Build.psd1
        $PSDependTarget = $RequiredModulesDirectory
    }
    else {
        if (-Not (Split-Path -IsAbsolute -Path $OutputDirectory)) {
            $OutputDirectory = Join-Path -Path $PSScriptRoot -ChildPath $OutputDirectory
        }

        # Resolving the absolute path to save the required modules to
        if (-Not (Split-Path -IsAbsolute -Path $RequiredModulesDirectory)) {
            $RequiredModulesDirectory = Join-Path -Path $PSScriptRoot -ChildPath $RequiredModulesDirectory
        }

        # Create the output/modules folder if not exists, or resolve the Absolute path otherwise
        if (Resolve-Path $RequiredModulesDirectory -ErrorAction SilentlyContinue) {
            Write-Debug "[pre-build] Required Modules path already exist at $RequiredModulesDirectory"
            $RequiredModulesPath = Convert-Path $RequiredModulesDirectory
        }
        else {
            Write-Host -foregroundColor Green "[pre-build] Creating required modules directory $RequiredModulesDirectory."
            $RequiredModulesPath = (New-Item -ItemType Directory -Force -Path $RequiredModulesDirectory).FullName
        }

        # Prepending $RequiredModulesPath folder to PSModulePath to resolve from this folder FIRST
        if ($RequiredModulesDirectory -notIn @('CurrentUser', 'AllUsers') -and
            (($Env:PSModulePath -split [io.path]::PathSeparator) -notContains $RequiredModulesDirectory)) {
            Write-Host -foregroundColor Green "[pre-build] Prepending '$RequiredModulesDirectory' folder to PSModulePath"
            $Env:PSModulePath = $RequiredModulesDirectory + [io.path]::PathSeparator + $Env:PSModulePath
        }

        # Prepending $OutputDirectory folder to PSModulePath to resolve built module from this folder
        if (($Env:PSModulePath -split [io.path]::PathSeparator) -notContains $OutputDirectory) {
            Write-Host -foregroundColor Green "[pre-build] Prepending '$OutputDirectory' folder to PSModulePath"
            $Env:PSModulePath = $OutputDirectory + [io.path]::PathSeparator + $Env:PSModulePath
        }

        # Tell Resolve-Dependency to use $RequiredModulesPath as -PSDependTarget if not overridden in Build.psd1
        $PSDependTarget = $RequiredModulesPath
    }

    if ($ResolveDependency) {
        Write-Host -Object "[pre-build] Resolving dependencies." -foregroundColor Green
        $ResolveDependencyParams = @{ }

        # If BuildConfig is a Yaml file, bootstrap powershell-yaml via ResolveDependency
        if ($BuildConfig -match '\.[yaml|yml]$') {
            $ResolveDependencyParams.add('WithYaml', $True)
        }

        # TODO: 3 way merge: BoundParameter over BuildInfo over Scope variables (i.e. defaults from args)
        $ResolveDependencyAvailableParams = (get-command -Name '.\Resolve-Dependency.ps1').parameters.keys
        foreach ($CmdParameter in $ResolveDependencyAvailableParams) {

            # The parameter has been explicitly used for calling the .build.ps1
            if ($MyInvocation.BoundParameters.ContainsKey($CmdParameter)) {
                $ParamValue = $MyInvocation.BoundParameters.ContainsKey($CmdParameter)
                Write-Debug " adding  $CmdParameter :: $ParamValue [from user-provided parameters to Build.ps1]"
                $ResolveDependencyParams.Add($CmdParameter, $ParamValue)
            }
            # Use defaults parameter value from Build.ps1, if any
            else {
                if ($ParamValue = Get-Variable -Name $CmdParameter -ValueOnly -ErrorAction Ignore) {
                    Write-Debug " adding  $CmdParameter :: $ParamValue [from default Build.ps1 variable]"
                    $ResolveDependencyParams.add($CmdParameter, $ParamValue)
                }
            }
        }

        Write-Host -foregroundColor Green "[pre-build] Starting bootstrap process."
        .\Resolve-Dependency.ps1 @ResolveDependencyParams
    }

    if ($MyInvocation.ScriptName -notLike '*Invoke-Build.ps1') {
        Write-Verbose "Bootstrap completed. Handing back to InvokeBuild."
        if ($PSBoundParameters.ContainsKey('ResolveDependency')) {
            Write-Verbose "Dependency already resolved. Removing task"
            $null = $PSBoundParameters.Remove('ResolveDependency')
        }
        Write-Host -foregroundColor Green "[build] Starting build with InvokeBuild."
        Invoke-Build @PSBoundParameters -Task $Tasks -File $MyInvocation.MyCommand.Path
        Pop-Location -StackName BuildModule
        return
    }
}