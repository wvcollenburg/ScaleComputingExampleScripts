<# 
BackupFromReplica.ps1

William David van Collenburg
Scale Computing

Script to demonstrate preparing a clone of a replica for Acronis agentless backup purposes

THIS SCRIPT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND
feel free to use without attribution in any way as seen fit, at your own risc.

Usage: 
First save this script as a .ps1 file on a server / pc
Manually create a clone of every replica you wish to backup with acronis and append -buclone to the name (test123 becomes test123-buclone)
remove all tags from vm and add the buclone tag to it. This should result in having a seperate group of vm's. (you can use another tag, but then you should also change the string that you append to the vms. when using "OtherTag" then the vms should be appended with "-OtherTag)"
This is needed to create the relationship between the source replica and its backup-clone.
Fill out the variables below and run the script.
Go to your Acronis management portal and create an agentless backup plan for the vm's that end with -buclone
On a server create a task that runs this script before every backup.

Update 6-3-2024: For a second replication, skip the Acronis part and configure a snapshot of the placeholder VM to be made after the vm has been equipped with the latest version of the replica.

#>

# In the below section the parameters as described above are defined. In this case all parameters are mandatory, except for the credentials as they will be asked if not provided.

$scaleuser = "admin"                     # Username that exist and has proper rights on a scale computing cluster
$scalepassword = "admin"                 # Password for given user
$node = "172.16.0.245"                   # the IP address or FQDN for one of the nodes in the cluster

$BackupTag = "buclone"                   # This tag needs to be added to VMs that you would like to be prepped for backup by this script.


# ---------- You should not need to change anything below this line ---------- #

# some other vars that are needed for the script

$TagLetterCount = $BackupTag.Length + 1

$restOpts = @{
    ContentType = 'application/json'
}

$searchTag = "*" + $BackupTag + "*"


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

# Read info from the cluster to use in this script
$readURL = "https://$node/rest/v1/VirDomain"
$readInfo = Invoke-RestMethod -Method 'Get' -Uri "$readURL" -ContentType 'application/json' -WebSession $mywebsession

# Loop through the VMs to find the VMs that have our designated tag
ForEach ($vm in $readInfo) {
    If ($vm.tags -like $searchTag) {
        $targetuuid =  $vm.uuid
        $ParentName = $vm.name -replace ".{$TagLetterCount}$"
        
        ForEach ($findParentUUID in $readInfo) {
            If ($findParentUUID.name -eq $ParentName) {
                $SnapARR = @($findParentUUID.snapUUIDs)
                $lastSnap = $SnapARR[-1]
            }
        }

        # remove existing disks from buclone vm's

        ForEach ($oldDisk in $vm.blockDevs) {
            If ($oldDisk.type -eq "VIRTIO_DISK") {
                $todeldisk = $oldDisk.uuid
                $deldskResultURL = "https://$node/rest/v1/VirDomainBlockDevice/$todeldisk"
                $deldskResult = Invoke-RestMethod -Method 'Delete' -Uri "$deldskResultURL" -ContentType 'application/json' -WebSession $mywebsession
                Wait-ScaleTask -TaskTag $($deldskResult.taskTag)
            }
            
        } 
        

        # Read the snapshot info
        
        $readSnapURL = "https://$node/rest/v1/VirDomainSnapshot/$lastSnap"
        $readSnap = Invoke-RestMethod -Method 'Get' -Uri "$readSnapURL" -ContentType 'application/json' -WebSession $mywebsession

        # Loop through snapshot info to get the disk uuids

        $makeboot = 0

        ForEach ($disk in $readSnap.domain.blockDevs) {
            If ($disk.type -eq "VIRTIO_DISK") {
                
                $diskuuidtoclone = $disk.uuid
                
                $Body = ConvertTo-Json @{
                    options = @{
                        regenerateDiskID = $false
                        readOnly = $false
                        }
                    snapUUID = $lastSnap
                    template = @{
                        virDomainUUID = $vm.uuid
                        type = "VIRTIO_DISK"
                        capacity = $disk.capacity
                        slot = 1
                        tieringPriorityFactor = 0
                        }
                    }
                
                $cloneDiskURL = "https://$node/rest/v1/VirDomainBlockDevice/$diskuuidtoclone/clone"

                $result = Invoke-RestMethod -Method 'Post' -Uri $cloneDiskURL -WebSession $mywebsession @restOpts -Body $Body
                Wait-ScaleTask -TaskTag $($result.taskTag)
                

                # make added disk bootable if it is the first one

                $bootBody = ConvertTo-Json @{
                    name = $vm.name
                    mem = $vm.mem
                    numVCPU = $vm.numVCPU
                    bootDevices = @(
                        $result.createdUUID
                    )
                }

                If ($makeboot -eq 0) {
                    $makeBootURL = "https://$node/rest/v1/VirDomain/$targetuuid"
                    $result = Invoke-RestMethod -Method 'Post' -Uri $makeBootURL -WebSession $mywebsession @restOpts -Body $bootBody
                    Wait-ScaleTask -TaskTag $($result.taskTag)
                    $makeboot++
                }
                



            }
            

        }

    }
}

Invoke-RestMethod -Method Post -Uri https://$node/rest/v1/logout -WebSession $mywebsession
Write-Host done 
