 <#
.SYNOPSIS  
 BootStrap script for creating Azure RunAs Account and configuring post deployment activities

.DESCRIPTION  
 BootStrap script for creating Azure RunAs Account and configuring post deployment activities like 
 - create table storage
 - create automation account variables
 - delete keyvalut
 - delete credential asset variable
 - delete BootStrap runbook

.EXAMPLE  
.\BootstrapRunAs.ps1 

.DEPENDENCIES
  - Automation Credential asset variable "AzureCredentials". 

.NOTES
   AUTHOR: AOA Feature Team 
   LASTEDIT: 5-11-2018      
#>

function ValidateKeyVaultAndCreate([string] $keyVaultName, [string] $resourceGroup, [string] $KeyVaultLocation) 
{
   $GetKeyVault=Get-AzureRmKeyVault -VaultName $keyVaultName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
   if (!$GetKeyVault)
   {
     Write-Warning -Message "Key Vault $keyVaultName not found. Creating the Key Vault $keyVaultName"
     $keyValut=New-AzureRmKeyVault -VaultName $keyVaultName -ResourceGroupName $resourceGroup -Location $keyVaultLocation
     if (!$keyValut) {
       Write-Error -Message "Key Vault $keyVaultName creation failed. Please fix and continue"
       return
     }
     $uri = New-Object System.Uri($keyValut.VaultUri, $true)
     $hostName = $uri.Host
     Start-Sleep -s 15     
     # Note: This script will not delete the KeyVault created. If required, please delete the same manually.
   }
 }

function CreateSelfSignedCertificateClassic([string] $certificateName, [string] $selfSignedCertPlainPassword, [string] $certPath, [string] $certPathCer, [string] $selfSignedCertNoOfMonthsUntilExpired, [String] $SubId, [String] $SubName, $Cred ) 
{
    $Cert = New-SelfSignedCertificate -DnsName $certificateName -CertStoreLocation cert:\LocalMachine\My -KeyExportPolicy Exportable -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider" -NotAfter (Get-Date).AddMonths($selfSignedCertNoOfMonthsUntilExpired) -HashAlgorithm SHA256
    $CertPassword = ConvertTo-SecureString $selfSignedCertPlainPassword -AsPlainText -Force
    Export-PfxCertificate -Cert ("Cert:\localmachine\my\" + $Cert.Thumbprint) -FilePath $certPath -Password $CertPassword -Force | Write-Verbose
    Export-Certificate -Cert ("Cert:\localmachine\my\" + $Cert.Thumbprint) -FilePath $certPathCer -Type CERT | Write-Verbose

    Add-AzureAccount -Credential $Cred

    Select-AzureSubscription -Default -SubscriptionName $SubName

    [Xml]$requestPayloadFormat ='<SubscriptionCertificate xmlns="http://schemas.microsoft.com/windowsazure">
                    <SubscriptionCertificatePublicKey></SubscriptionCertificatePublicKey>
                    <SubscriptionCertificateThumbprint></SubscriptionCertificateThumbprint>
                    <SubscriptionCertificateData></SubscriptionCertificateData>
                </SubscriptionCertificate>'    
    
    #Acquire AAD token    
    $azureRmProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    $currentAzureContext = Get-AzureRmContext
    $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azureRmProfile)
    $token = $profileClient.AcquireAccessToken($currentAzureContext.Subscription.TenantId)
    
    $authHeader = @{
    'Content-Type'='application\json'
    'Authorization'="Bearer $($token.AccessToken)"
    'x-ms-version' = '2012-03-01'}
    $cert =  New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPathCer)
    
    $publicKey = [System.Convert]::ToBase64String($cert.GetPublicKey())
    $thumbprint = $cert.Thumbprint;
    $rawdata = [System.Convert]::ToBase64String($cert.RawData)

    $requestPayloadFormat.SubscriptionCertificate.SubscriptionCertificatePublicKey = $publicKey
    $requestPayloadFormat.SubscriptionCertificate.SubscriptionCertificateThumbprint = $thumbprint
    $requestPayloadFormat.SubscriptionCertificate.SubscriptionCertificateData = $rawdata
    
    $body =[string]:: Format( $requestPayloadFormat.OuterXml, $publicKey )
    $output =@()
    
    $Exists = $null
    Invoke-RestMethod -Uri "https://management.core.windows.net/${SubId}/certificates" -Headers $authHeader -Method POST -Body $body -ContentType 'Application/xml' -ErrorAction SilentlyContinue
}

 function CreateSelfSignedCertificate([string] $keyVaultName, [string] $certificateName, [string] $selfSignedCertPlainPassword,[string] $certPath, [string] $certPathCer, [string] $noOfMonthsUntilExpired ) 
{
   $certSubjectName="cn="+$certificateName

   $Policy = New-AzureKeyVaultCertificatePolicy -SecretContentType "application/x-pkcs12" -SubjectName $certSubjectName  -IssuerName "Self" -ValidityInMonths $noOfMonthsUntilExpired -ReuseKeyOnRenewal
   $AddAzureKeyVaultCertificateStatus = Add-AzureKeyVaultCertificate -VaultName $keyVaultName -Name $certificateName -CertificatePolicy $Policy 
  
   While($AddAzureKeyVaultCertificateStatus.Status -eq "inProgress")
   {
     Start-Sleep -s 10
     $AddAzureKeyVaultCertificateStatus = Get-AzureKeyVaultCertificateOperation -VaultName $keyVaultName -Name $certificateName
   }
 
   if($AddAzureKeyVaultCertificateStatus.Status -ne "completed")
   {
     Write-Error -Message "Key vault cert creation is not successful and its status is: $status.Status" 
   }

   $secretRetrieved = Get-AzureKeyVaultSecret -VaultName $keyVaultName -Name $certificateName
   $pfxBytes = [System.Convert]::FromBase64String($secretRetrieved.SecretValueText)
   $certCollection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
   $certCollection.Import($pfxBytes,$null,[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
   
   #Export  the .pfx file 
   $protectedCertificateBytes = $certCollection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $selfSignedCertPlainPassword)
   [System.IO.File]::WriteAllBytes($certPath, $protectedCertificateBytes)

   #Export the .cer file 
   $cert = Get-AzureKeyVaultCertificate -VaultName $keyVaultName -Name $certificateName
   $certBytes = $cert.Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
   [System.IO.File]::WriteAllBytes($certPathCer, $certBytes)

   # Delete the cert after downloading
   $RemoveAzureKeyVaultCertificateStatus = Remove-AzureKeyVaultCertificate -VaultName $keyVaultName -Name $certificateName -PassThru -Force -ErrorAction SilentlyContinue -Confirm:$false
 }

 function CreateServicePrincipal([System.Security.Cryptography.X509Certificates.X509Certificate2] $PfxCert, [string] $applicationDisplayName) {  
   
   $CurrentDate = Get-Date
   $keyValue = [System.Convert]::ToBase64String($PfxCert.GetRawCertData())
   $KeyId = [Guid]::NewGuid() 

   $KeyCredential = New-Object Microsoft.Azure.Graph.RBAC.Version1_6.ActiveDirectory.PSADKeyCredential  
   $KeyCredential.StartDate = $CurrentDate
   $KeyCredential.EndDate= [DateTime]$PfxCert.GetExpirationDateString()
   $KeyCredential.KeyId = $KeyId
   $KeyCredential.CertValue  = $keyValue

   # Use Key credentials and create AAD Application
   $Application = New-AzureRmADApplication -DisplayName $ApplicationDisplayName -HomePage ("http://" + $applicationDisplayName) -IdentifierUris ("http://" + $KeyId) -KeyCredentials $KeyCredential

   $ServicePrincipal = New-AzureRMADServicePrincipal -ApplicationId $Application.ApplicationId 
   $GetServicePrincipal = Get-AzureRmADServicePrincipal -ObjectId $ServicePrincipal.Id

   # Sleep here for a few seconds to allow the service principal application to become active (should only take a couple of seconds normally)
   Start-Sleep -s 15

   $NewRole = $null
   $Retries = 0;
   While ($NewRole -eq $null -and $Retries -le 6)
   {
      New-AzureRMRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName $Application.ApplicationId | Write-Verbose -ErrorAction SilentlyContinue
      Start-Sleep -s 10
      $NewRole = Get-AzureRMRoleAssignment -ServicePrincipalName $Application.ApplicationId -ErrorAction SilentlyContinue
      $Retries++;
   }

   return $Application.ApplicationId.ToString();
 }

 function CreateAutomationCertificateAsset ([string] $resourceGroup, [string] $automationAccountName, [string] $certifcateAssetName,[string] $certPath, [string] $certPlainPassword, [Boolean] $Exportable) {
   $CertPassword = ConvertTo-SecureString $certPlainPassword -AsPlainText -Force   
   Remove-AzureRmAutomationCertificate -ResourceGroupName $resourceGroup -automationAccountName $automationAccountName -Name $certifcateAssetName -ErrorAction SilentlyContinue
   New-AzureRmAutomationCertificate -ResourceGroupName $resourceGroup -automationAccountName $automationAccountName -Path $certPath -Name $certifcateAssetName -Password $CertPassword -Exportable:$Exportable  | write-verbose
 }

 function CreateAutomationConnectionAsset ([string] $resourceGroup, [string] $automationAccountName, [string] $connectionAssetName, [string] $connectionTypeName, [System.Collections.Hashtable] $connectionFieldValues ) {
   Remove-AzureRmAutomationConnection -ResourceGroupName $resourceGroup -automationAccountName $automationAccountName -Name $connectionAssetName -Force -ErrorAction SilentlyContinue
   New-AzureRmAutomationConnection -ResourceGroupName $ResourceGroup -automationAccountName $automationAccountName -Name $connectionAssetName -ConnectionTypeName $connectionTypeName -ConnectionFieldValues $connectionFieldValues 
 }
 

 try
 {
	Start-Sleep (Get-Random -Maximum 15 -Minimum 1)

    [String]$aroBootstrapStatus = Get-AutomationVariable -Name 'Internal_BootStrapRunbookCompleted'

    if($aroBootstrapStatus.ToLower() -eq "false")
    {
        #Set the bootstrap flag to true which means bootstrap execution started. This will help to avoid the execution twice.
        Set-AutomationVariable -Name 'Internal_BootStrapRunbookCompleted' -Value "true"

        Write-Output "Bootstrap RunAs script execution started..."

        $servicePrincipalConnection=Get-AutomationConnection -Name 'AzureRunAsConnection' -ErrorAction SilentlyContinue

        #---------Inputs variables for bootstrap script--------------
	    $SubscriptionId = Get-AutomationVariable -Name 'Internal_AzureSubscriptionId'
        $AutomationAccountName = Get-AutomationVariable -Name 'Internal_AutomationAccountName'
        $aroResourceGroupName = Get-AutomationVariable -Name 'Internal_ResourceGroupName'
    
        #-----L O G I N - A U T H E N T I C A T I O N-----

        if ($servicePrincipalConnection -eq $null)
        {
            Write-Output "Reading the credentials..."

            #---------Read the Credentials variable---------------
            $myCredential = Get-AutomationPSCredential -Name 'AzureCredentials'  
            $AzureLoginUserName = $myCredential.UserName
            $securePassword = $myCredential.Password
            $AzureLoginPassword = $myCredential.GetNetworkCredential().Password
    
            #++++++++++++++++++++++++STEP 1 execution starts++++++++++++++++++++++++++
    
            #In Step 1 we are creating keyvault to generate cert and creating runas account...

            try
             {
                Write-Output "Starting Step-1 : Creation of RunAs account..."

                Write-Output "Logging into Azure Subscription..."
    
                #-----L O G I N - A U T H E N T I C A T I O N-----
                $secPassword = ConvertTo-SecureString $AzureLoginPassword -AsPlainText -Force
                $AzureOrgIdCredential = New-Object System.Management.Automation.PSCredential($AzureLoginUserName, $secPassword)
                Login-AzureRmAccount -Credential $AzureOrgIdCredential
                Get-AzureRmSubscription -SubscriptionId $SubscriptionId | Select-AzureRmSubscription
            
			    Write-Output "Successfully logged into Azure Subscription..."

                [String] $ApplicationDisplayName="$($automationAccountName)App1"
                [Boolean] $CreateClassicRunAsAccount=$false
                [String] $SelfSignedCertPlainPassword = [Guid]::NewGuid().ToString().Substring(0,8)+"!" 
                [String] $KeyVaultName="KeyVault"+ [Guid]::NewGuid().ToString().Substring(0,5)        
                [int] $NoOfMonthsUntilExpired = 36
    
                $RG = Get-AzureRmResourceGroup -Name $aroResourceGroupName 
                $KeyVaultLocation = $RG[0].Location
 
                # Create Run As Account using Service Principal
                $CertifcateAssetName = "AzureRunAsCertificate"
                $ConnectionAssetName = "AzureRunAsConnection"
                $ConnectionTypeName = "AzureServicePrincipal"
 
			    Write-Output "RunAs Account (ARM) Creation Started..."

                Write-Output "Creating Key vault for generating cert..."
            
			    ValidateKeyVaultAndCreate $KeyVaultName $aroResourceGroupName $KeyVaultLocation

                $CertificateName = $automationAccountName+$CertifcateAssetName
                $PfxCertPathForRunAsAccount = Join-Path $env:TEMP ($CertificateName + ".pfx")
                $PfxCertPlainPasswordForRunAsAccount = $SelfSignedCertPlainPassword
                $CerCertPathForRunAsAccount = Join-Path $env:TEMP ($CertificateName + ".cer")

                Write-Output "Generating the cert using Key vault..."
                CreateSelfSignedCertificate $KeyVaultName $CertificateName $PfxCertPlainPasswordForRunAsAccount $PfxCertPathForRunAsAccount $CerCertPathForRunAsAccount $NoOfMonthsUntilExpired


                Write-Output "Creating service principal..."
                # Create Service Principal
                $PfxCert = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @($PfxCertPathForRunAsAccount, $PfxCertPlainPasswordForRunAsAccount)
                $ApplicationId=CreateServicePrincipal $PfxCert $ApplicationDisplayName

                Write-Output "Creating Certificate in the Asset..."
                # Create the automation certificate asset
                CreateAutomationCertificateAsset $aroResourceGroupName $automationAccountName $CertifcateAssetName $PfxCertPathForRunAsAccount $PfxCertPlainPasswordForRunAsAccount $true

                # Populate the ConnectionFieldValues
                $SubscriptionInfo = Get-AzureRmSubscription -SubscriptionId $SubscriptionId
                $TenantID = $SubscriptionInfo | Select-Object TenantId -First 1
                $Thumbprint = $PfxCert.Thumbprint
                $ConnectionFieldValues = @{"ApplicationId" = $ApplicationId; "TenantId" = $TenantID.TenantId; "CertificateThumbprint" = $Thumbprint; "SubscriptionId" = $SubscriptionId} 

                Write-Output "Creating Connection in the Asset..."
                # Create a Automation connection asset named AzureRunAsConnection in the Automation account. This connection uses the service principal.
                CreateAutomationConnectionAsset $aroResourceGroupName $automationAccountName $ConnectionAssetName $ConnectionTypeName $ConnectionFieldValues

                Write-Output "RunAs Account (ARM) Creation Completed..."

                <#
                Write-Output "RunAsAccount (Classic) Creation Started..."

                $SubscriptionName = $SubscriptionInfo.Name

                #For Classic RunAs
                $ClassicRunAsAccountCertifcateAssetName = "AzureClassicRunAsCertificate"
                $ClassicRunAsAccountConnectionAssetName = "AzureClassicRunAsConnection"
                $ClassicRunAsAccountConnectionTypeName = "AzureClassicCertificate "

                [String] $SelfSignedCertPlainPassword = [Guid]::NewGuid().ToString().Substring(0,8)+"!" 

                $ClassicRunAsAccountCertificateName = $automationAccountName + $ClassicRunAsAccountCertifcateAssetName
                $PfxCertPathForClassicRunAsAccount = Join-Path $env:TEMP ($ClassicRunAsAccountCertificateName + ".pfx")
                $PfxCertPlainPasswordForClassicRunAsAccount = $SelfSignedCertPlainPassword
                $CerCertPathForClassicRunAsAccount = Join-Path $env:TEMP ($ClassicRunAsAccountCertificateName + ".cer")
        
                Write-Output "Generating the cert using Key vault for classic..."
                CreateSelfSignedCertificateClassic $ClassicRunAsAccountCertificateName $PfxCertPlainPasswordForClassicRunAsAccount $PfxCertPathForClassicRunAsAccount $CerCertPathForClassicRunAsAccount $NoOfMonthsUntilExpired $SubscriptionId $SubscriptionName $AzureOrgIdCredential

			    Write-Output "Creating Certificate in the Asset for classic..."
                # Create the automation certificate asset
                CreateAutomationCertificateAsset $aroResourceGroupName $automationAccountName $ClassicRunAsAccountCertifcateAssetName $PfxCertPathForClassicRunAsAccount $PfxCertPlainPasswordForClassicRunAsAccount $false

                Write-Output "Creating Connection in the Asset for classic..."
                # Populate the ConnectionFieldValues
                $ClassicRunAsAccountConnectionFieldValues = @{"SubscriptionName" = $SubscriptionInfo.Name; "SubscriptionId" = $SubscriptionId; "CertificateAssetName" = $ClassicRunAsAccountCertifcateAssetName}

                # Create a Automation connection asset named AzureRunAsConnection in the Automation account. This connection uses the service principal.
                CreateAutomationConnectionAsset $aroResourceGroupName $automationAccountName $ClassicRunAsAccountConnectionAssetName $ClassicRunAsAccountConnectionTypeName $ClassicRunAsAccountConnectionFieldValues

                Write-Output "RunAsAccount (Classic) Creation Completed..."
                #>

                Write-Output "Completed Step-1 : Creation of RunAs Account..."
            
             }
             catch
             {
                Write-Output "Error Occurred on Step-1..."   
                Write-Output $_.Exception
                Write-Error $_.Exception
                exit
             }
             #++++++++++++++++++++++++STEP 1 execution ends++++++++++++++++++++++++++

             #=======================STEP 2 execution starts===========================

             Write-Output "Starting Step-2 : Creation of new table storage for storing scheduled/ondemand job outputs..."
             try
             {
                [String]$StorageAccountName = Get-AutomationVariable -Name 'Internal_StorageAccountName'
                [String]$tableStorageRG = Get-AutomationVariable -Name 'Internal_ResourceGroupName'
                [String]$storageTableforScheduleJob = "ScheduleExecutionHistory"
                [String]$storageTableforOnDemandJob = "OnDemandExecutionHistory"

                #Get the storage context
                Write-Output "Get the storage context..."
                $storageContext = (Get-AzureRmStorageAccount -ResourceGroupName $tableStorageRG -Name $StorageAccountName).Context

                #Store the connection string value in the automation account variable
                $connectionStringName = "Internal_StorageAccountConnectionString"

                $AccountKey = (Get-AzureRMStorageAccountKey -ResourceGroupName $aroResourceGroupName -Name $StorageAccountName).Value[0]

                $connectionStringValue = "DefaultEndpointsProtocol=https;AccountName=" + $storageContext.StorageAccountName + ";AccountKey=" + $AccountKey + ";EndpointSuffix=" + $storageContext.EndPointSuffix

                New-AzureRmAutomationVariable -automationAccountName $automationAccountName -Name $connectionStringName -ResourceGroupName $aroResourceGroupName -Encrypted $False -Value $connectionStringValue

                #Create the new tables
                Write-Output "Create the new table storage..."

                $chkTable = Get-AzureStorageTable -Name $storageTableforScheduleJob -Context $storageContext -ErrorAction SilentlyContinue

                if($chkTable -eq $null)
                {
                    $newtblforschedule = New-AzureStorageTable -Name $storageTableforScheduleJob -Context $storageContext
                    if($newtblforschedule.Name)
                    {
                        Write-Output "$($storageTableforScheduleJob) table created successfully..."
                    }
                }
                else
                {
                    Write-Output "Table $($storageTableforScheduleJob) already exist..."
                }
                $chkTable = ""
                $chkTable = Get-AzureStorageTable -Name $storageTableforOnDemandJob -Context $storageContext -ErrorAction SilentlyContinue
                if($chkTable -eq $null)
                {
                    $newtblforondemand = New-AzureStorageTable -Name $storageTableforOnDemandJob -Context $storageContext
                    if($newtblforondemand.Name)
                    {
                        Write-Output "$($storageTableforOnDemandJob) table created successfully..."
                    }
                }
                else
                {
                    Write-Output "Table $($storageTableforOnDemandJob) already exist..."
                }

                #Store the storage table names in the automation account variable
                $scheduleStorageTableName = "Internal_ScheduleTableStorageName"
                $ondemandStorageTableName = "Internal_OnDemandTableStorageName"

                New-AzureRmAutomationVariable -automationAccountName $automationAccountName -Name $scheduleStorageTableName -ResourceGroupName $aroResourceGroupName -Encrypted $False -Value $storageTableforScheduleJob

                New-AzureRmAutomationVariable -automationAccountName $automationAccountName -Name $ondemandStorageTableName -ResourceGroupName $aroResourceGroupName -Encrypted $False -Value $storageTableforOnDemandJob

                Write-Output "Completed Step-2..."

             }
             catch
             {
                Write-Output "Error Occurred on Step-2..."   
                Write-Output $_.Exception
                Write-Error $_.Exception
                exit
             }
             #=======================STEP 2 execution ends=============================

            #*******************STEP 3 execution starts********************************************

            #In Step 3 we are deleting the bootstrap script, Credential asset variable, and Keyvault...
            try
            {

                Write-Output "Executing Step-3 : Performing clean-up tasks (Bootstrap script, Bootstrap Schedule, Credential asset variable, and Keyvault) ..."

                if($KeyVaultName -ne $null)
                {
                    Write-Output "Removing the key vault : ($($KeyVaultName))..."

                    Remove-AzureRmKeyVault -VaultName $KeyVaultName -ResourceGroupName $aroResourceGroupName -Confirm:$False -Force
                }
        
                $checkCredentials = Get-AzureRmAutomationCredential -Name "AzureCredentials" -automationAccountName $automationAccountName -ResourceGroupName $aroResourceGroupName -ErrorAction SilentlyContinue
        
                if($checkCredentials -ne $null)
                {
                    Write-Output "Removing the Azure Credentials..."

                    Remove-AzureRmAutomationCredential -Name "AzureCredentials" -automationAccountName $automationAccountName -ResourceGroupName $aroResourceGroupName 
                }

                Write-Output "Removing Bootstrap Runbook..."  
		
		        #Remove-AzureRmAutomationRunbook -Name "BootStrap" -ResourceGroupName $aroResourceGroupName -automationAccountName $automationAccountName -Force

                Write-Output "Completed Step-3 ..."
            }
            catch
            {
                Write-Output "Error Occurred in Step-3..."   
                Write-Output $_.Exception
                Write-Error $_.Exception        
            }

            #*******************STEP 3 execution ends**********************************************

        }
        else
        {
            Write-Output "AzureRunAsConnection is missing..."
            exit
        }
    
    }
    else
    {
        Write-Output "You are attempting to re-run the boostrap script. Your bootstrap script might be currently running or completed recently. Please check the previous job status..."
    }
 }
 catch
 {
    Write-Output "Error Occurred..."   
    Write-Output $_.Exception

 }