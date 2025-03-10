import requests
import json
# the below module suppresses SSL warnings. It comes without saying that you should not use this. It is in here for educational reasons
import urllib3
# Suppress only the single warning from urllib3.
urllib3.disable_warnings(category=urllib3.exceptions.InsecureRequestWarning)

def sc_login(username: str, password: str, node: str) -> str:
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
    :rtype: str
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

    return 'sessionID={0}'.format(login_response.cookies.get('sessionID'))

