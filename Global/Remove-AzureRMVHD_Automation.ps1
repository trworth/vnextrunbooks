<#
.SYNOPSIS
  This runbook will Remove a VHD blob

.DESCRIPTION
  This runbook will Remove a VHD blob.
  The runbook can be started by supplying values to the SubscriptionId, $storageAccount, $BlobVHD name as  input parameters.
  Or the runbook can be started by an Azure alert, in which case the input data is passed in the WebhookData parameter.
  The input needed is the data to identify which SQL Azure Server to ReSize.
  
  DEPENDENCIES
  - An Automation connection asset called "AzureRunAsConnection" that is of type AzureRunAsConnection.  
  - An Automation certificate asset called "AzureRunAsCertificate". 

.PARAMETER SubscriptionId
   Optional
   The Azure subscription id is required if you are starting the runbook in any way besides an Azure alert.

.PARAMETER $StorageAccount
    The Storage Account to use

.PARAMETER $BlobVHD
   the name of the blob to remove

.PARAMETER WebhookData
   Optional
   This value will be set automatically if the runbook is triggered from an Azure alert.

.NOTES
   AUTHOR: Azure Automation Team 
   LASTEDIT: 2018-4-29
#>

[OutputType("PSAzureOperationResponse")]

param 
(
	[Parameter (Mandatory=$false)]
        [string] $SubscriptionId,
	[Parameter (Mandatory=$false)]
        [String] $storageAccountName,
	[Parameter (Mandatory=$false)]
        [String] $BlobVHD,
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
        [Parameter (Mandatory=$false)]
             [String]$StorageAccountName,    
        [Parameter (Mandatory=$false)]
             [String] $blobVHD
    )
 
    Write-Verbose "Set subscription to work against: $SubId" -Verbose
    $CurrentContext = Set-AzureRmContext -SubscriptionId $SubId -ErrorAction Stop
	
    $blob = Get-AzureStorageBlob -Container $_.Container -Blob $_.vhd -Context $context

    #If a Page blob is not attached as disk then LeaseStatus will be unlocked
    if($blob.ICloudBlob.Properties.LeaseStatus -eq 'Unlocked'){
            
        Write-Verbose "Deleting unattached VHD with Uri: $($_.ICloudBlob.Uri.AbsoluteUri)" -Verbose

            #   $blob | Remove-AzureStorageBlob -Force

        $_ | Add-Member -type NoteProperty -Name 'Removed' -Value 'Yes'

        Write-Verbose "Deleted unattached VHD with Uri: $($_.ICloudBlob.Uri.AbsoluteUri)" -Verbose

		Write-Output '"BlobDeleted": {"Blob":  {"' + $($Blob.Name) +'", "Status": "Blob Deleted", "StorageAccountName": "'+ $($storageAccount) + '"}"'

    } else{
        Write-Error "Unable to delete unattached VHD with Uri: $($_.ICloudBlob.Uri.AbsoluteUri) due to Lease"
   }
  
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
		$SubId = $AlertContext.subscriptionId
 
        Write-Verbose "resourceType: $ResourceType" -Verbose
	
	    # Is this a supported resourceType?
	    if ($ResourceType -eq "Microsoft.Compute/virtualMachines")
	    {
		    # This is an  Azure VM
		    Write-Verbose "This is an Azure VM." -Verbose
            
            # Call a function to perform the action
           Do-TheAction -SubId $SubscriptionId -storageAccountName $storageAccountName -BlobVHD $blobVHD
         
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
elseif ($SubscriptionId) {

    # Runbook being started by non-webhook method
    Write-Verbose "Runbook is being started by a method other than Azure alert." -Verbose

    # Call a function to perform the action
	Do-TheAction -SubId $SubscriptionId -StorageAccountName $StorageAccountName -BlobVHD $blobVHD
	
  
}
else {
    # Error
    Write-Error "You must start this runbook with an input value for the WebhookData parameter or with input values for all of the other parameters." 
}