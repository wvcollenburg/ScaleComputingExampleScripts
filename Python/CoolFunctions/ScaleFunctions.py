import requests
import json
import time
import urllib3

# The below is to ignore self-signed certificate. This is a bad practice. I need to figure out some way to get the node cert and ca
# and write thos as a PEM to the OS. (also not something i like, but at least then this is also applicable to stuff that is properly
# setup)

# Suppress only the single warning from urllib3.
urllib3.disable_warnings(category=urllib3.exceptions.InsecureRequestWarning)


def sc_login(username: str, password: str, node: str) -> dict:
    """
    perform login to the hypercore API

    This function performs an API login and returns a cookie variable that can be added to the headers for further
    actions against the API. Make sure to always end and/or exit with a logout as otherwise the session will be valid
    for another 100 days.

    :example:
    >>> sc_login("admin", "admin", "192.168.0.1")
    sessionID=7d00a7a3-d510-4f99-bb7f-d214a8c4e74d


    :param username: A valid hypercore username.
    :type username: str
    :param password: The password for the used username.
    :type password: str
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: session cookie string
    :rtype: dict
    :raises Exception: Failure description.
    """

    login_payload = json.dumps({
        "username": username,
        "password": password,
        "useOIDC": False
    })

    api_headers = {
        'Content-Type': 'application/json'
    }

    api_login = 'https://' + node + '/rest/v1/login'

    login_response = requests.request("POST",
                                      api_login,
                                      headers=api_headers,
                                      data=login_payload,
                                      verify=False
                                      )

    if login_response.status_code == 401:
        print(login_response.status_code)
        raise Exception(f'Login failed.')
    if login_response.status_code == 500:
        print(login_response.status_code)
        raise Exception(f'An internal error occurred.')

    api_headers['Cookie'] = 'sessionID={0}'.format(
        login_response.cookies.get('sessionID'))
    return api_headers


def sc_logout(api_headers: dict, node: str) -> bool:
    """
    Log out from the Hypercore API

    This function performs an API Logout. It returns nothing. Logging out of the cluster is very important
    as lingering sesions can exist for a year. If a malicious party were to find a valid session they would
    potentially gain destructive access to the cluster.

    :example:
    >>> sc_logout(api_headers_dict, "192.168.0.1")

    :param api_headers: a dict with the api headers that include the sessionID cookie.
    :type username: dict
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: bool
    :raises Exception: Failure description.
    """

    api_logout = 'https://' + node + '/rest/v1/logout'
    logout_response = requests.request("POST",
                                       api_logout,
                                       headers=api_headers,
                                       verify=False
                                       )

    if logout_response.status_code == 200:
        return True
    else:
        return False


def sc_wait_for_task(api_headers: dict, sctag: str, timeout: int, node: str) -> bool:
    """
    Wait for task to complete

    Many actions are asynchronous, often we need a way to wait for a returned taskTag to complete before taking further action.
    This function returns True if the task is completed successfully and Falso is an error is reported. If the timeout is reached
    it will raise an error and terminate execution

    :example:
    >>> sc_wait_for_task(api_headers_dict, "123456", 3600, "192.16.0.1")
    True

    :param api_headers: a dict with the api headers that include the sessionID cookie.
    :type api_headers: dict
    :param sctag: A string with the task tag returned by another function.
    :type sctag: str
    :param timeout: Timeout for this function in seconds.
    :type timeout: int
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: bool
    :raises Exception: Failure description.
    """

    api_tasktag = 'https://' + node + '/rest/v1/TaskTag/' + str(sctag)
    # tasks needs to be completed within this time in secconds
    wait_timeout = time.time() + timeout

    while time.time() < wait_timeout:
        task_check = requests.request("GET",
                                      api_tasktag,
                                      headers=api_headers,
                                      verify=False)

        task_check_json = json.loads(task_check.text)
        if task_check_json[0]["state"] == "COMPLETE":
            return True
        elif task_check_json[0]["state"] == "ERROR":
            return False
        else:
            # wait for 2 seconds before re-testing to prevent ddos-ing the api
            time.sleep(2)
    raise Exception(
        f'Timeout for task reached! The task might still be running on the cluster, please inspect cluster logs')


def sc_get_all_vminfo(api_headers: dict, node: str) -> dict:
    """
    Load all vm info in disct

    This function allows you to retreive vm info into a dict. As this loads info for all vm's at once this functions
    intended use is for itterative operations where it is required to perform your own actions on all vms

    :example:
    >>> sc_get_all_vminfo(var_with_headers_dict, "192.168.0.1")
    dict

    :param api_headers: a dict with the api headers that include the sessionID cookie.
    :type api_headers: dict
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: dict
    :raises Exception: Failure description.
    """

    api_virdomain = 'https://' + node + '/rest/v1/VirDomain/'
    virdomain_response = json.loads(requests.request("GET",
                                                     api_virdomain,
                                                     headers=api_headers,
                                                     verify=False
                                                     ).text)
    return virdomain_response


def sc_get_vm_info(type: str, identifier: str, api_headers: dict, node: str) -> dict:
    """
    Load all specific vm info in disct

    This function allows you to retreive vm info for a particula vm into a dict. As this fuction retrieves info for a single
    vm it is targeted at single vm operations

    :example:
    >>> sc_get_vminfo("vm", "testvm01", var_with_headers_dict, "192.168.0.1")
    dict

    :param type: this can be either "vm" or "uuid".
    :type type: str
    :param identifier: The name or uuid for a vm depending on what was requested in type
    :type identifier: str
    :param api_headers: a dict with the api headers that include the sessionID cookie.
    :type api_headers: dict
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: dict
    :raises Exception: Failure description.
    """

    match type:
        case "vm":
            vm_uuid: str = sc_get_uuid("vm", identifier, api_headers, node)
        case "uuid":
            vm_uuid = identifier

    api_virdomain = 'https://' + node + '/rest/v1/VirDomain/' + vm_uuid
    virdomain_response = json.loads(requests.request("GET",
                                                     api_virdomain,
                                                     headers=api_headers,
                                                     verify=False
                                                     ).text)
    return virdomain_response


def sc_get_all_nodeinfo(api_headers: dict, node: str) -> dict:
    """
    Load all Node info in disct

    This function allows you to retreive node info into a dict. As this loads info for all nodes at once this functions
    intended use is for itterative operations where it is required to perform your own actions on all nodes.

    :example:
    >>> sc_get_all_nodeinfo(var_with_headers_dict, "192.168.0.1")
    dict

    :param api_headers: a dict with the api headers that include the sessionID cookie.
    :type api_headers: dict
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: dict
    :raises Exception: Failure description.
    """

    api_virdomain = 'https://' + node + '/rest/v1/Node/'
    virdomain_response = json.loads(requests.request("GET",
                                                     api_virdomain,
                                                     headers=api_headers,
                                                     verify=False
                                                     ).text)
    return virdomain_response


def sc_get_uuid(type: str, identifier: str, api_headers: dict, node: str) -> str:
    """
    Get UUID for a node or vm

    This function allows you to retreive the UUID for a virtual machine or a node. This is usefull when using other
    functions that can be targeted at a specific vm or node.

    :example:
    >>> sc_get_uuid("node", "192.168.0.1", session, host)
    dict

    :param type: definition of what uuid is needed. can be "vm" or "node"
    :type type: str
    :param identifier: either vm name or node lanIP address
    :type identifier: str
    :param api_headers: a dict with the api headers that include the sessionID cookie.
    :type api_headers: dict
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: str
    :raises Exception: Invalid type defined.
    """

    match type:
        case "vm":
            sc_info = sc_get_all_vminfo(api_headers, node)
            for svm in sc_info:
                if svm["name"].upper() == identifier.upper():
                    return svm["uuid"]

        case "node":
            sc_info = sc_get_all_nodeinfo(api_headers, node)
            for snode in sc_info:
                if snode["lanIP"] == identifier:
                    return snode["uuid"]

        case _:
            raise Exception(
                f'invalid type defined. First argument must a string containing the text vm or node')


def sc_get_by_tag(tag: str, api_headers: dict, node: str) -> dict:
    """
    Get a dict with all vms and their uuid with a given tag.

    This function searches for all virtual machines with a given tag, and then returns a dict with the vm's and
    their uuid. Use this function to identify all vm's that require an operation based on their tags.

    :example:
    >>> result = sc.sc_get_by_tag("linux", session, host)
    >>> print(result)
    {'TestVM01': '0946a2b5-f16b-44f8-823a-e682824a6261', 'TestVM02': 'acd74fde-b85c-48d9-85c3-841292ea0920'}

    :param tag: The tag to search for.
    :type tag: str
    :param api_headers: a dict with the api headers that include the sessionID cookie.
    :type api_headers: dict
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: str
    :raises Exception: Invalid type defined.
    """

    sc_info = sc_get_all_vminfo(api_headers, node)
    vm_list = {}
    for vm in sc_info:
        vm_tags_list = vm["tags"].split(",")
        if tag in vm_tags_list:
            key = vm["name"]
            vm_list[key] = vm["uuid"]
    return vm_list


def sc_snapshot(type: str, identifier: str, snapshot_label: str, api_headers: dict, node: str) -> dict:
    """
    Create a snapshot for one or more vms

    This function allows you to create virtual machine snapshots based on the uuid, name or tag of a virtual machine
    To run multiple snapshots use the 'tag' method.

    :example:
    >>> sc.sc_snapshot("tag", "exampletag", "scripted snap by tag", session, host)


    :param type: definition of snapshot to be made. Can be "uuid", "vm" or "tag"
    :type type: str
    :param identifier: uuid, vmname or tag to be snappped.
    :type identifier: str
    :param snapshot_label: label for the snapshot
    :type snapshot_label: str
    :param api_headers: a dict with the api headers that include the sessionID cookie.
    :type api_headers: dict
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: none
    :raises Exception: Error message


    """

    match type:
        case "uuid":
            api_snapshot = 'https://' + node + '/rest/v1/VirDomainSnapshot/'
            snapshot_payload = json.dumps({
                "domainUUID": identifier,
                "label": snapshot_label
            })
            snapshot_response = json.loads(requests.request("POST",
                                                            api_snapshot,
                                                            headers=api_headers,
                                                            data=snapshot_payload,
                                                            verify=False)
                                           .text)
            return snapshot_response

        case "vmname":
            get_uuid = sc_get_uuid("vm", identifier, api_headers, node)
            if get_uuid is None:
                raise Exception(
                    f'vm name {identifier} could not be found on the targeted cluster')
            api_snapshot = 'https://' + node + '/rest/v1/VirDomainSnapshot/'
            snapshot_payload = json.dumps({
                "domainUUID": get_uuid,
                "label": snapshot_label
            })
            snapshot_response = json.loads(requests.request("POST",
                                                            api_snapshot,
                                                            headers=api_headers,
                                                            data=snapshot_payload,
                                                            verify=False)
                                           .text)
            return snapshot_response

        case "tag":
            to_snap_dict = sc_get_by_tag(identifier, api_headers, node)
            if not to_snap_dict:
                raise Exception(f'No VMs with tag {identifier} were found')
            for get_uuid in to_snap_dict.values():
                api_snapshot = 'https://' + node + '/rest/v1/VirDomainSnapshot/'
                snapshot_payload = json.dumps({
                    "domainUUID": get_uuid,
                    "label": snapshot_label
                })
                snapshot_response = json.loads(requests.request("POST",
                                                                api_snapshot,
                                                                headers=api_headers,
                                                                data=snapshot_payload,
                                                                verify=False)
                                               .text)
                print(f'snapshot made for {get_uuid}')


def sc_change_tag(type: str, identifier: str, method: str, tags: list, api_headers: dict, node: str) -> None:
    """
    Change tags and tag order for vm's

    This function allows you to change tags and grouping for virtual machines. 

    :example:
    >>> sc_change_tag("vm", "test123", "group", "dmo", session, host)


    :param type: definition of vm to be changed. Can be "uuid" or "vm"
    :type type: str
    :param identifier: uuid or vm to be changed.
    :type identifier: str
    :param method: which method will be used, can be "add", "remove", "group" or "manual"
    :type method: str
    :param tags: tag to add, remove, group by, or comma delimited manual list.
    :type snapshot_label: str
    :param api_headers: a dict with the api headers that include the sessionID cookie.
    :type api_headers: dict
    :param node: IP address or FQDN for a scale computing node, this can be any node in the cluster you are managing.
    :type node: str
    :return: none
    :raises Exception: Error message
    
    """

    vm_info = sc_get_vm_info(type, identifier, api_headers, node)
    vm_tags_list = vm_info[0]["tags"].split(",")

    match method:
        case "add":
            vm_tags_list.append(tags)
            vm_tags_str = ','.join(vm_tags_list)
        
        case "remove":
            if tags in vm_tags_list:
                vm_tags_list.remove(tags)
                vm_tags_str = ','.join(vm_tags_list)
                tagchange_payload = json.dumps({
                    "tags": vm_tags_str
                })
            else:
                raise Exception(f'requested tag remove for tag that is not registered with vm')

        case "group":
            if tags in vm_tags_list:
                vm_tags_list.remove(tags)
                vm_tags_list.insert(0, tags)
                vm_tags_str = ','.join(vm_tags_list)
                
            else:
                vm_tags_list.insert(0, tags)
                vm_tags_str = ','.join(vm_tags_list)

        case "manual":
            vm_tags_str = tags
    
    tagchange_payload = json.dumps({
        "tags": vm_tags_str
        })
    
    api_tagchange = 'https://' + node + '/rest/v1/VirDomain/' + vm_info[0]["uuid"]
    tagchange_response = json.loads(requests.request("POST",
                                                     api_tagchange,
                                                     headers=api_headers,
                                                     data=tagchange_payload,
                                                     verify=False)
                                    .text)
    return tagchange_response


if __name__ == "__main__":
    print("This script was never intended to be run directly. Feel free to do so, but a more elegant way would be to import it"
          " as a module into your own code.")
