<#
deleteSnapshots.ps1
William David van Collenburg
Scale Computing

Script to demonstrate deleting excessive snapshots

!!! ----------------ATTENTION------------------- !!!
!!! THIS SCRIPT DELETES SNAPSHOT ON YOUR CLUSTER !!!
!!!                                              !!!
!!!          USE WITH EXTREME CARE               !!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

THIS SCRIPT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND
feel free to use without attribution in any way as seen fit, at your own risc.

Usage: Fill out the variables below and run the script.

#>

$scaleuser = "admin"                                # Username that exist and has proper rights on a scale computing cluster
$scalepassword = "admin"                            # Password for given user
$node = "192.168.0.11"                              # the IP address or FQDN for one of the nodes in the cluster
$SafeMode = ""                                      # Set this to "DeleteMySnaps" to allow for actual snapshot deletion. If not set it gives an overview of all
                                                    # snapshots that would be deleted if actually performed. Use this to first check before just deleting.

$snapshotLabel = "bdtest"                           # If you want to delete specific snapshots give their label here. leave blank for all snapshots (not recomended)

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
        Write-Progress -Activity "Exporting $tname to $smburl" -PercentComplete $taskStatus.progressPercent

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

# Read info from the cluster to use in this script
$readURL = "https://$node/rest/v1/VirDomainSnapshot"
$readInfo = Invoke-RestMethod -Method 'Get' -Uri "$readURL" -ContentType 'application/json' -WebSession $mywebsession

# Loop through the Snapshots to find the snapshots that have our designated label
ForEach ($snap in $readInfo) {
    $matchme = $snap.label
    If ($snapshotLabel -match "\b$matchme\b") {
        Write-Host $snap.domain.name $snap.uuid -NoNewline
        If ($SafeMode -eq "DeleteMySnaps") {
            #Generate the delete URL
            $snap2del = $snap.uuid
            $delURL = "https://$node/rest/v1/VirDomainSnapshot/$snap2del"
            #Remove the snapshot
            $delresult = Invoke-RestMethod -Method 'DELETE' -Uri "$delURL" -ContentType 'application/json' -WebSession $mywebsession
            Wait-ScaleTask -TaskTag $($delresult.taskTag)
            Write-Host " - has been deleted"
        }
        else {
            Write-Host " - Would be deleted"
        }
      }
    }

# logout from the scale cluster and invalidate the session token
Invoke-RestMethod -Method Post -Uri https://$node/rest/v1/logout -WebSession $mywebsession

Write-Host done
