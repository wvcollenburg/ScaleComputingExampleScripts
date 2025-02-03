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

# the below module suppresses SSL warnings. It comes without saying that you should not use this. It is in here for educational reasons
import urllib3
# Suppress only the single warning from urllib3.
urllib3.disable_warnings(category=urllib3.exceptions.InsecureRequestWarning)
# all requests below have 'verify=False' added to it. If your system has proper certificates installed remove False and replace it with
# your certificate path.

# set required variables
username = "doademo"
password = "doademo"
url = "https://edge.demolabs.me/"

# You should not have to change anything below this point for the script to work as designed.

# vars for quickly using the endpoints we want to access
prefix = 'rest/v1/'
api_login = url + prefix + 'login'
api_logout = url + prefix + 'logout'
api_virdomain = url + prefix + 'VirDomain'

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

# Below this point, all the way up to the logout response you can perform actions on the cluster.
# For this example script we are going to list the names of all VM's and their current state.

# get the virdomain list - the list all generic info on vm's

virdomain_response = requests.request("GET",
                                      api_virdomain,
                                      headers=api_headers,
                                      verify=False
)

# fix the formatting so python json can interpret properly (should not be nescesary but yields better results)

virdomain_json = json.loads(virdomain_response.text)

# now iterate over the array that has just been created and print the names of the vm's and their state

with open("output.csv", "w") as f:
    f.write("vmname, state, VCPUs, RAM, Snapshots, VMType, Location, DriveType, SizeGB, Allocated%\n")

    for vm in virdomain_json:
        if vm['state'] in("RUNNING", "SHUTOFF"):
            api_virdomainstats = url + prefix + 'VirDomainStats/' + vm['uuid']
            
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



#                    + ", " + (vm['blockDevs'][0]['uuid'])
#                    + ", " + str(round(virdomainstats_result[0]['vsdStats'][0]['rates'][0]['milliwritesPerSecond'] / 1000, 3))
#                    + ", " + str(round(virdomainstats_result[0]['vsdStats'][0]['rates'][0]['millireadsPerSecond'] / 1000, 3))
#                    + "\n"
#                    )



# logging out again

logout_response = requests.request("POST",
                                   api_logout,
                                   headers=api_headers,
                                   verify=False
)
