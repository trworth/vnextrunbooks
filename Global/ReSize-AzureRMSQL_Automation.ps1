<#
.SYNOPSIS
  This runbook will Resize an SQL Azure Database.

.DESCRIPTION
  This runbook Resize an SQL Azure Database.
  The runbook can be started by supplying values to the SubscriptionId, ResourceGroupName, ResourceName and TargetSku as  input parameters.
  Or the runbook can be started by an Azure alert, in which case the input data is passed in the WebhookData parameter.
  The input needed is the data to identify which SQL Azure Server to ReSize.
  
  DEPENDENCIES
  - An Automation connection asset called "AzureRunAsConnection" that is of type AzureRunAsConnection.  
  - An Automation certificate asset called "AzureRunAsCertificate". 

.PARAMETER SubscriptionId
   Optional
   The Azure subscription id is required if you are starting the runbook in any way besides an Azure alert.

.PARAMETER ResourceGroupName
   Optional
   The Azure resource group name is required if you are starting the runbook in any way besides an Azure alert.

.PARAMETER ResourceName
   Optional
   The SQL Azure Database name is required if you are starting the runbook in any way besides an Azure alert.

.PARAMETER TargetSkuSize
   Optional
   The SQL Azure Target SKU Size is required if you are starting the runbook in any way besides an Azure alert.

.PARAMETER TargetStorageBytes
   Optional
   The SQL Azure Target Storage Size is required if you are starting the runbook in any way besides an Azure alert.

.PARAMETER WebhookData
   Optional
   This value will be set automatically if the runbook is triggered from an Azure alert.

.NOTES
   AUTHOR: Azure Automation Team 
   LASTEDIT: 2018-3-29
#>

[OutputType("PSAzureOperationResponse")]

param 
(
	[Parameter (Mandatory=$false)]
        [string] $SubscriptionId,
	[Parameter (Mandatory=$false)]
        [string] $ResourceGroupName,
	[Parameter (Mandatory=$false)]
        [string] $SQLAzureServerName,
    [Parameter (Mandatory=$false)]
        [string] $SQLAzureDatabaseName,
    [Parameter (Mandatory=$false)]
        [string] $TargetSkuSize,
    [Parameter (Mandatory=$false)]
        [string] $TargetDTU,
    [Parameter (Mandatory=$false)]
        [string] $TargetStorageBytes,
	[Parameter (Mandatory=$false)]
        [object] $WebhookData
)

$ErrorActionPreference = "stop"
        

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

    Write-Verbose "Set subscription to work against: $SubId" -Verbose
    $CurrentContext = Set-AzureRmContext -SubscriptionId $SubId -ErrorAction Stop | Write-Verbose

    Write-Verbose "Authenticated to Azure." -Verbose

    # Return the current context
    $CurrentContext
}

function Do-TheAction
{
    param 
    (
        [Parameter (Mandatory=$true)]
            [string] $SubId,
        [Parameter (Mandatory=$true)]
            [string] $RgName,    
        [Parameter (Mandatory=$true)]
            [string] $SQLAzureServer,
        [Parameter (Mandatory=$true)]
            [string] $SQLAzureDatabase,
        [Parameter (Mandatory=$true)]
            [string] $TargetSKU,
        [Parameter (Mandatory=$true)]
            [string] $newdbDTUsize,
        [Parameter (Mandatory=$false)]
            [string] $maxSizeBytes
       
    )
 
    Write-Verbose "Subscription Id: $SubId" -Verbose
    Write-Verbose "Resource Group Name: $RgName" -Verbose
    Write-Verbose "SQLAzureServer Name: $SQLAzureServer" -Verbose
    Write-Verbose "SQLAzureDatabase Name: $SQLAzureDatabase" -Verbose
    Write-Verbose "Target SKU Name: $TargetSKU" -Verbose
    Write-Verbose "Target DTU Size Name: $newdbDTUsize" -Verbose
    Write-Verbose "Target Size Bytes: $maxSizeBytes" -Verbose

     # Authenticate
        $CurrentContext = AuthenticateTo-Azure -SubId $SubId

       Write-Verbose "Set subscription to work against: $SubId" -Verbose
	  Set-AzureRmContext -SubscriptionId $SubId -ErrorAction Stop

        # # if Exists, 
        # Resize the Database using the server context  
        # Resize Azure SQL Database to new performance-level
        Write-Verbose "Searching for $SQLAzureServer in resource group '$RgName'..." -Verbose
        $SQLDB = Get-AzureRmSqlDatabase  -ResourceGroupName $rgname -Servername $SQLAzureServer -DatabaseName $SQLAzureDatabase 
        if (!$SQLDB) {
            Write-Verbose "$SQLAzureServer in resource group $RgName does not Exist..." -Verbose
        } else {
           
           if($maxSizeBytes) {
             Write-Verbose "Resizing the db $SQLAzureDatabase on the server $SQLAzureServer to Sku: $($TargetSKU) and DTU: $($newdbDTUsize) and storage: $($maxSizeBytes)..." -Verbose
            $Result = Set-AzureRmSqlDatabase  -Servername $SQLAzureServer -ResourceGroupName $rgname -DatabaseName $SQLAzureDatabase -Edition $TargetSKU -RequestedServiceObjectiveName $newdbDTUsize -MaxSizeBytes $maxSizeBytes  
            } else {
                Write-Verbose "Resizing the db $SQLAzureDatabase on the server $SQLAzureServer to Sku: $($TargetSKU) and DTU: $($newdbDTUsize)..." -Verbose
            $Result = Set-AzureRmSqlDatabase  -Servername $SQLAzureServer -ResourceGroupName $rgname -DatabaseName $SQLAzureDatabase -Edition $TargetSKU -RequestedServiceObjectiveName $newdbDTUsize
            }
        }
       
        Write-Verbose "Verify Resize Occured" -Verbose
        if($($Result.Edition) -eq $TargetSKu -and $($Result.CurrentServiceObjectiveName) -eq $newdbDTUsize) {
            write-verbose "SQL Azure Resized Successfully to $TargetSku and $newdbDTUSize"  -Verbose
        } else 
        {
            write-Error "SQL Azure Resize Failed: Current: SKU $($Result.Edition) Expected SKU: $($TargetSKU), CurrentDTU: $($Result.CurrentServiceObjectiveName) Expected DTU: $($newdbDTUsize) Expected Storage: $($newdbDTUsize)"
        }
       
       Write-Output $Result
    # [OutputType("PSAzureOperationResponse")]
}

# END FUNCTIONS

if ($WebhookData) 
{ 
	# Get the data object from WebhookData
	$WebhookBody = (ConvertFrom-Json -InputObject $WebhookData.RequestBody)
	
    # Get the info needed to identify the VM (depends on the payload schema)
    $schemaId = $WebhookBody.schemaId
    Write-Verbose "schemaId: $schemaId" -Verbose
    if ($schemaId -eq "AzureMonitorMetricAlert") {
        # This is the near-real-time Metric Alert schema
        $AlertContext = [object] ($WebhookBody.data).context
		$ResourceName = $AlertContext.resourceName
        $status = ($WebhookBody.data).status
    }
    elseif ($schemaId -eq "Microsoft.Insights/activityLogs") {
        # This is the Activity Log Alert schema
        $AlertContext = [object] (($WebhookBody.data).context).activityLog
		$ResourceName = (($AlertContext.resourceId).Split("/"))[-1]
        $status = ($WebhookBody.data).status
    }
    elseif ($schemaId -eq $null) {
        # This is the original Metric Alert schema
        $AlertContext = [object] $WebhookBody.context
		$ResourceName = $AlertContext.resourceName
        $status = $WebhookBody.status
    }
    else {
        # Schema not supported
        Write-Error "The alert data schema - $schemaId - is not supported."
    }

    Write-Verbose "status: $status" -Verbose
	if ($status -eq "Activated") 
    {
		$ResourceType = $AlertContext.resourceType
		$ResourceGroupName = $AlertContext.resourceGroupName
		$SubId = $AlertContext.subscriptionId
        $SQLAzureServerName = $AlertContext.SQLAzureServer
        $SQLAzureDatabaseName = $AlertContext.SQLAzureDatabase
        $TargetSkuSize = $AlertContext.TargetSKU
        $TargetDTUSize = $AlertContext.TargetDTU
        $TargetStorageBytes = $AlertContext.TargetStorageBytes

        Write-Verbose "resourceType: $ResourceType" -Verbose
	
	    # Is this a supported resourceType?
	    if ($ResourceType -eq "Microsoft.Sql/servers")
	    {
		    # This is an SQL Azure Server
		    Write-Verbose "This is an SQL Azure Server." -Verbose
            
            # Call a function to perform the action
           Do-TheAction -SubId $SubscriptionId -RgName $ResourceGroupName -SQLAzureServer $SQLAzureServerName -SQLAzureDatabase $SQLAzureDatabaseName -TargetSKU $TargetSkuSize -newdbDTUsize $TargetDTU -maxSizeBytes $TargetStorageBytes
         

	    }
	    else {
            # ResourceType not supported
		    Write-Error "$ResourceType is not a supported resource type for this runbook."
	    }
    }
    else {
        # The alert status was not 'Activated' so no action taken
		Write-Verbose ("No action taken. Alert status: " + $status) -Verbose
    }
}
elseif ($SubscriptionId -and $ResourceGroupName -and $SQLAzureServerName -and $SQLAzureDatabaseName -and $TargetSkuSize -and $TargetDTU) {
    # Runbook being started by non-webhook method
    Write-Verbose "Runbook is being started by a method other than Azure alert." -Verbose

    # Call a function to perform the action
    Do-TheAction -SubId $SubscriptionId -RgName $ResourceGroupName -SQLAzureServer $SQLAzureServerName -SQLAzureDatabase $SQLAzureDatabaseName -TargetSKU $TargetSkuSize -newdbDTUsize $TargetDTU -maxSizeBytes $TargetStorageBytes
  
}
else {
    # Error
    Write-Error "You must start this runbook with an input value for the WebhookData parameter or with input values for all of the other parameters." 
}