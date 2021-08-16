  
##################################################################################################
#
# Parameters to this script file.
#

[CmdletBinding()]
param(
    # comma- separated list of powershell modules.
    [string] $PsModules = "Az",

    # comma- separated list of powershell modules.
    [string] $Packages = "Git",

    # Name of keyvault to retrieve secret from
    [string] $KeyVaultName = "aadtlkv",

    # Name of secret to retrieve
    [string] $SecretName = "bitbucket",

    # Name of CSV Path to retrieve
    [string] $csvPath = "./repos.csv",

    # Boolean indicating if we should allow empty checksums. Default to true to match previous artifact functionality despite security
    [bool] $AllowEmptyChecksums = $true,

    # Boolean indicating if we should ignore checksums. Default to false for security
    [bool] $IgnoreChecksums = $false,
    
    # Minimum PowerShell version required to execute this script.
    [int] $PSVersionRequired = 5
)

###################################################################################################
#
# PowerShell configurations
#

# NOTE: Because the $ErrorActionPreference is "Stop", this script will stop on first failure.
#       This is necessary to ensure we capture errors inside the try-catch-finally block.
$ErrorActionPreference = 'Stop'

# Suppress progress bar output.
$ProgressPreference = 'SilentlyContinue'

# Ensure we force use of TLS 1.2 for all downloads.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Expected path of the choco.exe file.
$choco = "$Env:ProgramData/chocolatey/choco.exe"

###################################################################################################
#
# Handle all errors in this script.
#

trap
{
    # NOTE: This trap will handle all errors. There should be no need to use a catch below in this
    #       script, unless you want to ignore a specific error.
    $message = $Error[0].Exception.Message
    if ($message)
    {
        Write-Host -Object "`nERROR: $message" -ForegroundColor Red
    }

    Write-Host "`nThe artifact failed to apply.`n"

    # IMPORTANT NOTE: Throwing a terminating error (using $ErrorActionPreference = "Stop") still
    # returns exit code zero from the PowerShell script when using -File. The workaround is to
    # NOT use -File when calling this script and leverage the try-catch-finally block and return
    # a non-zero exit code from the catch block.
    exit -1
}

###################################################################################################
#
# Functions used in this script.
#

function Ensure-PowershellModules
{
    [CmdletBinding()]
    param(
        [string] $PsModulesStr
    )
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted 
    Install-PackageProvider -Name nuget -Confirm:$False
    $PsModules = $PsModulesStr.Split(",")
    foreach($m in $PsModules)
    {
        Install-Module $m -Confirm:$False
    }


}

function Ensure-Chocolatey
{
    [CmdletBinding()]
    param(
        [string] $ChocoExePath
    )

    if (-not (Test-Path "$ChocoExePath"))
    {
        Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        if ($LastExitCode -eq 3010)
        {
            Write-Host 'The recent changes indicate a reboot is necessary. Please reboot at your earliest convenience.'
        }
    }
}

function Install-Packages
{
    [CmdletBinding()]
    param(
        [string] $ChocoExePath,
        $Packages
    )

    $Packages = $Packages.split(',; ', [StringSplitOptions]::RemoveEmptyEntries)
    $Packages | % {
        $checkSumFlags = ""
        if ($AllowEmptyChecksums)
        {
            $checkSumFlags = $checkSumFlags + " --allow-empty-checksums "
        }
        if ($IgnoreChecksums)
        {
            $checkSumFlags = $checkSumFlags + " --ignore-checksums "
        }
        $expression = "$ChocoExePath install -y -f --acceptlicense $checkSumFlags --no-progress --stoponfirstfailure $_"
        Invoke-ExpressionImpl -Expression $expression
    }
}


function Ensure-PowerShell
{
    [CmdletBinding()]
    param(
        [int] $Version
    )

    if ($PSVersionTable.PSVersion.Major -lt $Version)
    {
        throw "The current version of PowerShell is $($PSVersionTable.PSVersion.Major). Prior to running this artifact, ensure you have PowerShell $Version or higher installed."
    }
}

function RunCommand
{
    [CmdletBinding()]
    param(
        $KeyvaultName,

        $secretName,

        $csvPath
    )
    # Run custom command for this artifact.
   $VM = Invoke-RestMethod -Headers @{"Metadata"="true"} -Method GET  -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01"
   Login-AzAccount -Identity
   $secret = Get-AzKeyVaultSecret -VaultName $KeyvaultName -Name $secretName -AsPlainText
   $repos = Import-Csv -Path $csvPath
   foreach($r in $repos)
   {
            $cmd = "git clone -q https://$($secretName):$($secret)@$($r)"
            Invoke-Expression $cmd -ErrorAction SilentlyContinue
   }


}

function Invoke-ExpressionImpl
{
    [CmdletBinding()]
    param(
        $Expression
    )

    # This call will normally not throw. So, when setting -ErrorVariable it causes it to throw.
    # The variable $expError contains whatever is sent to stderr.
    iex $Expression -ErrorVariable expError

    # This check allows us to capture cases where the command we execute exits with an error code.
    # In that case, we do want to throw an exception with whatever is in stderr. Normally, when
    # Invoke-Expression throws, the error will come the normal way (i.e. $Error) and pass via the
    # catch below.
    if ($LastExitCode -or $expError)
    {
        if ($LastExitCode -eq 3010)
        {
            # Expected condition. The recent changes indicate a reboot is necessary. Please reboot at your earliest convenience.
        }
        elseif ($expError[0])
        {
            throw $expError[0]
        }
        else
        {
            throw "Installation failed ($LastExitCode)."
        }
    }
}


###################################################################################################
#
# Main execution block.
#

try
{
    pushd $PSScriptRoot

    Write-Host 'Validating parameters.'

    Write-Host 'Configuring PowerShell session.'
    Ensure-PowerShell -Version $PSVersionRequired
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null

    if($PsModules -ne "")
    {
        Write-Host 'Configuring PowerShell Modules.'
        Ensure-PowershellModules $PsModules
    }
    Write-Host 'Checking Chocolately'
    Ensure-Chocolatey -ChocoExePath $choco

    if($Packages -ne "")
    {
        Write-Host 'Checking Az Cli'
        Install-Packages -Packages $Packages -ChocoExePath $choco
    }

    Write-Host 'Running Command'
    RunCommand -KeyvaultName $KeyVaultName -secretName $SecretName -csvPath $csvPath

    Write-Host "`nThe artifact was applied successfully.`n"
}
finally
{
    popd
}
