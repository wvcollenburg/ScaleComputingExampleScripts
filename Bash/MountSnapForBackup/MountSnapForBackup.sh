#!/bin/bash

# William David van Collenburg
# Scale Computing

# This script demonstrates taking a snapshot from one virtual machine and attaching it's disk to another system for backup purposes.
# At the end of the backup, remove the disk from the backup system and delete the snapshot.

# THIS SCRIPT IS PROVIDED "AS IS",WITHOUT WARRANTY OF ANY KIND
# feel free to use without attribution in any way as seen fit, at your own risc.

# This script has 2 dependencies:
# curl - https://curl.se/ - command line tool and library for transferring data with URLs
# jq - https://jqlang.github.io/jq/ - lightweight and flexible command-line JSON processor

# The Scale Computing user that runs this script needs have the following rights on the cluster:
# Backup - to be able to create and delete the snapshots
# VM Create / Edit -  to be able to attach the cloned virtual disk to the target VM
# VM Delete - to be able to delete the virtual disk from the target VM once backup is done
#
# The user should not have access to cluster settings, cluster shutdown and VM Power Controls

SCUSERNAME="admin"
SCPASSWD="admin"
SCNODE="192.168.0.1"

# To know which VM is the source and the target we use the UUID of these VMs. The easiest way to find these UUIDs is by opening a console to the VM in the UI, the new tab that will be opened
# has the UUID at the end. Alternatively you could read the VirDomain list (https://$SCNODE/rest/v1/VirDomain) and use jq to find the UUID for a specific VM name.

S_VMUUID="8485f751-3e02-458a-89c9-0ccc2f38d681"
T_VMUUID="a2169e73-b1b1-486e-acc3-fe9f10e30d1b"

# !-- you should not have to change anything below this line to make the demonstration work --!
# !-- for training purposes i have added a lot of comments to explain what the script does  --!

# During the running of this script we will often have to wait for tasks to complete. The scale computing API provides a means to this by declaring a taskTag. This taskTag can be queried the status of that task
# the following function, when called with a valid taskTag will create a loop untill the taskTag reports back as COMPLETE. In this example state there is no reference to the other states, but as per example the
# API can also report an error on a task. As it is created right not the script will continue once time out has been reaches. this will most likely produce more errors. Better time-out management should be done

Wait-ScaleTask () {
    echo "Waiting for task $1 to complete"
    taskCheckResult=""
    taskTime=0
    while [ $taskTime -le 150 ] # in increments of 2 seconds (sleep 2 just below this) 150 means a time-out for the task of 300 seconds / 5 minutes.
    do
        sleep 2
        taskCheck=$(curl -s -k --cookie ./cookie -X 'GET' 'https://'$SCNODE'/rest/v1/TaskTag/'$1)
        taskCheckResult=$( echo $taskCheck | jq -r .[].state)
        if [[ "$taskCheckResult" == "COMPLETE" ]]
	then
		break
	fi
		taskTime=$(( $taskTime + 1 ))
	done
}


# login to Scale Computing system and write sessionID to file called cookie in same dir as script. (be aware that the end of this script also contains a logout command. This is very important as this invalidates the session)
# If you fail to logout of the session, the SessionID set in ./cookie would be usable by anyone who can read that file to gain access to the cluster. Also considder deleting the file itself after logout.
curl -s -k -X POST https://$SCNODE/rest/v1/login -H 'Content-Type: application/json' -d '{"username":"'"${SCUSERNAME}"'","password":"'"${SCPASSWD}"'"}' -c ./cookie >/dev/null

# Now lets make the snapshot. the endpoint for this is /VirDomainSnapshot. Check var S_VMUUID. This should be set to the VM that needs to backed up, e.g. the Source VM.
# an easy way to locate the UUID for a VM is to open a console to that vm. The URL for that console will have the UUID as the last string. is should look like '8485f751-3e02-458a-89c9-0ccc2f38d681'
# The output of the snapshot command is a taskTag (which we will use to monitor progress) and a createdUUID (the UUID of the snapshot that was created) which we will need to attach it to another VM

RESULT1="$(curl -s -k --cookie ./cookie -X 'POST' 'https://'$SCNODE'/rest/v1/VirDomainSnapshot' -H 'accept: application/json' -H 'Content-Type: application/json' -d '{"domainUUID":"'"${S_VMUUID}"'","label":"scripted snapshot"}')"
taskID=$( echo ${RESULT1} | jq -r .taskTag )
newSnapUUID=$( echo ${RESULT1} | jq -r .createdUUID )

# wait for snapshot to complete
Wait-ScaleTask $taskID

# Get info out of the snapshot (the snapshot will come with it's own storage device UUIDs etc), Identify the disk we need and attach it to the backup target. I am assuming a single HDD on the VM, if there are more
# virtual HDD's attached to the VM, you might also want to consider selecting the right disk based on the mountpoints on the disk, but this requires the qemu-guest-agent to be installed on the VM.

GETSNAPINFO=$(curl -s -k --cookie ./cookie -X 'GET' 'https://'$SCNODE'/rest/v1/VirDomainSnapshot/'$newSnapUUID -H 'accept: application/json')
DISK2CLONE=$( echo $GETSNAPINFO | jq  -r '.[].domain.blockDevs[] | select(.type=="VIRTIO_DISK") | .uuid' )
SIZEOFCLONE=$( echo $GETSNAPINFO | jq  -r '.[].domain.blockDevs[] | select(.uuid=="'"$DISK2CLONE"'") | .capacity' )

# As the 'clone to vm' request is more complex, and for demonstration purposes i have created the body for this request in another way, using jq -n. The -c option is used to make sure the JSON is outputted as a single string.

JSONBODY=$(jq -n -c \
    --arg snapUUID "$newSnapUUID" \
    --argjson options "{\"readOnly\": false, \"regenerateDiskID\" : false}" \
    --argjson template "{ \"capacity\" : $SIZEOFCLONE, \"tieringPriorityFactor\" : 8, \"virDomainUUID\" : \"$T_VMUUID\", \"type\": \"VIRTIO_DISK\"}" \
    '$ARGS.named'
)

# perform the clone operation based on the body above, and get set the var's for deleting the disk in the cleanup phase.
CLONEDDISKRESULT=$(curl -s -k --cookie ./cookie -X POST https://$SCNODE/rest/v1/VirDomainBlockDevice/$DISK2CLONE/clone -H 'accept: application/json' -H 'Content-Type: application/json' -d $JSONBODY)
DISK2DELETE=$( echo ${CLONEDDISKRESULT} | jq -r .createdUUID )
TaskID=$(echo ${CLONEDDIKSRESULT} | jq -r .taskTag )

Wait-ScaleTask $taskID

# !-- The prerequisites for the backup have now been met, and the backup script can be inserted below this. For the purpose of the script a manual break will be made here. this can be replaced
# !-- with the backup logic. This includes having to mount the correct disk to the operating system. Since this procedure can differe based on which volume manager is used i have not included
# !-- this step here.

echo 'A snapshot has been made with the UUID '$newSnapUUID'. The disk for this snapshot has UUID '$DISK2CLONE', which has been cloned to VM 'T_VMUUID' with a new UUID of '$DISK2DELETE'.'
echo "Your own backup mechanisms should be in place of this message. This can include rsync, smb copy or even more advanced options with Acronis or other backup software"
echo " "
echo "Press any key to continue..." 
read -n 1 -s   # Waits for a single key press silently 

# Clean up phase, Delete the new disk from the backup target and delete the snapshot on the source. (Deleting the snapshot could be done directly after attaching the disk to the backup target
# but by doing it at the end, when something fails and the script terminates prematurely we would still have the snapshot. You might even consider builing in some error-handling to retain snapshot
# whenever a backup or something else in this script fails.

# Delete the attached disk from the target VM

DISKDELETERESULT=$(curl -s -k --cookie ./cookie -X 'DELETE' 'https://'$SCNODE'/rest/v1/VirDomainBlockDevice/'$DISK2DELETE -H 'accept: application/json')
TaskID=$(echo ${DISKDELETERESULT} | jq -r .taskTag )
Wait-ScaleTask $taskID

# Delete snapshot from source vm

DELSNAPRESULT=$(curl -s -k --cookie ./cookie -X 'DELETE' 'https://'$SCNODE'/rest/v1/VirDomainSnapshot/'$newSnapUUID -H 'accept: application/json')
taskID=$( echo ${DELSNAPRESULT} | jq -r .taskTag )
Wait-ScaleTask $taskID

# logout of the Scale Computing session which invalidates the session ID written in the cookie. Consider also adding a delete for the cookie file (./cookie) after the logout, although the info in it
# is useless after the logout. (that sessionID is no longer valid)
curl -s -k --cookie ./cookie -X 'POST'   'https://'$SCNODE'/rest/v1/logout'   -H 'accept: application/json'
