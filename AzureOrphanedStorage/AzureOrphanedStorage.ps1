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

.PARAMETER ExcludedStorageAccounts
   Optional
   A CSV list of StorageAccounts to Exclude.

.PARAMETER ExcludedResourceGroups
   Optional
   A CSV list of ResourceGroups to Exclude.

.PARAMETER MinimumDaysBeforeDelete
   Optional
   Minimum Age before VHD is deleted

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
        [String] $ExcludedStorageAccounts,
	[Parameter (Mandatory=$false)]
        [String] $ExcludedResourceGroups,
    [Parameter (Mandatory=$false)]
        [int] $MinimumDaysBeforeDelete,
	[Parameter (Mandatory=$false)]
        [object] $WebhookData
)

$ErrorActionPreference = "SilentlyContinue"
        
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

function Do-TheAction
{
    param 
    (
        [Parameter (Mandatory=$true)]
            [string] $SubId,
        [Parameter (Mandatory=$false)]
             [String[]]$ExcludedStorageAccount,    
        [Parameter (Mandatory=$false)]
            [String[]] $ExcludedResourceGroup,  
        [Parameter (Mandatory=$false)]
            [int] $MinimumDaysBeforeDelete
    )
    Write-Verbose "Subscription Id: $SubId" -Verbose
     # Authenticate
    $CurrentContext = AuthenticateTo-Azure -SubId $SubId
   
    $Report = Get-TheData -SubId $SubId -ExcludedStorageAccount $ExcludedStorageAccount -ExcludedResourceGroup $ExcludedResourceGroup -MinimumDaysBeforeDelete $MinimumDaysBeforeDelete

    $report | %{
        if($_.LastWriteDays -ge $MinimumDaysBeforeDelete -and $_.LeaseStatus -ne 'Locked') {$_.Recommendation='Recommend deleting UnAttached VHD Blob'}
    }
    
    $Report | %{write-output $($_ | convertto-json)}
}

function Get-TheData
{
param 
    (
        [Parameter (Mandatory=$true)]
            [string] $SubId,
        [Parameter (Mandatory=$false)]
             [String[]]$ExcludedStorageAccount,    
        [Parameter (Mandatory=$false)]
             [String[]] $ExcludedResourceGroup,
        [Parameter (Mandatory=$false)]
            [int] $MinimumDaysBeforeDelete
        
    )
        $CurrentContext = Set-AzureRmContext -SubscriptionId $SubId -ErrorAction Stop

        Write-verbose "Retrieving Storage Accounts" -verbose

        $Data = @{}
        $StorageAccounts = @(Get-AzureRmStorageAccount  | ?{$_.StorageAccountName -notin @($ExcludedStorageAccount)})
    
        Write-verbose "Scanning for orphaned vhds in $($StorageAccounts.Count) storage accounts" -Verbose
        Foreach ($StorageAccount in $StorageAccounts) {
    
			try{
				$ResourceGroup = $StorageAccount.id.split('/')[4]

				$StorageAccountContainers = @(Get-AzureStorageContainer -Context $($StorageAccount.Context) )
                   
				Foreach ($StorageAccountContainer in $StorageAccountContainers) {
				                
					Foreach ($blob in @(Get-AzureStorageBlob -Container $($StorageAccountContainer.Name) -Context $($StorageAccount.Context) -Blob "*.vhd" -errorAction SilentlyContinue))
					{ 
        
						IF ($blob.BlobType -eq "PageBlob") {

						 Write-verbose "........$($ResourceGroup)/$($StorageAccount.StorageAccountName)/$($StorageAccountContainer.Name)/$($blob.Name)" -Verbose

						#Get Last time Touched
						$ModifiedLocal =$blob.lastmodified.localdatetime
						$Now = [datetime]::Now
						if ($ModifiedLocal) { $Days = (New-TimeSpan -Start $ModifiedLocal -End $Now).Days; $ModifiedLocalTime = $ModifiedLocal.ToString('MM/dd/yyyy HH:mm')}
						else {$Days = "CouldNotDetermine"; $ModifiedLocalTime = "CouldNotDetermine"}

						$blobSizeInBytes  = 0
						if ($Blob.BlobType -eq [Microsoft.WindowsAzure.Storage.Blob.BlobType]::BlockBlob) {
							$blobSizeInBytes += 8
							$Blob.ICloudBlob.DownloadBlockList() | 
							ForEach-Object { $blobSizeInBytes += $_.Length + $_.Name.Length }
								$blobSizeInBytes = "{0:N2}" -f ($blobSizeInBytes/1gb)
						} else {
							$Blob.ICloudBlob.GetPageRanges() | 
								ForEach-Object { $blobSizeInBytes += 12 + $_.EndOffset - $_.StartOffset }
								$blobSizeInBytes = "{0:N2}" -f ($blobSizeInBytes/1gb)
						}

						$ResourceURI = $($($StorageAccountContainer.CloudBlobContainer.Uri.AbsoluteUri) +'/'+ $($blob.Name))   
						$ResourceID =  $($StorageAccountContainer.CloudBlobContainer.Uri.AbsoluteUri)                                                                
						$resourceKey = $ResourceID.Replace('https://','')

						$data."$resourceKey" = [PSCustomObject]@{
                                                SubscriptionID = $Subid
                                                ResourceGroup = $ResourceGroup
												ResourceURI = $($ResourceURI)
												StorageAccount = $StorageAccount.StorageAccountName 
												Container = $StorageAccountContainer.Name
												vhd = $blob.Name
												SizeGB = [Math]::Round($blob.length /1GB,0)
												UsedGB = $blobSizeInBytes
												Sku = "[$($StorageAccount.Sku.Name)] $($StorageAccount.Sku.Tier)"
												VMName = '' 
												Disk = $diskName
												LastModified = $blob.LastModified.ToString()
												LastWriteDays  = $Days
												LeaseStatus = $($blob.ICloudBlob.Properties.LeaseStatus)
												Recommendation = 'Not Attached'
												}
                        
                        
                        
                        
						}
					}
				}

			} catch{write-verbose "$($StorageAccount.StorageAccountName) failed: $($_.Exception.Message)" -verbose}
        }
   
        Write-verbose "Building data for Orphaned Disks for classic" -Verbose
        $orphanedClassicVHDs = Get-AzureDisk | Where-Object {$_.AttachedTo –eq $null}
        Foreach($classicDisk in $orphanedClassicVHDs) {
                    
            $StorageAccountName = $($classicDisk.MediaLink.Host.split(".")[0])
            $StorageAccount = (Get-AzureStorageAccount | Where-Object{$_.StorageAccountName -match $StorageAccountName})
        
            if($StorageAccount) {
                $ResourceGroup = $StorageAccount.id.split('/')[4]
                $blob = Get-AzureStorageBlob  -Container $($classicDisk.MediaLink.localPath.split('/')[1])  -Blob $($classicDisk.medialink.segments[2]) -Context $StorageAccount.Context -errorAction SilentlyContinue
                                        
                $ResourceURI = $($($classicDisk.MediaLink.AbsoluteUri))      
                $ResourceID = $($classicDisk.MediaLink.AbsoluteUri)                                                           
                $resourceKey = $ResourceID.Replace('https://','')

                Write-verbose "........$($ResourceGroup)/$($StorageAccount.StorageAccountName)/$($StorageAccountContainer.Name)/$($blob.Name)" -Verbose

                $data."$resourceKey" = [PSCustomObject]@{
                                    SubscriptionID = $Subid
                                    ResourceGroup = $ResourceGroup
                                    ResourceURI = $($ResourceURI)
                                    StorageAccount = $($StorageAccount.StorageAccountName)
                                    Container = $($classicDisk.MediaLink.localPath.split('/')[1])
                                    vhd = $($classicDisk.medialink.segments[2])
                                    SizeGB = $([Math]::Round($blob.length /1GB,0))
                                    UsedGB = $blobSizeInBytes
                                    Sku = $("[$($StorageAccount.Sku.Name)] $($StorageAccount.Sku.Tier)")
                                    VMName = '' 
                                    Disk =  $($classicDisk.DiskName)
                                    LastModified = $($blob.LastModified.ToString())
                                    LastWriteDays  = $Days
                                    LeaseStatus = $($blob.ICloudBlob.Properties.LeaseStatus) 
                                    Recommendation = 'Not Attached'
                }
            }
        }
        
        Write-verbose "Building data for Orphaned Managed Disks for ARM" -Verbose
        $orphanedARMVHDs = Get-AzureRMDisk| Where {$_.OwnerId -eq $null -and $_.ManagedBy -eq $null}
        Foreach($ArmDisk in $orphanedARMVHDs) {
        
            $StorageAccountName = "ManagedDisk"
            $StorageAccount = (Get-AzureStorageAccount | Where-Object{$_.StorageAccountName -match $StorageAccountName})

            $ResourceID = $($ArmDisk.id)                                                           
            $resourceKey = $ResourceID
            $ResourceGroup = $ArmDisk.Id.Split('/')[4]

            Write-verbose "........$($ResourceGroup)/$($StorageAccount.StorageAccountName)/$($StorageAccountContainer.Name)/$($blob.Name)" -Verbose

            $data."$resourceKey" = [PSCustomObject]@{
                                SubscriptionID = $Subid
                                ResourceGroup = $ResourceGroup
                                ResourceURI = $($ResourceID)
                                StorageAccount = 'ManagedDisk'
                                Container = 'DIsks'                                
                                vhd = $($ArmDisk.Name)
                                SizeGB = $($ArmDisk.DiskSizeGB)
                                UsedGB = 'NA'
                                Sku = $("[$($ArmDisk.Sku.Name)] $($ArmDisk.Sku.Tier)")
                                VMName = '' 
                                Disk =  $($ArmDisk.Name)
                                LastModified = $($ArmDisk.TimeCreated.ToString())
                                LastWriteDays  = 'NA'
                                LeaseStatus = $($blob.ICloudBlob.Properties.LeaseStatus) 
                                Recommendation = 'Not Attached'
                                }

        }

    Write-verbose "Retrieving all VM's" -Verbose

    # Updates servername on $data.[blob Name] 
    $allVMS = @(Get-AzureRMVM -WarningAction SilentlyContinue )
    foreach ($VM in $allVMS)
    {
        $ErrorActionPreference = 'SilentlyContinue'
        $disks = [System.Collections.ArrayList]::new() 
        $disks.add($vm.StorageProfile.OsDisk.vhd.uri.Replace('%7B','{').replace('%7D','}')) | Out-Null
        $vm.StorageProfile.DataDisks.vhd.uri | %{$disks.Add("$($_.Replace('%7B','{').replace('%7D','}'))")} | Out-Null
        $disk = [System.Collections.ArrayList]::new()
        $disks |  %{ if (($_ -Split '/')[-1] -ne ''){$Data."$(($_ -Split '/')[-1])".VMName = $VM.Name} }
    }

    Write-verbose "Linking $data to virtual machine" -Verbose
        $returnInfo= ($data.Keys | %{$data.$_ } | Sort-Object -Property VMName,LastModified | Select SubscriptionID,ResourceGroup,ResourceURI,StorageAccount,Container,vhd,SizeGB,UsedGB,Sku,VMName,Disk,LastModified,LastWriteDays,LeaseStatus,Recommendation)          
   
 
   Return $($ReturnInfo)
}


$ExcludedStorageAccount = $ExcludedStorageAccounts.split(',')
$ExcludedResourceGroup = $ExcludedResourceGroups.split(',')
$VirtualMachines = $VirtualMachinesToInclude.split(',')

# Call a function to perform the action
	
Do-TheAction -SubId $SubscriptionId -ExcludedStorageAccount $ExcludedStorageAccount -ExcludedResourceGroup $ExcludedResourceGroup -MinimumDaysBeforeDelete $MinimumDaysBeforeDelete