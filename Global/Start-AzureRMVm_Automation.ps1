<#
.SYNOPSIS
  This runbook will start an Azure ARM VM.

.DESCRIPTION
  This runbook will start an Azure ARM VM (not classic).
  The runbook can be started by supplying values to the SubscriptionId, ResourceGroupName, and ResourceName input parameters.
  Or the runbook can be started by an Azure alert, in which case the input data is passed in the WebhookData parameter.
  The input needed is the data to identify which VM to delete.
  
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
   The Azure virtual machine name is required if you are starting the runbook in any way besides an Azure alert.

.PARAMETER WebhookData
   Optional
   This value will be set automatically if the runbook is triggered from an Azure alert.

.NOTES
   AUTHOR: Azure Automation Team 
   LASTEDIT: 2018-3-19
#>

[OutputType("PSAzureOperationResponse")]

param 
(
	[Parameter (Mandatory=$false)]
        [string] $SubscriptionId,
	[Parameter (Mandatory=$false)]
        [string] $ResourceGroupName,
	[Parameter (Mandatory=$false)]
        [string] $ResourceName,
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
    $CurrentContext = Set-AzureRmContext -SubscriptionId $SubId -ErrorAction Stop

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
            [string] $VmName
    )

    Write-Verbose "Subscription Id: $SubId" -Verbose
    Write-Verbose "Resource Group Name: $RgName" -Verbose
    Write-Verbose "Resource Name: $VmName" -Verbose

    # Authenticate
    $CurrentContext = AuthenticateTo-Azure -SubId $SubId

	 Write-Verbose "Set subscription to work against: $SubId" -Verbose
     Set-AzureRmContext -SubscriptionId $SubId -ErrorAction Stop

    # Start the ARM VM  
    Write-Verbose "Starting the VM '$VmName' in resource group '$RgName'..." -Verbose
    Start-AzureRmVm -Name $VmName -ResourceGroupName $RgName -AzureRmContext $CurrentContext
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
        Write-Verbose "resourceType: $ResourceType" -Verbose
	
	    # Is this a supported resourceType?
	    if ($ResourceType -eq "Microsoft.Compute/virtualMachines")
	    {
		    # This is an ARM VM
		    Write-Verbose "This is an ARM VM." -Verbose
            
            # Call a function to perform the action
            Do-TheAction -SubId $SubscriptionId -RgName $ResourceGroupName -VmName $ResourceName
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
elseif ($SubscriptionId -and $ResourceGroupName -and $ResourceName) {
    # Runbook being started by non-webhook method
    Write-Verbose "Runbook is being started by a method other than Azure alert." -Verbose

    # Call a function to perform the action
    Do-TheAction -SubId $SubscriptionId -RgName $ResourceGroupName -VmName $ResourceName
}
else {
    # Error
    Write-Error "You must start this runbook with an input value for the WebhookData parameter or with input values for all of the other parameters." 
}