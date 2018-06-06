<#
.SYNOPSIS  
 Wrapper script for start & stop Classic VM's
.DESCRIPTION  
 Wrapper script for start & stop Classic VM's
.EXAMPLE  
.\ScheduledStartStop_Child_Classic.ps1 -VMName "Value1" -Action "Value2" -ResourceGroupName "Value3" 
Version History  
v1.0   - Initial Release  
#>
param(
[string]$VMName = $(throw "Value for VMName is missing"),
[String]$Action = $(throw "Value for Action is missing"),
[String]$ResourceGroupName = $(throw "Value for ResourceGroupName is missing")
)

#----------------------------------------------------------------------------------
#---------------------LOGIN TO AZURE AND SELECT THE SUBSCRIPTION-------------------
#----------------------------------------------------------------------------------
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

try
{          
    Write-Output "VM action is : $($Action)"
    
	$currentVM = Get-AzureVM | where Name -Like $VMName
	if ($currentVM.Count -ge 1)
	{	
		if ($Action.Trim().ToLower() -eq "stop")
		{
			Write-Verbose "Stopping VM $($vm.Name) using Classic"
			$Status = Stop-AzureVM -Name $currentVM.Name -ServiceName $currentVM.ServiceName -Force
			if ($Status.OperationStatus -ne 'Succeeded') 
			{ 
				# The VM failed to stop, so send notice 
				Write-Output ($currentVM.Name + " failed to stop") 
			} 
			else 
			{ 
				# The VM stopped, so send notice 
				Write-Output ($currentVM.Name + " has been stopped") 
			} 
		}
		elseif($Action.Trim().ToLower() -eq "start")
		{
			Write-Verbose "Starting VM $($currentVM.Name) using Classic"
			$Status = Start-AzureVM -Name $currentVM.Name -ServiceName $currentVM.ServiceName
			if ($Status.OperationStatus -ne 'Succeeded') 
			{ 
				# The VM failed to start, so send notice 
				Write-Output ($currentVM.Name + " failed to start") 
			} 
			else 
			{ 
				# The VM started, so send notice 
				Write-Output ($currentVM.Name + " has been started") 
			} 
		}
	}
    else
	{
		Write-Error "Error: No VM instance with name $($vm.Name) found"
	}
}
catch
{
    Write-Output "Error Occurred..."
    Write-Output $_.Exception
}



