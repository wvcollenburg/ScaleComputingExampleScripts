import ScaleFunctions as sc

host = "192.168.1.11"
session = sc.sc_login("doademo", "doademo", host)

sc.sc_change_tag("vm", "nameOfVm", "group", "demo", session, host)

sc.sc_logout(session, host)
