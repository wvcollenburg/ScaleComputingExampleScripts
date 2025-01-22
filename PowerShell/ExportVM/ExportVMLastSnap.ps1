<#
ExportVM.ps1

William David van Collenburg
Scale Computing

Script to demonstrate exporting vm's last snapshot based on a tag

THIS SCRIPT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND
feel free to use without attribution in any way as seen fit, at your own risc.

Usage: Fill out the variables below and run the script.

#>

# In the below section the parameters as described above are defined. In this case all parameters are mandatory.

$scaleuser = "admin"                                # Username that exist and has proper rights on a scale computing cluster
$scalepassword = "admin"                            # Password for given user
$node = "192.168.0.1"                               # the IP address or FQDN for one of the nodes in the cluster

$smbdomain = "domain.local"                       # The domain for the SMB user. usually your windows domain
$smbuser = "username"                          # Username that has write and change rights on the SMB share
$smbpassword = "password"                           # Password for given user
$smburl = "fileserver.domain.local"               # IP Address or FQDN for SMB share
$smbpath = "/exportfolder"                               # SMB share path. Needs to start with a / and needs to end without a /

$BackupTag = "export"                               # This tag needs to be added to VMs that you would like to be exported by this script

# ---------- You should not need to change anything below this line ---------- #

# some other vars that are needed for the script

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
$readURL = "https://$node/rest/v1/VirDomain"
$readInfo = Invoke-RestMethod -Method 'Get' -Uri "$readURL" -ContentType 'application/json' -WebSession $mywebsession

# Loop through the VMs to find the VMs that have our designated tag
ForEach ($vm in $readInfo) {
    If ($vm.tags -like $searchTag) {
        # set some variables that make it easier to genrate bodies and urls
        $tname = $vm.name + (Get-Date -Format "yyyy-MM-dd-HHmm")
        $snapARR = @($vm.snapUUIDs)
        $tsnapid = $snapARR[-1]
        $vmid = $vm.UUID
        # generate export path URI
        $exportpath = "smb://" + $smbdomain + ";" + $smbuser + ":" + $smbpassword + "@" + $smburl + $SMBPath + "/" + $vm.name + "/" + $tname
        # Check if export path exists, if not create it.
        $newFolderPath = "FileSystem::\\" + $smburl + $SMBPath + "\" + $vm.name + "\"
        $checkPath = Test-Path $newFolderPath
        If($checkPath -eq $false) {
            New-Item -Path $newFolderPath -ItemType Directory | Out-Null
        }
        
        # Create the json for the export api call
        $ExportBody = ConvertTo-Json @{
            target = @{
                pathURI = $exportpath
                definitionFileName = $tname + ".xml"
                }
                snapUUID = $tsnapid    
        }
        
        # generate the export URI based on above vars
        $exportURL = "https://$node/rest/v1/VirDomain/$vmid/export"
        
        # perform the export and hand over to the earlier created wait function to show progress and monitor when export is done
        $exportresult = Invoke-RestMethod -Method 'Post' -Uri $exportURL -WebSession $mywebsession @restOpts -Body $ExportBody
        Wait-ScaleTask -TaskTag $($exportresult.taskTag)
        
        }
    }

# logout from the scale cluster and invalidate the session token
Invoke-RestMethod -Method Post -Uri https://$node/rest/v1/logout -WebSession $mywebsession

Write-Host done