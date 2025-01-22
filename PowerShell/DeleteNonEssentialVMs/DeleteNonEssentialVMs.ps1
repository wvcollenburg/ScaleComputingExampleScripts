<#
deleteSnapshots.ps1
William David van Collenburg
Scale Computing

Script to demonstrate deleting non essential virtual machines

   !!! --------------------ATTENTION----------------------- !!!
   !!! THIS SCRIPT DELETES VIRTUAL MACHINES ON YOUR CLUSTER !!!
   !!!      !!!     THIS CAN NOT BE UNDONE     !!!          !!!
   !!!              USE WITH EXTREME CARE                   !!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

This scritp is inteded for use in demo environments where a lot of vm's are created and some form of scheduled clean-up needs to be done.
I strongly recomend AGAINST using this script in a live production environment as the chance of destroying something important is just to big.
Use this script at your own risc. Also see the WITHOUT WARRENTY OF ANY KIND remark below.

THIS SCRIPT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND
feel free to use without attribution in any way as seen fit, at your own risc.

Usage: Fill out the variables below and run the script.

#>

$scaleuser = "admin"                                # Username that exist and has proper rights on a scale computing cluster
$scalepassword = "admin"                            # Password for given user
$node = "192.168.0.11"                              # the IP address or FQDN for one of the nodes in the cluster
$SafeMode = ""                                      # Set this to "DeleteMyVMs" to allow for actual virtual vm deletion. If not set it gives an overview of all
                                                    # vms that would be deleted if actually performed. Use this to first check before just deleting.

$safeTag = "DoNotDelete"                            # VMs that need to be kept need to have this TAG. !!! ALL OTHER VMs WILL BE DELETED - THIS CAN NOT BE UNDONE !!!

# ---------- You should not need to change anything below this line ---------- #

# some other vars that are needed for the script

$restOpts = @{
    ContentType = 'application/json'
}

# The below is to ignore certificates. comment out or delete section if cerificates are handled properly (e.g. certificate has been uploaded to cluster)

add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# Make sure we are using a TLS version that is supported by the scale appliances (SSL3, TLS and TLS11 are not supported) 
# This setting influences the entire powershell session so will stay active untill the powershell session is terminated (will not be reset when script terminates)

[System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Login to the cluster and aquire Session


$login = ConvertTo-Json @{
    username = $scaleuser
    password = $scalepassword
}

Invoke-RestMethod -Method POST -Uri https://$node/rest/v1/login -Body $login -ContentType 'application/json' -SessionVariable mywebSession | Out-Null

# Many actions are asynchronous, often we need a way to wait for a returned taskTag to complete before taking further action

function Wait-ScaleTask {
    Param(
        [Parameter(Mandatory = $true,Position  = 1, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $TaskTag
    )

    $retryDelay = [TimeSpan]::FromSeconds(1)
    $timeout = [TimeSpan]::FromSeconds(7200)

    $timer = [Diagnostics.Stopwatch]::new()
    $timer.Start()

    while ($timer.Elapsed -lt $timeout)
    {
        
        Start-Sleep -Seconds $retryDelay.TotalSeconds
        $taskStatus = Invoke-RestMethod @restOpts "https://$node/rest/v1/TaskTag/$TaskTag" -Method GET -WebSession $mywebsession
        # Write-Progress -Activity "Exporting $tname to $smburl" -PercentComplete $taskStatus.progressPercent

        if ($taskStatus.state -eq 'ERROR') {
            throw "Task '$TaskTag' failed!"
        }
        elseif ($taskStatus.state -eq 'COMPLETE') {
            Write-Verbose "Task '$TaskTag' completed!"
            return
        }
    }
    throw [TimeoutException] "Task '$TaskTag' failed to complete in $($timeout.Seconds) seconds"
}

# Get the list of vm's for processing
$readURL = "https://$node/rest/v1/VirDomain"
$readInfo = Invoke-RestMethod -Method 'Get' -Uri "$readURL" -ContentType 'application/json' -WebSession $mywebsession
$SadVmList = New-Object System.Collections.Generic.List[System.Object]


# Loop through the VMs to find the VMs that have our designated tag
ForEach ($vm in $readInfo) {
    $matchme = $vm.tags
    If ($matchme -match "\b$safeTag\b") {
        # Write-Host $vm.name has the $safeTag TAG and will not be deleted
    } elseif ($matchme -notmatch "\b$safeTag\b") {
        Write-Host $vm.name IS NOT SAFE  -NoNewline
        If ($vm.state -like "RUNNING") {
            Write-Host " but needs to be stopped first"
            If ($SafeMode -eq "DeleteMyVMs") {
            $stopThisVM = $vm.UUID
            $stopURL = "https://$node/rest/v1/VirDomain/action"
            $stopVmBody = ConvertTo-Json @(@{
                virDomainUUID = $stopThisVM
                actionType = "STOP"
                })

            $result = Invoke-RestMethod -Method 'Post' -Uri $stopURL -WebSession $mywebsession -ContentType 'application/json' -Body $stopVmBody
            Wait-ScaleTask -TaskTag $($result.taskTag)

            $SadVmList.Add($vm.UUID)
            }
        }
        elseif ($vm.state -like "SHUTOFF") {
            Write-Host " and is already stopped"
            If ($SafeMode -eq "DeleteMyVMs") {
                $SadVmList.Add($vm.UUID)
            }
        }
        else {
            Write-Host " but i do not understand the state $vm.state"
           
        }
    }
}


If ($SadVmList.Count -ne 0  ) {
    Write-Host The script has found $SadVmList.Count VMs to delete. When you continue these will be deleted. THIS CAN NOT BE UNDONE. 'y' to continue
    $confirmation = Read-Host "Are you Sure You Want To Proceed"
    if ($confirmation -eq 'y') {
        ForEach ($sadVM in $SadVmList) {
            $delUri =  "https://$node/rest/v1/VirDomain/$sadVM"
            Invoke-RestMethod -Method DELETE -Uri $delUri  -WebSession $mywebsession -ContentType 'application/json' | Out-Null
        }
    }
}

Invoke-RestMethod -Method Post -Uri https://$node/rest/v1/logout -WebSession $mywebsession

