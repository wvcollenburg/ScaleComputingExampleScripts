import ScaleFunctions as sc

host = "172.16.0.241"
session = sc.sc_login("doademo", "doademo", host)

sc.sc_change_tag("vm", "tagtestvm", "add", "platform", session, host)

sc.sc_logout(session, host)
