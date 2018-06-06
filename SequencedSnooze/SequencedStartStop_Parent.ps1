<#
.SYNOPSIS  
	This runbook used to perform sequenced start or stop Azure RM/Classic VM
.DESCRIPTION  
	This runbook used to perform sequenced start or stop Azure RM/Classic VM.
	Create a tag called “sequencestart” on each VM that you want to sequence start activity for.Create a tag called “sequencestop” on each VM that you want to sequence stop activity for. The value of the tag should be an integer (1,2,3) that corresponds to the order you want to start\stop. For both action, the order goes ascending (1,2,3) . WhatIf behaves the same as in other runbooks. 
	Upon completion of the runbook, an option to email results of the started VM can be sent via SendGrid account. 
	
	This runbook requires the Azure Automation Run-As (Service Principle) account, which must be added when creating the Azure Automation account.
 .PARAMETER  
    Parameters are read in from Azure Automation variables.  
    Variables (editable):
    -  External_Start_ResourceGroupNames    :  ResourceGroup that contains VMs to be started. Must be in the same subscription that the Azure Automation Run-As account has permission to manage.
    -  External_Stop_ResourceGroupNames     :  ResourceGroup that contains VMs to be stopped. Must be in the same subscription that the Azure Automation Run-As account has permission to manage.
    -  External_ExcludeVMNames              :  VM names to be excluded from being started.
    -  External_IsSendEmail                 :  String value (Yes/No) to send email or not send email.
    -  External_EmailSubject                :  Email subject (title) 
    -  External_EmailToAddress              :  List of recipients of the email.  Seperate by semi-colon ';'
.EXAMPLE  
	.\SequencedStartStop_Parent.ps1 -Action "Value1" 

#>

Param(
[Parameter(Mandatory=$true,HelpMessage="Enter the value for Action. Values can be either stop or start")][String]$Action,
[Parameter(Mandatory=$false,HelpMessage="Enter the value for WhatIf. Values can be either true or false")][bool]$WhatIf = $false,
[Parameter(Mandatory=$false,HelpMessage="Enter the value for ContinueOnError. Values can be either true or false")][bool]$ContinueOnError = $false,
[Parameter(Mandatory=$false,HelpMessage="Enter the VMs separated by comma(,)")][string]$VMList
)
#-----L O G I N - A U T H E N T I C A T I O N-----
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

function sendEmail($VMList,[string]$Action)
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

        $Body = "The following VMs are attempting to do the operation: $($Action)."
		
		$Body += "<br><br><table border=1><tr><td><b>VM Name</b></td><td><b>Resource Group Name</b></td></tr>"

        foreach($vm in $VMList)
        {
            $Body +="<tr><td>$($vm.Name)</td><td>$($vm.ResourceGroupName)</td></tr>"
        }

		$Body += "</table>"
		
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

function PerformActionOnSequencedTaggedVMRGs($Sequences, [string]$Action, $TagName, [string[]]$VMRGList, $ExcludeList)
{
    $EmailVMList=@()


    foreach($seq in $Sequences)
    {
        $AzureVMList=@()

        if($WhatIf -eq $false)
        {
            Write-Output "Performing the $($Action) action against VM's where the tag $($TagName) is $($seq)."
			foreach($rg in $VMRGList)
			{
                $AzureVMList += Find-AzureRmResource -TagName $TagName.ToLower() -TagValue $seq | Where-Object {($_.ResourceType -eq “Microsoft.Compute/virtualMachines”) -and ($_.ResourceGroupName -eq $rg.Trim())} | Select Name, ResourceGroupName
            }
            
            ##Remove Excluded VMs
            $ActualAzureVMList=@()
            $ExAzureVMList=@()
            if($ExcludeList -ne $null)
            {
                foreach($filtervm in $ExcludeList) 
                {
		            $currentVM = Get-AzureRmVM | where Name -Like $filtervm.Trim()  -ErrorAction SilentlyContinue
		            if ($currentVM.Count -ge 1)
		            {
			            $ExAzureVMList+=$currentVM.Name
		            }
                }
            }

            if($ExcludeList -ne $null)
            {
                foreach($VM in $AzureVMList)
                {  
                    ##Checking Vm in excluded list                         
                    if($ExAzureVMList -notcontains ($($VM.Name)))
                    {
                        $ActualAzureVMList+=$VM
                    }
                }
            }
            else
            {
                $ActualAzureVMList = $AzureVMList
            }
            
            foreach($vmObj in $ActualAzureVMList)
            {   
                Write-Output "Executing runbook ScheduledStartStop_Child to perform the $($Action) action on VM: $($vmobj.Name)"
                $params = @{"VMName"="$($vmObj.Name)";"Action"=$Action;"ResourceGroupName"="$($vmObj.ResourceGroupName)"}                    
                Start-AzureRmAutomationRunbook -automationAccountName $automationAccountName -Name 'ScheduledStartStop_Child' -ResourceGroupName $aroResourceGroupName –Parameters $params   
                $EmailVMList += $vmObj          
            }

            Write-Output "Completed the sequenced $($Action) against VM's where the tag $($TagName) is $($seq)." 

            if(($Action -eq 'stop' -and $seq -ne $Sequences.Count) -or ($Action -eq 'start' -and $seq -ne [int]$Sequences.Count - ([int]$Sequences.Count-1)))
            {
                Write-Output "Validating the status before processing the next sequence..."
            }        

            foreach($vmObjStatus in $ActualAzureVMList)
            {
                [int]$SleepCount = 0 
                $CheckVMStatus = CheckVMState -VMObject $vmObjStatus -Action $Action
                While($CheckVMStatus -eq $false)
                {                
                    Write-Output "Checking the VM Status in 10 seconds..."
                    Start-Sleep -Seconds 10
                    $SleepCount+=10
                    if($SleepCount -gt $maxWaitTimeForVMRetryInSeconds -and $ContinueOnError -eq $false)
                    {
                        Write-Output "Unable to $($Action) the VM $($vmObjStatus.Name). ContinueOnError is set to False, hence terminating the sequenced $($Action)..."
                        Write-Output "Completed the sequenced $($Action)..."
                        exit
                    }
                    elseif($SleepCount -gt $maxWaitTimeForVMRetryInSeconds -and $ContinueOnError -eq $true)
                    {
                        Write-Output "Unable to $($Action) the VM $($vmObjStatus.Name). ContinueOnError is set to True, hence moving to the next resource..."
                        break
                    }
                    $CheckVMStatus = CheckVMState -VMObject $vmObjStatus -Action $Action
                }
            }
        }
        elseif($WhatIf -eq $true)
        {
            Write-Output "WhatIf parameter is set to True..."
            Write-Output "When 'WhatIf' is set to TRUE, runbook provides a list of Azure Resources (e.g. VMs), that will be impacted if you choose to deploy this runbook."
            Write-Output "No action will be taken at this time. These are the resources where the tag $($TagName) is $($seq)..."
            foreach($rg in $VMRGList)
			{
                $AzureVMList += Find-AzureRmResource -TagName $TagName.ToLower() -TagValue $seq | Where-Object {($_.ResourceType -eq “Microsoft.Compute/virtualMachines”) -and ($_.ResourceGroupName -eq $rg.Trim())} | Select Name, ResourceGroupName
            }
            
            ##Remove Excluded VMs
            $ActualAzureVMList=@()
            $ExAzureVMList=@()
            if($ExcludeList -ne $null)
            {
                foreach($filtervm in $ExcludeList) 
                {
		            $currentVM = Get-AzureRmVM | where Name -Like $filtervm.Trim()  -ErrorAction SilentlyContinue
		            if ($currentVM.Count -ge 1)
		            {
			            $ExAzureVMList+=$currentVM.Name
		            }
                }
            }

            if($ExcludeList -ne $null)
            {
                foreach($VM in $AzureVMList)
                {  
                    ##Checking Vm in excluded list                         
                    if($ExAzureVMList -notcontains ($($VM.Name)))
                    {
                        $ActualAzureVMList+=$VM
                    }
                }
            }
            else
            {
                $ActualAzureVMList = $AzureVMList
            }
            
            Write-Output $($ActualAzureVMList)
            Write-Output "End of resources where tag $($TagName) is $($seq)..."
        }
    }

    if($EmailVMList -ne $null -and $isSendMail.ToLower() -eq 'yes')
    {
        sendEmail -VMList $EmailVMList -Action $Action
    }
}

function PerformActionOnSequencedTaggedVMList($Sequences, [string]$Action, $TagName, [string[]]$AzVMList)
{
    $EmailVMList=@()

    foreach($seq in $Sequences)
    {
        $AzureVMList=@()

        if($WhatIf -eq $false)
        {
            Write-Output "Performing the $($Action) action against VM's where the tag $($TagName) is $($seq)."
			foreach($vm in $AzVMList)
			{
                $AzureVMList += Find-AzureRmResource -TagName $TagName.ToLower() -TagValue $seq | Where-Object {($_.ResourceType -eq “Microsoft.Compute/virtualMachines”) -and ($_.Name -eq $vm.Trim())} | Select Name, ResourceGroupName
            }
            
            foreach($vmObj in $AzureVMList)
            {   
                Write-Output "Executing runbook ScheduledStartStop_Child to perform the $($Action) action on VM: $($vmobj.Name)"
                $params = @{"VMName"="$($vmObj.Name)";"Action"=$Action;"ResourceGroupName"="$($vmObj.ResourceGroupName)"}                    
                Start-AzureRmAutomationRunbook -automationAccountName $automationAccountName -Name 'ScheduledStartStop_Child' -ResourceGroupName $aroResourceGroupName –Parameters $params   
                $EmailVMList += $vmObj          
            }

            Write-Output "Completed the sequenced $($Action) against VM's where the tag $($TagName) is $($seq)." 

            if(($Action -eq 'stop' -and $seq -ne $Sequences.Count) -or ($Action -eq 'start' -and $seq -ne [int]$Sequences.Count - ([int]$Sequences.Count-1)))
            {
                Write-Output "Validating the status before processing the next sequence..."
            }        

            foreach($vmObjStatus in $AzureVMList)
            {
                [int]$SleepCount = 0 
                $CheckVMStatus = CheckVMState -VMObject $vmObjStatus -Action $Action
                While($CheckVMStatus -eq $false)
                {                
                    Write-Output "Checking the VM Status in 10 seconds..."
                    Start-Sleep -Seconds 10
                    $SleepCount+=10
                    if($SleepCount -gt $maxWaitTimeForVMRetryInSeconds -and $ContinueOnError -eq $false)
                    {
                        Write-Output "Unable to $($Action) the VM $($vmObjStatus.Name). ContinueOnError is set to False, hence terminating the sequenced $($Action)..."
                        Write-Output "Completed the sequenced $($Action)..."
                        exit
                    }
                    elseif($SleepCount -gt $maxWaitTimeForVMRetryInSeconds -and $ContinueOnError -eq $true)
                    {
                        Write-Output "Unable to $($Action) the VM $($vmObjStatus.Name). ContinueOnError is set to True, hence moving to the next resource..."
                        break
                    }
                    $CheckVMStatus = CheckVMState -VMObject $vmObjStatus -Action $Action
                }
            }
        }
        elseif($WhatIf -eq $true)
        {
            Write-Output "WhatIf parameter is set to True..."
            Write-Output "When 'WhatIf' is set to TRUE, runbook provides a list of Azure Resources (e.g. VMs), that will be impacted if you choose to deploy this runbook."
            Write-Output "No action will be taken at this time. These are the resources where the tag $($TagName) is $($seq)..."
            foreach($vm in $AzVMList)
			{
                $AzureVMList += Find-AzureRmResource -TagName $TagName.ToLower() -TagValue $seq | Where-Object {($_.ResourceType -eq “Microsoft.Compute/virtualMachines”) -and ($_.Name -eq $vm)} | Select Name, ResourceGroupName
            }
            
            ##Remove Excluded VMs
            $ActualAzureVMList=@()
            if($ExcludeList -ne $null)
            {
                foreach($VM in $AzureVMList)
                {  
                    ##Checking Vm in excluded list                         
                    if($ExcludeList -notcontains ($($VM.Name)))
                    {
                        $ActualAzureVMList+=$VM
                    }
                }
            }
            else
            {
                $ActualAzureVMList = $AzureVMList
            }
            
            Write-Output $($ActualAzureVMList)
            Write-Output "End of resources where tag $($TagName) is $($seq)..."
        }
    }

    if($EmailVMList -ne $null -and $isSendMail.ToLower() -eq 'yes')
    {
        sendEmail -VMList $EmailVMList -Action $Action
    }
}
function CheckVMState ($VMObject,[string]$Action)
{
    [bool]$IsValid = $false
    
    $CheckVMState = (Get-AzureRmVM -ResourceGroupName $VMObject.ResourceGroupName -Name $VMObject.Name -Status -ErrorAction SilentlyContinue).Statuses.Code[1]
    if($Action.ToLower() -eq 'start' -and $CheckVMState -eq 'PowerState/running')
    {
        $IsValid = $true
    }    
    elseif($Action.ToLower() -eq 'stop' -and $CheckVMState -eq 'PowerState/deallocated')
    {
            $IsValid = $true
    }    
    return $IsValid
}

function CheckExcludeVM ($FilterVMList)
{
    [boolean] $ISexists = $false
    [string[]] $invalidvm=@()
    $ExAzureVMList=@()

    foreach($filtervm in $FilterVMList) 
    {
		$currentVM = Get-AzureRmVM | where Name -Like $filtervm.Trim()  -ErrorAction SilentlyContinue
		if ($currentVM.Count -ge 1)
		{
			$ExAzureVMList+=$currentVM.Name
		}
		else
		{
			$invalidvm = $invalidvm+$filtervm
		}
    }
    if($invalidvm -ne $null)
    {
        Write-Output "Runbook Execution Stopped! Invalid VM Name(s) in the exclude list: $($invalidvm) "
        Write-Warning "Runbook Execution Stopped! Invalid VM Name(s) in the exclude list: $($invalidvm) "
        exit
    }
    else
    {
        Write-Output "Exclude VM's validation completed..."
    }    
}

#---------Read all the input variables---------------
$automationAccountName = Get-AutomationVariable -Name 'Internal_AutomationAccountName'
$aroResourceGroupName = Get-AutomationVariable -Name 'Internal_ResourceGroupName'
$isSendMail = Get-AutomationVariable -Name 'External_IsSendEmail'
$maxWaitTimeForVMRetryInSeconds = Get-AutomationVariable -Name 'External_WaitTimeForVMRetryInSeconds'

$StartResourceGroupNames = Get-AutomationVariable -Name 'External_Start_ResourceGroupNames'
$StopResourceGroupNames = Get-AutomationVariable -Name 'External_Stop_ResourceGroupNames'
$ExcludeVMNames = Get-AutomationVariable -Name 'External_ExcludeVMNames'

try
{
    $Action = $Action.Trim().ToLower()

    if(!($Action -eq "start" -or $Action -eq "stop"))
    {
        Write-Output "`$Action parameter value is : $($Action). Value should be either start or stop."
        Write-Output "Completed the runbook execution..."
        exit
    }

    #If user gives the VM list with comma seperated....
    [string[]] $AzVMList = $VMList -split ","        

    #Validate the Exclude List VM's and stop the execution if the list contains any invalid VM
    if (([string]::IsNullOrEmpty($ExcludeVMNames) -ne $true) -and ($ExcludeVMNames -ne "none"))
    {   
        Write-Output "Values exist on the VM's Exclude list. Checking resources against this list..."
        [string[]] $VMfilterList = $ExcludeVMNames -split ","
        CheckExcludeVM -FilterVMList $VMfilterList
    }

    if($Action -eq "stop")
    {
        [string[]] $VMRGList = $StopResourceGroupNames -split ","
    }
    if($Action -eq "start")
    {
        [string[]] $VMRGList = $StartResourceGroupNames -split ","
    }
     
    Write-Output "Executing the Sequenced $($Action)..."   
    Write-Output "Input parameter values..."
    Write-Output "`$Action : $($Action)"
    Write-Output "`$WhatIf : $($WhatIf)"
    Write-Output "`$ContinueOnError : $($ContinueOnError)"
    Write-Output "Filtering the tags across all the VM's..."
    
    $startTagValue = "sequencestart"  
	$stopTagValue = "sequencestop"  	
    $startTagKeys = Get-AzureRmVM | Where-Object {$_.Tags.Keys -eq $startTagValue.ToLower()} | Select Tags
	$stopTagKeys = Get-AzureRmVM | Where-Object {$_.Tags.Keys -eq $stopTagValue.ToLower()} | Select Tags
	$startSequences=[System.Collections.ArrayList]@()
	$stopSequences=[System.Collections.ArrayList]@()
	
    foreach($tag in $startTagKeys.Tags)
    {
		foreach($key in $($tag.keys)){
            if ($key -eq $startTagValue)
            {
                [void]$startSequences.add([int]$tag[$key])
            }
        }
	}
	
	foreach($tag in $stopTagKeys.Tags)
    {
		foreach($key in $($tag.keys)){
            if ($key -eq $stopTagValue)
            {
                [void]$stopSequences.add([int]$tag[$key])
            }
        }
    }

    $startSequences = $startSequences | Sort-Object -Unique
	$stopSequences = $stopSequences | Sort-Object -Unique
	
	
	if ($Action -eq 'start') 
	{
        if($AzVMList -ne $null)
        {
            PerformActionOnSequencedTaggedVMList -Sequences $startSequences -Action $Action -TagName $startTagValue -AzVMList $AzVMList
        }
        else
        {
		    PerformActionOnSequencedTaggedVMRGs -Sequences $startSequences -Action $Action -TagName $startTagValue -VMRGList $VMRGList -ExcludeList $VMfilterList
	    }
    }
	
	if ($Action -eq 'stop')
	{
        if($AzVMList -ne $null)
        {
            PerformActionOnSequencedTaggedVMList -Sequences $stopSequences -Action $Action -TagName $stopTagValue -AzVMList $AzVMList        
        }
        else
        {
		    PerformActionOnSequencedTaggedVMRGs -Sequences $stopSequences -Action $Action -TagName $stopTagValue -VMRGList $VMRGList -ExcludeList $VMfilterList
	    }
    }
	
   
    Write-Output "Completed the sequenced $($Action)..."
}
catch
{
    Write-Output "Error Occurred in the sequence $($Action) runbook..."   
    Write-Output $_.Exception
}