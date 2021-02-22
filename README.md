# Generate-Unifi-Keystore
This script creates a valid keystore file to be used by UniFi Controller from letsencrypt generated certificates.
Useful when you're not running UC behind a forward proxy (such as nginx), but still want to use signed certificates.

It runs from the command line or cron and correctly handles all errors.

You can run this script from the command line by specifying the directory that contains the letsencrypt certificate,
and the directory you want the keystore file to be created.
 
## Command line examples
```
$ ./generate_unifi_keystore.sh /etc/letsencrypt/live/host.domain.tld/ /var/lib/unifi/
Success: Generated new UniFi Controller keystore.
$ ls /var/lib/unifi
backup	db  firmware.json  keystore  keystore.bck  model_lifecycles.json  sites
system.properties system.properties.bk
```
Any existing keystore file will be renamed to keystore.bck. Existing keystore.bck files are deleted.

You can omit the target directory and the script will create the keystore file in the current working directory.
```
$ ./generate_unifi_keystore.sh /etc/letsencrypt/live/host.domain.tld/
Success: Generated new UniFi Controller keystore.
$ ls -l keystore
-rw-r--r-- 1  user  user  5245  Feb 22 12:21 keystore
```

When running from the command line, the script will NOT set ownership or permissions of the keystore file, and
it will NOT restart the UniFi Controller service. It will only generate the keystore file as the current user.
You will need to move the keystore file to the correct location, set permissions, and then restart the UniFi
Controller service.

## Cron
If you want to automate the process, then you will need to modify the CRON section of the script with values
specific to your system.

E.g:

```
# Location of letsencrypt certs and the UniFi Controller keystore.
# Test on the command line first, and then add your paths in here.
letsencrypt_cert_dir=/etc/letsencrypt/live/host.domain.tld/
unifi_keystore_dir=/var/lib/unifi/

# Keystore owner and permissions.
USER=user
MODE=640

# Command to restart UniFi Controller.
restart_uc="docker restart unifi-controller"
# restart_uc="service unifi restart"
```
You will want to set 'USER' to the same user that UniFi Controller runs as. You shouldn't need to change MODE.

Drop the script into `/etc/cron.monthly/` and it will update your keystore when it detects a new certificate,
and then restart the UniFi Controller.

```
$ sudo cp ./generate_unifi_keystore.sh /etc/cron.monthly/
$ sudo chmod 750 /etc/cron.monthly/generate_unifi_keystore.sh
```

When run from cron, all output is directed to syslog...
```
$ tail -f /var/log/syslog
Feb 1 2:35:02 hostname generate_unifi_keystore.sh: Success: Generated new UniFi Controller keystore.
--snip--
Feb 1 2:35:10 hostname generate_unifi_keystore.sh: Success: UniFi Controller service restarted.
```
