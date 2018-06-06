
 #---------Inputs variables for PSModule Updates script--------------
	$SubId = Get-AutomationVariable -Name 'Internal_AzureSubscriptionId'
    $AutomationAccountName = Get-AutomationVariable -Name 'Internal_AutomationAccountName'
    $ResourceGroupName = Get-AutomationVariable -Name 'Internal_ResourceGroupName'
 #---------Inputs variables for PSModule Updates script--------------
  
# BEGIN FUNCTIONS
function AuthenticateTo-Azure
{
    param 
    (
        [Parameter (Mandatory=$true)]
            [string] $SubId
    )
    $ConnectionAssetName = "AzureRunAsConnection"

    # Authenticate to Azure with service principal and certificate
    Write-Verbose "Get connection asset: $ConnectionAssetName" -Verbose
    $Conn = Get-AutomationConnection -Name $ConnectionAssetName
    if ($Conn -eq $null)
    {
        throw "Could not retrieve connection asset: $ConnectionAssetName. Check that this asset exists in the Automation account."
    }
    Write-Verbose "Authenticating to Azure with service principal." -Verbose
    Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationId $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint | Write-Verbose

    $CurrentContext = Set-AzureRmContext -SubscriptionId $SubId -ErrorAction Stop | Write-Verbose
   
    Write-Verbose "Authenticated to Azure." -Verbose

    # Return the current context
    $CurrentContext
}

function Sort-CustomList{
    param(
    [Parameter(ValueFromPipeline=$true)]$collection,
    [Parameter(Position=0)]$customList,
    [Parameter(Position=1)]$propertyName,
    [Parameter(Position=2)]$additionalProperty
    )
    $properties=,{
        $rank=$customList.IndexOf($($_."$propertyName".ToLower()))
       
        if($rank -ne -1){$rank}
        else{[System.Double]::PositiveInfinity}
    } 
    if ($additionalProperty){
        $properties+=$additionalProperty
    }
    $Input | sort $properties
}
function Do-TheAction
{
    param
    (
    [Parameter (Mandatory=$true)] [string] $SubId,
    [Parameter (Mandatory=$true)] [string] $AutomationAccountName,
    [Parameter (Mandatory=$true)] [string] $ResourceGroupName
    )
    Write-Verbose "Subscription Id: $SubId" -Verbose
     # Authenticate
    $CurrentContext = AuthenticateTo-Azure -SubId $SubId
   
    Write-Verbose "Set subscription to work against: $SubId" -Verbose
    $CurrentContext = Set-AzureRmContext -SubscriptionId $SubId -ErrorAction Stop | Write-Verbose

    # Get the automation job id for this runbook job 
    $AutomationJobID = $PSPrivateMetaData.JobId.Guid 

    # check to see if another instance is queued or running
    $CurrentJob = Get-AzureRMAutomationJob -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName -Id $AutomationJobID 
      

    # Get the Active Jobs 
    $AllActiveJobs = $(Get-AzureRMAutomationJob -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName -RunBook $($CurrentJob.RunbookName)) | ?{$($_.Status) -eq "Running" -or $($_.Status) -eq "Starting" -or $($_.Status) -eq "Queued"} 
   Write-Verbose "AllActiveJobs: $($AllActiveJobs.length)" -Verbose

    # Get the Oldest (first) Jobs 
    $OldestJob = $AllActiveJobs | Sort-Object -Property CreationTime  | Select-Object -First 1 
        
    if ($AutomationJobID -eq $OldestJob.JobId  -or $($AllActiveJobs.length) -eq 0) 
    { 
        $moduleUpGrade = $(Get-AzureRmAutomationVariable -Name 'Internal_ModuleUpgrade' -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName )
        Write-output "This runbook job $($OldestJob.JobId) is the Oldest, Executing" 
        if( $moduleUpGrade -eq $null) {
            New-AzureRmAutomationVariable -Name 'Internal_ModuleUpgrade' -Value "Running:$($OldestJob.JobId)" -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName -encrypted $false
        } else {
            Set-AzureRmAutomationVariable -Name 'Internal_ModuleUpgrade' -Value "Running:$($OldestJob.JobId)" -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName -encrypted $false
        }

        $ModuleOrder = @("azurerm.profile","azurerm.compute","azure.storage","azurerm.resources","azurerm.keyvault","azurerm.automation","azurerm.operationalinsights","Azurerm.insights","azurerm.sql","azurerm.storage","azure")

        $UnOrderedModules = Get-AzureRmAutomationModule `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName | ?{$_.name -match 'Azure'}

        $Modules = $UnOrderedModules | Sort-CustomList $ModuleOrder Name

        $AzureRMProfileModule = Get-AzureRmAutomationModule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name 'AzureRM.Profile'

        # Force AzureRM.Profile to be evaluated first since some other modules depend on it 
        # being there / up to date to import successfully
        $Modules = @($AzureRMProfileModule) + $Modules
            
        write-verbose "Module Count: $($modules.length)" -verbose

        foreach($Module in $Modules) {
            Import-PSModule -moduleName $($module.name) -ModuleVersion $($module.version)
        }

        Set-AzureRmAutomationVariable -Name 'Internal_ModuleUpgrade' -Value "Completed:$($OldestJob.JobId)" -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName  -encrypted $false

    } else {
        write-output "Another (older) Instance already $($OldestJob.Status). (see jobID: $($OldestJob.JobId)), aborting."
    }
}


function Import-PSModule
{ 
    param
    (
        [Parameter (Mandatory=$true)]
        $moduleName,
        [Parameter (Mandatory=$true)]
        $ModuleVersionInAutomation
    )
 
    $CurrentContext = Set-AzureRmContext -SubscriptionId $SubId -ErrorAction Stop | Write-Verbose

    if($moduleName) {
       
        Write-verbose "Checking if module '$ModuleName' is up to date in your automation account" -verbose

        $Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=1" 
        $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -UseBasicParsing

        $PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $($SearchResult.id)
        $LatestModuleVersionOnPSGallery = $($PackageDetails.entry.properties.version)

        if(!$LatestModuleVersionOnPSGallery){
            Write-Output "Failed"
            Write-Error "Failed to get latest version of $ModuleName"
            Set-AzureRmAutomationVariable -Name 'Internal_PSModuleUpgrade' -Value "Failed:$($OldestJob.JobId)" -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName -encrypted $false
        }

        Write-verbose "'$ModuleName' Current Version: $($ModuleVersionInAutomation) Latest Version: $($LatestModuleVersionOnPSGallery)" -verbose
        if($ModuleVersionInAutomation -ne $LatestModuleVersionOnPSGallery) {
            Write-Output "Module '$ModuleName' is not up to date. Latest version on PS Gallery is $($LatestModuleVersionOnPSGallery) but this automation account has version $($ModuleVersionInAutomation)"
            Write-Output "Importing latest version of '$ModuleName' into your automation account"

            $ModuleContentUrl = "https://www.powershellgallery.com/api/v2/package/$ModuleName/$ModuleVersion"

            # Find the actual blob storage location of the module
            do {
                $ActualUrl = $ModuleContentUrl
                $ModuleContentUrl = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore).Headers.Location 
            } while($ModuleContentUrl -ne $Null)

            $Module = New-AzureRmAutomationModule `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $ModuleName `
                -ContentLink $ActualUrl
                
            while($Module.ProvisioningState -ne 'Succeeded' -and $Module.ProvisioningState -ne 'Failed') {
                Start-Sleep -Seconds 10
            
                $Module = Get-AzureRmAutomationModule `
                    -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -Name $ModuleName

                Write-Output 'Polling for import completion...'
            }

            if($Module.ProvisioningState -eq 'Succeeded') {
                Write-Output "Success"
            }
            else {
                Write-Output "Failed"
                Write-Error "Failed to import latest version of $ModuleName"
                Set-AzureRmAutomationVariable -Name 'Internal_ModuleUpgrade' -Value "Failed:$($OldestJob.JobId)" -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName -encrypted $false
            }   
        
        } else {
            Write-Output "'$ModuleName' is Latest"
        }
    }
}

# Call a function to perform the action
Do-TheAction -Subid $subid -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName
