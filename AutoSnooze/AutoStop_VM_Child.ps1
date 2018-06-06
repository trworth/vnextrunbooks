<#
.SYNOPSIS  
 Script for deleting the resource groups
.DESCRIPTION  
 Script for deleting the resource groups
.EXAMPLE  
.\AutoStop_VM_Child.ps1 
Version History  
v1.0   - redmond\balas - Initial Release  
#>

param ( 
    [object]$WebhookData
)

$isSendMail = Get-AutomationVariable -Name 'External_IsSendEmail'

function sendEmail($VMName,$ResourceGroup)
{
    Write-Output "Sending email with details on VM action"
    $sendGridUsername = $sendGridResource.Properties.username
    $sendGridPassword = Get-AutomationVariable -Name 'Internal_SendGridPassword'
    $sendGridEmailFrom = Get-AutomationVariable -Name 'External_EmailFromAddress'
    $sendGridEmailTo = Get-AutomationVariable -Name 'External_EmailToAddress'
    $sendGridEmailSubject = Get-AutomationVariable -Name 'External_EmailSubject'
    $sendGridAccountName = Get-AutomationVariable -Name 'Internal_SendGridAccountName'
    try
    {
        $sendGridResource = Find-AzureRmResource -ResourceType "Sendgrid.Email/accounts" -ResourceNameContains $sendGridAccountName -ExpandProperties
        $sendGridUsername = $sendGridResource.Properties.username
        $SMTPServer = $sendGridResource.Properties.smtpServer

        $securedPassword=$sendGridPassword|ConvertTo-SecureString -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential $sendGridUsername, $securedPassword

		[string[]]$EmailToList = $sendGridEmailTo -split ","

        $Body = "The following VM has been stopped  -  $($VMName) in the resource group - $($ResourceGroup) "

		$Body += "<p style='font-family:Tahoma; font-size: 14px;'>Documentation : <a href='https://aka.ms/startstopvms'>Start/Stop VMs during off-hours</a><br/>"

        Send-MailMessage -smtpServer $SMTPServer -Credential $credential -Usessl -Port 587 -from $sendGridEmailFrom -to $EmailToList -subject $sendGridEmailSubject -Body $Body -BodyAsHtml
        Write-Output "Email sent succesfully." 
    }
    catch
    {
        $ex = $_.Exception
        Write-Output $_.Exception
    }

}

if ($WebhookData -ne $null) {  
    # Collect properties of WebhookData.
    $WebhookName    =   $WebhookData.WebhookName
    $WebhookBody    =   $WebhookData.RequestBody
    $WebhookHeaders =   $WebhookData.RequestHeader
       
    # Information on the webhook name that called This
    Write-Output "This runbook was started from webhook $WebhookName."
       
    # Obtain the WebhookBody containing the AlertContext
    $WebhookBody = (ConvertFrom-Json -InputObject $WebhookBody)
    Write-Output "`nWEBHOOK BODY"
    Write-Output "============="
    Write-Output $WebhookBody
       
    # Obtain the AlertContext
    $AlertContext = [object]$WebhookBody.context

    # Some selected AlertContext information
    Write-Output "`nALERT CONTEXT DATA"
    Write-Output "==================="
    Write-Output $AlertContext.name
    Write-Output $AlertContext.subscriptionId
    Write-Output $AlertContext.resourceGroupName
    Write-Output $AlertContext.resourceName
    Write-Output $AlertContext.resourceType
    Write-Output $AlertContext.resourceId
    Write-Output $AlertContext.timestamp
      
    $connectionName = "AzureRunAsConnection"
    try
    {
        # Get the connection "AzureRunAsConnection "
        $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

        "Logging in to Azure..."
        Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
    }
    catch 
    {
        if (!$servicePrincipalConnection)
        {
            $ErrorMessage = "Connection $connectionName not found."
            throw $ErrorMessage
        } else{
            Write-Error -Message $_.Exception
            throw $_.Exception
        }
    }
	
	#
	# Initialize the Azure subscription we will be working against for Classic Azure resources
	#
	Write-Verbose "Authenticating Classic RunAs account"
	$ConnectionAssetName = "AzureClassicRunAsConnection"
	$connection = Get-AutomationConnection -Name $connectionAssetName        
	Write-Verbose "Get connection asset: $ConnectionAssetName" -Verbose
	$Conn = Get-AutomationConnection -Name $ConnectionAssetName
	if ($Conn -eq $null)
	{
		throw "Could not retrieve connection asset: $ConnectionAssetName. Make sure that this asset exists in the Automation account."
	}
	$CertificateAssetName = $Conn.CertificateAssetName
	Write-Verbose "Getting the certificate: $CertificateAssetName" -Verbose
	$AzureCert = Get-AutomationCertificate -Name $CertificateAssetName
	if ($AzureCert -eq $null)
	{
		throw "Could not retrieve certificate asset: $CertificateAssetName. Make sure that this asset exists in the Automation account."
	}
	Write-Verbose "Authenticating to Azure with certificate." -Verbose
	Set-AzureSubscription -SubscriptionName $Conn.SubscriptionName -SubscriptionId $Conn.SubscriptionID -Certificate $AzureCert 
	Select-AzureSubscription -SubscriptionId $Conn.SubscriptionID
	
	if($AlertContext.resourceType -eq "microsoft.classiccompute/virtualmachines")
	{
		$currentVM = Get-AzureVM | where Name -Like $AlertContext.resourceName
		if ($currentVM.Count -ge 1)
		{	
			Write-Verbose "Stopping VM $($vm.Name) using Classic"
			$Status = Stop-AzureVM -Name $currentVM.Name -ServiceName $currentVM.ServiceName -Force			
		}
	}
    else 
	{
		Write-Verbose "Stopping VM $($vm.Name) using Resource Manager"
		$Status = Stop-AzureRmVM -Name $AlertContext.resourceName -ResourceGroupName $AlertContext.resourceGroupName -Force
	}
    
    
    if($Status -eq $null)
    {
        Write-Output "Error occured while stopping the Virtual Machine. $AlertContext.resourceName"
    }
    else
    {
       Write-Output "Successfully stopped the VM $AlertContext.resourceName"
       if ($isSendMail.ToLower() -eq 'yes')
       {
           sendEmail -VMName $AlertContext.resourceName -ResourceGroup $AlertContext.resourceGroupName
        }
    }
}
else 
{
    Write-Error "This runbook is meant to only be started from a webhook." 
}
