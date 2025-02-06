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
username = "admin"              # scale computing cluster user with at minimal READ permissions
password = "admin"              # scale computing cluster password
url = "https://192.168.0.11/"   # URL to cluster
measure_in_hours = 6

# \|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||/ #
# -   You should not have to change anything below this point for the script to work as designed.   - #
# /|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||\ #

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
with open("vmOverview.csv","w") as f:
    f.write("vmname,state,VCPUs,RAM,Snapshots,VMType,Location,DriveType1,SizeGB1,AllocatedPct1,DriveType2,SizeGB2,AllocatedPct2\n")

    for vm in virdomain_json:
        if vm['state'] in("RUNNING","SHUTOFF"):
            api_virdomainstats = prefix + 'VirDomainStats/' + vm['uuid']
            
            f.write(vm['name']
                    + "," + vm['state']
                    + "," + str(vm['numVCPU'])
                    + "," + str(vm['mem'] / 1024**3)
                    + "," + str(len(vm['snapUUIDs']))
                    + "," + vm['machineType']
                    )
            
            if not vm['sourceVirDomainUUID'] == "":
                f.write(",REPLICA,NO_DISK,0,0,NO_DISK,0,0")
            else:
                f.write(",LOCAL")
            
            disk_count = 8
            for disk in vm['blockDevs']:
                if disk['type'] == "VIRTIO_DISK" or disk['type'] == "IDE_DISK": # ugly OR version, cooler OR later in script (if disk in ('comma, delimited, list'))
                    f.write("," + disk['type'])
                    f.write("," + str(round(disk['capacity'] / 1000**3, 2)))
                    f.write("," + str(round(disk['allocation'] / disk['capacity'] * 100, 2)))
                    disk_count -= 1
            if disk_count == 7:
                f.write(",NO_DISK,0,0")
            f.write("\n")

# Lets do the same for the nodes. Read the /node endpoint, iterate over the nodes and put their infos in a .csv
# This time i immediately dump the json response in a dict. Important to make sure you end with the .text. if you forget it will store the result (http 200)
node_response = json.loads(requests.request("GET",
                                      api_node,
                                      headers=api_headers,
                                      verify=False
                                      ).text)

with open("nodeOverview.csv","w") as p:
    p.write("lanIP,backplaneIP,NodeCapacity,RAMsize,RAMusage,CPUspeed,Sockets,Cores,Threads,NumDrives,DriveSize,DriveUsedPct\n")
    for node in node_response:
        p.write(node['lanIP'])
        p.write("," + node['backplaneIP'])
        p.write("," + str(round(node['capacity'] / 1000**3, 2)))
        p.write("," + str(round(node['memSize'] / 1024**3, 2)))
        p.write("," + str(round(node['totalMemUsageBytes'] / 1024**3, 2)))
        p.write("," + str(round(node['CPUhz'] / 1000**3, 2)))
        p.write("," + str(node['numSockets']))
        p.write("," + str(node['numCores']))
        p.write("," + str(node['numThreads']))
        p.write("," + str(len(node['drives'])))

        for disk in node['drives']:
            p.write("," + str(round(disk['disks']['scribe']['capacityBytes'] / 1000**3, 2)))
            p.write("," + str(round(disk['disks']['scribe']['usedBytes'] / disk['disks']['scribe']['capacityBytes'] * 100, 2)))
        
        p.write("\n")

# Now lets start doing some performance measurements. For this we are going to request data from the API every 10 seconds
# We need to be carefull with this because we do not want to DDoS our API / GUI. Stats in cluster are refreshed every 10
# seconds so there is no benefit of polling at a higher frequency. There will be some rapid successive check while iterating.

# Lets open two more files, one with Node performance data, and one with vms performance data.
with open("nodePerf.csv","w") as np, open("vmPerf.csv","w") as vp:
    # set headers for both csv files
    vp.write("epoch,name,numVCPU,cpuPct,cpuGhz,vmGhz,rxBit,txBit,DiskType1,IOPsread1,IOPswrite1,latencyReadUm1,latercyWriteUm1,DiskType2,IOPsread2,IOPswrite2,latencyReadUm2,latercyWriteUm2\n")
    np.write("lanIP,memSize,totalMemUsageBytes,memUsagePercentage,cpuUsagePct\n")

    # calculate untill which time in epoch we will run (epoch is time measured in seconds)
    r_until = time.time() + (measure_in_hours * 3600)

    # keep looping until we reach the above calculated time
    while time.time() < r_until:

        # Next i am going to reuse the earlier virdomain_json to iterate over all vm's, but now to retrieve their perf data
        now = str(int(time.time())) # I am going to use this data later in grafana so need to strip the decimals (infini plugin doesnt understand decimals)
        for pvm in virdomain_json:
            api_virdomainstats = prefix + 'VirDomainStats/' + pvm['uuid']
            stat_response = json.loads(requests.request("GET",
                                                        api_virdomainstats,
                                                        headers=api_headers,
                                                        verify=False).text)
            
            # write data to vmPerf.csv
            vp.write(now)
            vp.write("," + pvm["name"])
            vp.write("," + str(pvm['numVCPU']))
            vp.write("," + str(round(stat_response[0]['cpuUsage'], 4)))
            for vpnode in node_response:
                if pvm['nodeUUID'] == vpnode['uuid']:
                    vp.write("," + str(round(vpnode['CPUhz'] / 1000**3 ,2)))
                    vp.write("," + str(round((vpnode['CPUhz'] * (stat_response[0]['cpuUsage'] / 100)) / 1000**3, 2)))
            vp.write("," + str(round(stat_response[0]['rxBitRate'], 4)))
            vp.write("," + str(round(stat_response[0]['txBitRate'], 4)))
            disk_count = 8
            for vdisk in pvm['blockDevs']:
                if vdisk['type'] in ("VIRTIO_DISK", "IDE_DISK"):
                    vp.write("," + vdisk['type'])
                    for stat_disk in stat_response[0]['vsdStats']:
                        if stat_disk['uuid'] == vdisk['uuid']:
                            vp.write("," + str(stat_disk['rates'][0]['millireadsPerSecond'] / 1000))
                            vp.write("," + str(stat_disk['rates'][0]['milliwritesPerSecond'] / 1000))
                            vp.write("," + str(stat_disk['rates'][0]['meanReadLatencyMicroseconds']))
                            vp.write("," + str(stat_disk['rates'][0]['meanWriteLatencyMicroseconds']))
                            disk_count -= 1
            if disk_count == 7:
                vp.write(",NO_DISK,0,0,0,0")
            vp.write("\n")
        vp.flush()
        
        # Get performance data for the Nodes. This is limited to CPU and RAM info
        stat_node_response = json.loads(requests.request("GET",
                                      api_node,
                                      headers=api_headers,
                                      verify=False
                                      ).text)
        
        # Write perf data to nodePerf.csv
        for snode in stat_node_response:
            np.write(snode['lanIP'])
            np.write("," + str(round(snode['memSize'] / 1024**3, 2)))
            np.write("," + str(round(snode['totalMemUsageBytes'] / 1024**3, 2)))
            np.write("," + str(round(snode['memUsagePercentage'], 2)))
            np.write("," + str(round(snode['cpuUsage'], 2)))
            np.write("\n")
        np.flush()
        
        time.sleep(10)      #stats on cluster are refreshed every 10 seconds so no need to check faster. again, also to prevent DoS-ing the API

# logging out again

logout_response = requests.request("POST",
                                   api_logout,
                                   headers=api_headers,
                                   verify=False
)
