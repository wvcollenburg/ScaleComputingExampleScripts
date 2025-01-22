#!/bin/bash

SCUSERNAME="admin"
SCPASSWD="admin"
SCNODE="192.168.0.1"
S_VMUUID="8485f751-3e02-458a-89c9-0ccc2f38d681"
T_VMUUID="a2169e73-b1b1-486e-acc3-fe9f10e30d1b"

Wait-ScaleTask () {
    echo "Waiting for task $1 to complete"
    taskCheckResult=""
    taskTime=0
    while [ $taskTime -le 150 ]
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

curl -s -k -X POST https://$SCNODE/rest/v1/login -H 'Content-Type: application/json' -d '{"username":"'"${SCUSERNAME}"'","password":"'"${SCPASSWD}"'"}' -c ./cookie >/dev/null

RESULT1="$(curl -s -k --cookie ./cookie -X 'POST' 'https://'$SCNODE'/rest/v1/VirDomainSnapshot' -H 'accept: application/json' -H 'Content-Type: application/json' -d '{"domainUUID":"'"${S_VMUUID}"'","label":"scripted snapshot"}')"
taskID=$( echo ${RESULT1} | jq -r .taskTag )
newSnapUUID=$( echo ${RESULT1} | jq -r .createdUUID )
Wait-ScaleTask $taskID

GETSNAPINFO=$(curl -s -k --cookie ./cookie -X 'GET' 'https://'$SCNODE'/rest/v1/VirDomainSnapshot/'$newSnapUUID -H 'accept: application/json')
DISK2CLONE=$( echo $GETSNAPINFO | jq  -r '.[].domain.blockDevs[] | select(.type=="VIRTIO_DISK") | .uuid' )
SIZEOFCLONE=$( echo $GETSNAPINFO | jq  -r '.[].domain.blockDevs[] | select(.uuid=="'"$DISK2CLONE"'") | .capacity' )

JSONBODY=$(jq -n -c \
    --arg snapUUID "$newSnapUUID" \
    --argjson options "{\"readOnly\": false, \"regenerateDiskID\" : false}" \
    --argjson template "{ \"capacity\" : $SIZEOFCLONE, \"tieringPriorityFactor\" : 8, \"virDomainUUID\" : \"$T_VMUUID\", \"type\": \"VIRTIO_DISK\"}" \
    '$ARGS.named'
)

CLONEDDISKRESULT=$(curl -s -k --cookie ./cookie -X POST https://$SCNODE/rest/v1/VirDomainBlockDevice/$DISK2CLONE/clone -H 'accept: application/json' -H 'Content-Type: application/json' -d $JSONBODY)
DISK2DELETE=$( echo ${CLONEDDISKRESULT} | jq -r .createdUUID )
TaskID=$(echo ${CLONEDDIKSRESULT} | jq -r .taskTag )

Wait-ScaleTask $taskID

echo 'A snapshot has been made with the UUID '$newSnapUUID'. The disk for this snapshot has UUID '$DISK2CLONE', which has been cloned to VM 'T_VMUUID' with a new UUID of '$DISK2DELETE'.'
echo "Your own backup mechanisms should be in place of this message. This can include rsync, smb copy or even more advanced options with Acronis or other backup software"
echo " "
echo "Press any key to continue..." 
read -n 1 -s

DISKDELETERESULT=$(curl -s -k --cookie ./cookie -X 'DELETE' 'https://'$SCNODE'/rest/v1/VirDomainBlockDevice/'$DISK2DELETE -H 'accept: application/json')
TaskID=$(echo ${DISKDELETERESULT} | jq -r .taskTag )
Wait-ScaleTask $taskID

DELSNAPRESULT=$(curl -s -k --cookie ./cookie -X 'DELETE' 'https://'$SCNODE'/rest/v1/VirDomainSnapshot/'$newSnapUUID -H 'accept: application/json')
taskID=$( echo ${DELSNAPRESULT} | jq -r .taskTag )
Wait-ScaleTask $taskID

curl -s -k --cookie ./cookie -X 'POST'   'https://'$SCNODE'/rest/v1/logout'   -H 'accept: application/json'
