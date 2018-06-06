<#
.SYNOPSIS  
	 Parent Runbook to start/stop the VM's based on the user request and then call the Start or Stop runbook

.DESCRIPTION  
	 This runbook is intended to start/stop VMs (both classic and ARM based VMs) that resides in a given list of Azure resource group(s). 
		
	 This runbook requires the Azure Automation Run-As (Service Principle) account, which must be added when creating the Azure Automation account.

.EXAMPLE  
	.\ScheduledStartStop_Parent_vNext.ps1 -Resources "ResourcesJSON" -WhatIf "False"
    $ResourcesJSON = '{
    "ScheduleName" : "TestSchedule",
    "Action" : "start",
    "Resources" : [
    "subscriptions/-xxxx-xxxx-xxxx-/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1",
    "subscriptions/-xxxx-xxxx-xxxx-/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm2",
    "subscriptions/-xxxx-xxxx-xxxx-/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm3",
    "subscriptions/-xxxx-xxxx-xxxx-/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm4"
    ]
 }'

.DEPENDENCIES
  - An Automation connection asset called "AzureRunAsConnection" that is of type AzureRunAsConnection.  
  - An Automation certificate asset called "AzureRunAsCertificate". 

.PARAMETER ResourcesJSON
   Mandatory
   User input the resources to take action as JSON format.

.PARAMETER WhatIf
   Optional
   If user want to check the expected action on execution this runbook against the needed resources.

.PARAMETER  
    Parameters are read in from Azure Automation variables.
      
    Variables (ReadOnly):
    -  Internal_AutomationAccountName           :  Contains Automation Account name.
    -  Internal_ResourceGroupName               :  Resource group name for Automation Account.
    -  Internal_StorageAccountName              :  Storage Account name for storing the execution data. 
    -  Internal_StorageAccountResourceGroupName :  Resource group name for the storage account.
    -  Internal_TableStorageName                :  Table storage inside the storage account to store all the parent and child jobs.

.NOTES
   AUTHOR: AOA Feature Team 
   LASTEDIT: 5-11-2018
        
#>

Param(
[Parameter(Mandatory=$false,HelpMessage="Enter the Resources in JSON format")][string]$ResourcesJSON,
[Parameter(Mandatory=$false,HelpMessage="Enter the value for WhatIf. Values can be either true or false")][bool]$WhatIf = $false
)

function ScheduleSnoozeAction ($VMObject,[string]$Action)
{
    
    Write-Output "Calling the ScheduledStartStop_Child wrapper (Action = $($Action))..."
	
    if($Action.ToLower() -eq 'start')
    {
        $params = @{"VMName"="$($VMObject.Name)";"Action"="start";"ResourceGroupName"="$($VMObject.ResourceGroupName)"}   
    }    
    elseif($Action.ToLower() -eq 'stop')
    {
        $params = @{"VMName"="$($VMObject.Name)";"Action"="stop";"ResourceGroupName"="$($VMObject.ResourceGroupName)"}                    
    }    
   
   	if ($VMObject.Type -eq "Classic")
	{
		Write-Output "Performing the schedule $($Action) for the VM : $($VMObject.Name) using Classic"
		$currentVM = Get-AzureVM | where Name -Like $VMObject.Name
		if ($currentVM.Count -ge 1)
		{
			$runbookName = 'ScheduledStartStop_Child_Classic'
		}
		else
		{
			Write-Error "Error: No VM instance with name $($VMObject.Name) found"
		}
	
	}
	elseif ($VMObject.Type -eq "ResourceManager")
	{
		Write-Output "Performing the schedule $($Action) for the VM : $($VMObject.Name) using AzureRM"
		$runbookName = 'ScheduledStartStop_Child'
	}

	 $job = Start-AzureRmAutomationRunbook -automationAccountName $automationAccountName -Name $runbookName -ResourceGroupName $aroResourceGroupName -Parameters $params

    return $job
}

function ValidateVMList ($FilterVMList)
{
    [boolean] $ISexists = $false
    [string[]] $invalidvm=@()
    $ExAzureVMList=@()

    foreach($filtervm in $FilterVMList) 
    {
	
		$currentVM = Get-AzureRmVM | where Name -Like $filtervm.Trim()  -ErrorAction SilentlyContinue
	    if ($currentVM.Count -ge 1)
	    {
		    $ExAzureVMList+= @{Name = $currentVM.Name; Location = $currentVM.Location; ResourceGroupName = $currentVM.ResourceGroupName; Type = "ResourceManager"}
            $ISexists = $true
	    }
	    elseif($ISexists -eq $false)
	    {
		    $invalidvm = $invalidvm+$filtervm				
	    }
    }

    if($invalidvm -ne $null)
    {
        Write-Output "Runbook Execution Stopped! Invalid VM Name(s) in the VM list: $($invalidvm) "
        Write-Warning "Runbook Execution Stopped! Invalid VM Name(s) in the VM list: $($invalidvm) "
        exit
    }
    else
    {
        return $ExAzureVMList
    }
}

function ValidateClassicVMList ($FilterVMList)
{
    
    [boolean] $ISexists = $false
    [string[]] $invalidvm=@()
    $ExAzureVMList=@()

    foreach($filtervm in $FilterVMList) 
    {
	
		$currentVM = Get-AzureVM | where Name -Like $filtervm.Trim()  -ErrorAction SilentlyContinue
		
		if ($currentVM.Count -ge 1)
		{
			$uri=$currentVM.VM.OSVirtualHardDisk.MediaLink.AbsoluteUri
			$VMLocation = Get-AzureDisk | Where-Object {$_.MediaLink -eq $uri}| Select-Object Location
			$ExAzureVMList+= @{Name = $currentVM.Name; Location = $VMLocation.Location; ResourceGroupName = $currentVM.ServiceName; Type = "Classic"}
            $ISexists = $true
		}
	    elseif($ISexists -eq $false)
	    {
		    $invalidvm = $invalidvm+$filtervm				
	    }
    }

    if($invalidvm -ne $null)
    {
        Write-Output "Runbook Execution Stopped! Invalid VM Name(s) in the VM list: $($invalidvm) "
        Write-Warning "Runbook Execution Stopped! Invalid VM Name(s) in the VM list: $($invalidvm) "
        exit
    }
    else
    {
        return $ExAzureVMList
    }
    
}

function CheckClassicRunAs()
{
    Write-Output "Checking Classic RunAs Connection..."
    $ConnectionAssetName = "AzureClassicRunAsConnection"
    $Conn = Get-AutomationConnection -Name $ConnectionAssetName -ErrorAction SilentlyContinue
    if ($Conn -eq $null)
    {
        Write-Output "Could not retrieve connection asset: $ConnectionAssetName. Make sure that this asset exists in the Automation account."
        Write-Warning "Could not retrieve connection asset: $ConnectionAssetName. Make sure that this asset exists in the Automation account."
        exit
    }

    Write-Output "Checking Classic RunAs Certificate..."
    $CertificateAssetName = $Conn.CertificateAssetName    
    $AzureCert = Get-AutomationCertificate -Name $CertificateAssetName -ErrorAction SilentlyContinue
    if ($AzureCert -eq $null)
    {
        Write-Output "Could not retrieve certificate asset: $CertificateAssetName. Make sure that this asset exists in the Automation account."
        Write-Warning "Could not retrieve certificate asset: $CertificateAssetName. Make sure that this asset exists in the Automation account."
        exit
    }
     Write-Output "Authenticating to Azure with certificate." -Verbose
    Set-AzureSubscription -SubscriptionName $Conn.SubscriptionName -SubscriptionId $Conn.SubscriptionID -Certificate $AzureCert 
    Select-AzureSubscription -SubscriptionId $Conn.SubscriptionID
}



#-----L O G I N - A U T H E N T I C A T I O N-----
$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    "Logging into Azure..."
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

#---------Read all the input variables---------------
$SubId = Get-AutomationVariable -Name 'Internal_AzureSubscriptionId'
$automationAccountName = Get-AutomationVariable -Name 'Internal_AutomationAccountName'
$aroResourceGroupName = Get-AutomationVariable -Name 'Internal_ResourceGroupName'
[String]$storageAccountName = Get-AutomationVariable -Name 'Internal_StorageAccountName'
[String]$tableStorageRG = Get-AutomationVariable -Name 'Internal_ResourceGroupName' 
[String]$storageTableName = Get-AutomationVariable -Name 'Internal_ScheduleTableStorageName'

try
    {  
        Write-Output "Runbook Execution Started..."        

        Write-Output "Validadting the input JSON..."

        if (([string]::IsNullOrEmpty($ResourcesJSON) -eq $true) -or ($ResourcesJSON -eq ""))
        {
            Write-Output "`$ResourcesJSON parameter value is required..."
            Write-Error "`$ResourcesJSON parameter value is required..."
            exit
        }

        $resourcesObj =  $ResourcesJSON | ConvertFrom-Json
        $ScheduleNameId = $resourcesObj.ScheduleName
        $Action = $resourcesObj.Action.Trim().ToLower()
        $resources = $resourcesObj.Resources

        Write-Output "Validating the OperationType..."

        $Action = $Action.Trim().ToLower()

        if(!($Action -eq "start" -or $Action -eq "stop")){
            Write-Output "`$Action parameter value is : $($Action). Value should be either start or stop."
            Write-Output "Completed the runbook execution..."
            exit
            }
        
        #Hashtable to collect the Resource name and ResourceId
        $resourceMapping = [ordered]@{}
        [String[]]$AzVMList = ""
        [String[]]$AzClassVMList = ""
        
        foreach($resource in $resources){
            [string[]]$strVMuri = $resource -split "/"            
            $resourceMapping.Add($strVMuri[$strVMuri.Count-1],$resource)
            if($resource.Contains("Microsoft.Compute"))
            {
                [String[]]$AzVMList += $strVMuri[$strVMuri.Count-1]                    
            }
            elseif($resource.Contains("Microsoft.ClassicCompute"))
            {
                [String[]]$AzClassVMList += $strVMuri[$strVMuri.Count-1]
            }            
        }

        if($AzClassVMList -ne $null)
        {
            Write-Output "You have classic resource to take action hence checking the Classic RunAs Account..."
            CheckClassicRunAs
        }
        
        Write-Output "Validating the VM List..."
        
        $AzureVMList=@()
        if ($AzVMList -ne $null)
		{
			##Validating the VM List.
			$AzureVMList = ValidateVMList -FilterVMList $AzVMList
		}

        if ($AzClassVMList -ne $null)
		{
			##Validating the VM List.
			$AzureVMList += ValidateClassicVMList -FilterVMList $AzClassVMList
		}
        
        [String] $ExecutionRunbook = "ScheduledStartStop_Parent_vNext"

        $storageSEHContext = (Get-AzureRmStorageAccount -ResourceGroupName $tableStorageRG -Name $StorageAccountName).Context

        $guid = [Guid]::NewGuid().ToString()
        $ExceptionRefId = [Guid]::NewGuid().ToString()
        $ScheduleExec = New-Object -TypeName PSObject 
        $ScheduleExec | Add-Member -MemberType NoteProperty -Name ScheduleExecutionId -Value $PSPrivateMetadata.JobId.Guid
        #$ScheduleExec | Add-Member -MemberType NoteProperty -Name ScheduleExecutionId -Value $guid        
        $ScheduleExec | Add-Member -MemberType NoteProperty -Name Status -Value "InProgress"
        $ScheduleExec | Add-Member -MemberType NoteProperty -Name StartTime -Value (Get-Date).DateTime
        $ScheduleExec | Add-Member -MemberType NoteProperty -Name EndTime -Value ""
        $ScheduleExec | Add-Member -MemberType NoteProperty -Name ExecutionResults -Value ""
        $ScheduleExec | Add-Member -MemberType NoteProperty -Name Message -Value ""

        $tableScheduleExecutionHistory = Get-AzureStorageTable -Name $storageTableName -Context $storageSEHContext

        $propertyScheduleExecutionObj = @{"ScheduleNameId"=$ScheduleNameId; `
                                          "ScheduleExecutionId"=$ScheduleExec.ScheduleExecutionId; `                                        
                                          "StartTime"=$ScheduleExec.StartTime; `
                                          "ExecutionRunbook"=$ExecutionRunbook; `
                                          "ExecutionParameters"=$ResourcesJSON; `
                                          "OperationType"=$Action; `
                                          "Status"=$ScheduleExec.Status; `                                        
                                          "EndTime"=$ScheduleExec.EndTime; `
                                          "ExecutionResults"=$ScheduleExec.ExecutionResults; `
                                          "Message"=$ScheduleExec.Message; `
                                          "ExceptionRefId"=$ExceptionRefId}

        Write-Output "Writing to table storage..."

        Add-StorageTableRow -table $tableScheduleExecutionHistory -partitionKey $ScheduleNameId -rowKey $ScheduleExec.StartTime -property $propertyScheduleExecutionObj


        Write-Output "The current action is $($Action)"
        
        if($WhatIf -eq $false)
        {       
            $ChildJobs = foreach($VM in $AzureVMList)
            {  
                $job = ScheduleSnoozeAction -VMObject $VM -Action $Action
                $childExceptionRefId = [Guid]::NewGuid().ToString()
                $jobStatus = Get-AzureRmAutomationJob -Id $job.JobId -ResourceGroupName $aroResourceGroupName -AutomationAccountName $automationAccountName
                [pscustomobject]@{                
                                    ChildJobId = $jobStatus.JobId
                                    RunbookName = $jobStatus.RunbookName
                                    Parameters = $VM.Name + " " + $Action
                                    ResourceId = $resourceMapping[$VM.Name]
                                    Result = $jobStatus.Status
                                    StartTime = $jobStatus.StartTime                
                                    EndTime = $jobStatus.EndTime
                                    Message = "Job started"
                                    ExceptionRefId = $childExceptionRefId
                                 }
            }
            
            Write-Output "Checking the job status on child runbooks..."
 
            foreach($jobdata in $ChildJobs)
            {
                $jobInfo = Get-AzureRmAutomationJob -Id $jobdata.ChildJobId -ResourceGroupName $aroResourceGroupName -AutomationAccountName $automationAccountName
                while ($jobInfo.Status -notin ("Completed","Stopped","Failed","Suspended")) 
                { 
                    #Get and output the status 
                    Write-Output "`t$($jobInfo.Status)" 
                    sleep -Seconds 10 
                    $jobInfo = Get-AzureRmAutomationJob -Id $jobdata.ChildJobId -ResourceGroupName $aroResourceGroupName -AutomationAccountName $automationAccountName  
                }
                $jobdata.StartTime = $jobInfo.StartTime
                $jobdata.EndTime = $jobInfo.EndTime
                $jobdata.Result = $jobInfo.Status 
            }

            Write-Output "All the child jobs completed..."
            $ChildJobsJSON = $ChildJobs | ConvertTo-Json
        }
        elseif($WhatIf -eq $true)
        {
            Write-Output "WhatIf parameter is set to True..."
            Write-Output "When 'WhatIf' is set to TRUE, runbook provides a list of Azure Resources (e.g. VMs), that will be impacted if you choose to deploy this runbook."
            Write-Output "No action will be taken at this time..."
            Write-Output $($AzureVMList) 
        }

        Write-Output "Update the execution status into the table storage..."
        #Get the parent job to update the status
        $rowScheduleExecutionData = Get-AzureStorageTableRowByColumnName -table $tableScheduleExecutionHistory -columnName "ScheduleExecutionId" -value $ScheduleExec.ScheduleExecutionId -operator Equal
        $rowScheduleExecutionData.EndTime = (Get-Date).DateTime
        $rowScheduleExecutionData.ExecutionResults = $ChildJobsJSON
        $rowScheduleExecutionData.Message = "Completed Successfully"
        $rowScheduleExecutionData.Status = "Completed"
        
        #Update the parent job status
        Update-AzureStorageTableRow -table $tableScheduleExecutionHistory -entity $rowScheduleExecutionData

        Write-Output "Parent schedule execution $($ScheduleExec)"
        Write-Output "Runbook Execution Completed..."
    }
    catch
    {
        $ex = $_.Exception
        Write-Output $_.Exception
        if($tableScheduleExecutionHistory -ne $null)
        {
            $rowScheduleExecutionData = Get-AzureStorageTableRowByColumnName -table $tableScheduleExecutionHistory -columnName "ScheduleExecutionId" -value $ScheduleExec.ScheduleExecutionId -operator Equal
            $rowScheduleExecutionData.EndTime = (Get-Date).DateTime
            $rowScheduleExecutionData.Message = $ex.Message
            $rowScheduleExecutionData.Status = "Failed"
            $rowScheduleExecutionData.ExecutionResults = $ChildJobsJSON

            Update-AzureStorageTableRow -table $tableScheduleExecutionHistory -entity $rowScheduleExecutionData

            Write-Output "Parent schedule execution $($ScheduleExec)"
        }
    }
