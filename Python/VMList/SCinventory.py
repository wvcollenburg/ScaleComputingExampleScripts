#!/usr/bin/env python3

"""

Script to demonstrate login, setting cookie and using cookies sessionID to retrieve a list of vm's, and finally logging out.

THIS SCRIPT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND
feel free to use without attribution in any way as seen fit, at your own risc.

Usage: Fill out the variables below and run the script.

William David van Collenburg
Scale Computing

dependencies: requests, json

"""

# import required modules
import requests
import json
import time

# the below module suppresses SSL warnings. It comes without saying that you should not use this. It is in here for educational reasons
import urllib3
# Suppress only the single warning from urllib3.
urllib3.disable_warnings(category=urllib3.exceptions.InsecureRequestWarning)
# all requests below have 'verify=False' added to it. If your system has proper certificates installed remove False and replace it with
# your certificate path.

# set required variables
username = "doademo"
password = "doademo"
url = "https://172.16.0.241/"
measure_in_hours = 6

# You should not have to change anything below this point for the script to work as designed.

# vars for quickly using the endpoints we want to access
prefix = url + 'rest/v1/'
api_login = prefix + 'login'
api_logout = prefix + 'logout'
api_virdomain = prefix + 'VirDomain'
api_node = prefix + 'Node'

# creating the bodies and headers we need
login_payload = json.dumps({
    "username": username,
    "password": password,
    "useOIDC": False
    })

api_headers = {
    'Content-Type': 'application/json'
}

# logging in

login_response = requests.request("POST", 
                                  api_login,
                                  headers=api_headers,
                                  data=login_payload,
                                  verify=False
)


# update api_headers to include the cookie with the sessionID in it

api_headers['Cookie'] = 'sessionID={0}'.format(login_response.cookies.get('sessionID'))

# get the virdomain list - the list all generic info on vm's

virdomain_response = requests.request("GET",
                                      api_virdomain,
                                      headers=api_headers,
                                      verify=False
)

# dump the json output into a dict. Later on in this script i have done this in a single command.

virdomain_json = json.loads(virdomain_response.text)

# now iterate over the array that has just been created and put the vm infos in a .csv
# using the with open(.... ) statement makes sure we close the file at the end of the with block. No need to manually close.

with open("vmOverview.csv", "w") as f:
    f.write("vmname, state, VCPUs, RAM, Snapshots, VMType, Location, DriveType, SizeGB, Allocated%\n")

    for vm in virdomain_json:
        if vm['state'] in("RUNNING", "SHUTOFF"):
            api_virdomainstats = prefix + 'VirDomainStats/' + vm['uuid']
            
            f.write(vm['name']
                    + ", " + vm['state']
                    + ", " + str(vm['numVCPU'])
                    + ", " + str(vm['mem'] / 1024**3)
                    + ", " + str(len(vm['snapUUIDs']))
                    + ", " + vm['machineType']
                    )
            
            if not vm['sourceVirDomainUUID'] == "":
                f.write(", REPLICA")
            else:
                f.write(", LOCAL")


            for disk in vm['blockDevs']:
                if disk['type'] == "VIRTIO_DISK" or disk['type'] == "IDE_DISK":
                    f.write(", " + disk['type'])
                    f.write(", " + str(round(disk['capacity'] / 1000**3, 2)))
                    f.write(", " + str(round(disk['allocation'] / disk['capacity'] * 100, 2)))
            

            f.write("\n")

# Lets do the same for the nodes. Read the /node endpoint, iterate over the nodes and put their infos in a .csv
# This time i immediately dump the json response in a dict. Important to make sure you end with the .text. if you forget it will store the result (http 200)

node_response = json.loads(requests.request("GET",
                                      api_node,
                                      headers=api_headers,
                                      verify=False
                                      ).text)

with open("nodeOverview.csv", "w") as p:
    p.write("lanIP, backplaneIP, NodeCapacity, RAMsize, RAMusage, CPUspeed, Sockets, Cores, Threads, NumDrives, DriveSize, DriveUsed%\n")
    for node in node_response:
        p.write(node['lanIP'])
        p.write(", " + node['backplaneIP'])
        p.write(", " + str(round(node['capacity'] / 1000**3, 2)))
        p.write(", " + str(round(node['memSize'] / 1024**3, 2)))
        p.write(", " + str(round(node['totalMemUsageBytes'] / 1024**3, 2)))
        p.write(", " + str(round(node['CPUhz'] / 1000**3, 2)))
        p.write(", " + str(node['numSockets']))
        p.write(", " + str(node['numCores']))
        p.write(", " + str(node['numThreads']))
        p.write(", " + str(len(node['drives'])))

        for disk in node['drives']:
            p.write(", " + str(round(disk['disks']['scribe']['capacityBytes'] / 1000**3, 2)))
            p.write(", " + str(round(disk['disks']['scribe']['usedBytes'] / disk['disks']['scribe']['capacityBytes'] * 100, 2)))
        
        p.write("\n")

# Now lets start doing some performance measurements. For this we are going to request data from the API every 1 minute
# We need to be carefull with this because we do not want to DDoS our API / GUI. Setting this shorter than every minute
# might have a negative impact on the cluster.
#
# Lets open two more files, one with Node performance data, and one with vms performance data.

with open("nodePerf.csv", "w") as np, open("vmPerf.csv", "w") as vp:
    vp.write("epoch, name, cpu%, rxBit, txBit\n")
    # calculate untill which time in epoch we will run (epoch is time measured in seconds)
    r_until = time.time() + (measure_in_hours * 3600)
    # r_until = time.time() + 120
    # keep looping until we reach the above calculated time
    while time.time() < r_until:
        # Next i am going to reuse the earlier virdomain_json to iterate over all vm's, but now to retrieve their perf data
        now = str(time.time())
        for pvm in virdomain_json:
            api_virdomainstats = prefix + 'VirDomainStats/' + pvm['uuid']
            stat_response = json.loads(requests.request("GET",
                                                        api_virdomainstats,
                                                        headers=api_headers,
                                                        verify=False).text)
            vp.write(now)
            vp.write(", " + pvm["name"])
            vp.write(", " + str(round(stat_response[0]['cpuUsage'], 4)))
            vp.write(", " + str(round(stat_response[0]['rxBitRate'], 4)))
            vp.write(", " + str(round(stat_response[0]['txBitRate'], 4)))
            vp.write("\n")

        time.sleep(30)


# logging out again

logout_response = requests.request("POST",
                                   api_logout,
                                   headers=api_headers,
                                   verify=False
)
