<#
CreateWithCloudInit.ps1

William David van Collenburg
Scale Computing

Script to demonstrate creating a clone from a template and configuring it with cloudinit

THIS SCRIPT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND
feel free to use without attribution in any way as seen fit, at your own risc.

The script does not have variables for all of the different options available in cloud-init
as it is intended as a proof of concept only. For the same reason it assumes the user that
is being created gets admin and sudo rights.

Usage: Fill out the variables below and run the script.

#>

# Scale Computing specific vars:

$scaleuser = "admin"                                      # Username that exist and has proper rights on a scale computing cluster
$scalepassword = "admin"                                  # Password for given user
$node = "192.168.0.11"                                    # the IP address or FQDN for one of the nodes in the cluster
$templateUUID = "347d3ffb-88bd-4ab2-ace7-cbe4af7f7831"    # The UUID of a template VM that has cloud-init installed and has been cleaned (cloud-init clean --logs)
$newVmName = "wonderfullvm"                               # Name for new VM (will also be the hostname)
$newVmTags = "cloudinitdemo, othertags"                   # Comma seperated tags list (remember first tag will also be group in interface)

# New Linux VM specific vars

<# 
As per the cloud-init documentation clear text passwords are not allowed in a cloud-init script. The password in this file needs to be hashed with SHA-512-CRYPT (this is not the same as regular SHA-512)
The easiest way to create this hash is to open a linux terminal and use 'mkpasswd --method=SHA-512 --rounds=4096' OR openssl passwd -6 '<password>' (that last one might also work on a mac). Alternatively you can use
https://www.mkpasswd.net/index.php. In the type field select crypt-sha512. (I personally do not like to generate my passwords via an online tool as i do not know what they will store and how this can be related back to me)
The result should always start with $6$ (This header means it is sha-512-crypt)
#>

$newUserName = "user1"                                    # Username for user to add to new vm
$paswdhash = '"$6$q62nNQPQ2Z0/ZZhH$6CKoyqvPCKNVW8NTDEN3UcPbqOiHUlWfmqA7aY4cZxFNmrZk5D1R0LsX8QHqRazCuYa3q2YMXKk3.ZOfE.xie0"' # Hashed passwd (welkom00) !! READ MESSAGE ABOVE !! also, note the double quotes ('"xxxx"')

# ---------------------------------------------------------------------------- #
# ---------- You should not need to change anything below this line ---------- #
# ---------------------------------------------------------------------------- #

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

# Many actions are asynchronous, often we need a way to wait for a returned taskTag to complete before taking further action. The below function facilitates this.

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

# generate the cloud-init userdata

$cloudinitBody = "#cloud-config
fqdn: $newVmName
package_update: true
package_upgrade: true
packages: [qemu-guest-agent]
users:
  - default
  - name: $newUserName
    passwd: $paswdhash
    shell: /bin/bash
    lock-passwd: false
    ssh_pwauth: True
    chpasswd: { expire: False }
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
power_state:
    delay: now
    mode: reboot
    message: Rebooting machine
"

#generate the Base64 string for cloud-init userdata

$base64String = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cloudinitBody)) 

# generate the correct url from the vars inventoried at the beginning of the script.

$apiURL = "https://$node/rest/v1/VirDomain/$templateUUID/clone"

# generate the body for the api call

$Body1 = ConvertTo-Json @{
    snapUUID = ""
    template = @{
        name = $newVmName
        tags = $newVmTags
    
    cloudInitData = @{
        metaData = ""
        userData = $base64String
        }
    }
}

# Perform the clone action

$result = Invoke-RestMethod -Method 'Post' -Uri $apiURL -WebSession $mywebsession @restOpts -Body $Body1
Wait-ScaleTask -TaskTag $($result.taskTag)

# Register the UUID for the new VM in a var so we can tell the API to start it.

$clonedVM = $result.createdUUID

# Start the VM we have just created

$actionUrl = "https://$node/rest/v1/VirDomain/action"

$Body2 = ConvertTo-Json @(@{
    actionType = "START"
    virDomainUUID = "$clonedVM"
    })
    
Invoke-RestMethod -Method 'POST' -Uri $actionUrl -WebSession $mywebsession @restOpts -Body $Body2 | Out-Null


# Log out of the session (remove session key from scale system) and output 'done' to console

Invoke-RestMethod -Method Post -Uri https://$node/rest/v1/logout -WebSession $mywebsession
Write-Host done
