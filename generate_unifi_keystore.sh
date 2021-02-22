#!/usr/bin/env bash

# This script creates a valid keystore file to be used by UniFi Controller from 
# letsencrypt generated certificates. Useful when you're not running UC behind
# a forward proxy (such as nginx), but still want to use signed certificates.

# You can run this script from the command line by specifying the directory that
# contains the letsencrypt certificate, and the directory you want the keystore
# file to be created. See usage below.

# You can also drop this script into /etc/cron.monthly and it will update your
# keystore when it detects a new certificate, and then restart the UniFi Controller.
# If you want to use cron then you will need to set the variables for your system
# in the CRON section below.

# When run from cron, all output is directed to syslog.

if [[ -t 1 ]]; then 

usage() { 
	printf "\nUsage: $0 /etc/letsencrypt/live/host.domain.tld/ [ /var/lib/unifi/ ]
	
			The letsencrypt directory needs to contain both cert.pem
			and priv-fullchain-bundle.pem files.

			The keystore file will be written to the current working
			directory if 'outdir' is not specified.

			An existing keystore file will be moved to keystore.bck\n"
} 

if [[ -n "$1" ]]; then letsencrypt_cert_dir="$1"; else usage; exit 0; fi
if [[ -n "$2" ]]; then unifi_keystore_dir="$2"; else unifi_keystore_dir="$PWD"; fi

else

#-----------------------------------------------------------------------------------#
#					CRON					    #
#-----------------------------------------------------------------------------------#

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

#-----------------------------------------------------------------------------------#
#					CRON					    #
#-----------------------------------------------------------------------------------#

# Output messages to system log if run from cron.
exec 1> >(logger -s -t $(basename $0)) 2>&1

fi

# The default UniFi Controller keystore password.
keystore_pass=aircontrolenterprise

# Check requirements.
command -v keytool >/dev/null 2>&1 || { printf >&2 "Error: I require Keytool, but it's not installed.\n"; exit 1; }
command -v openssl >/dev/null 2>&1 || { printf >&2 "Error: I require OpenSSL, but it's not installed.\n"; exit 1; }

get_letsencrypt_cert_print() {
	local retval=$(openssl x509 \
	-in $letsencrypt_cert_dir/cert.pem \
	-noout \
	-sha256 \
	-fingerprint \
	| cut -d"=" -f2)
	echo "$retval"
}

get_keystore_cert_print() {
	local retval=$(keytool \
	-list \
	-keystore $unifi_keystore_dir/keystore \
	-alias unifi \
	-storepass $keystore_pass 2> /dev/null \
	| grep fingerprint | cut -d" " -f4)
	echo "$retval"
}

generate_keystore() {
	tmpfile=$(mktemp -t uc-XXXXXXXXXX) || exit 1 
	openssl pkcs12 \
	-export \
	-out $tmpfile \
	-in $letsencrypt_cert_dir/priv-fullchain-bundle.pem \
	-password pass:$keystore_pass \
	&& \
	chmod 600 $tmpfile \
	&& \
	keytool \
	-importkeystore \
	-srckeystore $tmpfile \
	-srcstoretype pkcs12 \
	-srcalias 1 \
	-srcstorepass $keystore_pass \
	-destkeystore $unifi_keystore_dir/keystore \
	-deststoretype jks \
	-destalias unifi \
	-deststorepass $keystore_pass 2> /dev/null \
	&& \
	rm -f $tmpfile \
	&& \
	printf "Success: Generated new UniFi Controller keystore.\n" 
}

compare_certs() {
	# This compares the certificate's fingerprints to determine if a new keystore
        # needs to be generated.
	if [[ "$(get_letsencrypt_cert_print)" == "$(get_keystore_cert_print)" ]]; then
		# Keystore certificate is current. Nothing to do.
		return 0
	else
		# Keystore certificate is outdated. Update.
		return 1
	fi
}

# It all begins, at the end.
if [[ ! -f $letsencrypt_cert_dir/cert.pem ]] || [[ ! -f $letsencrypt_cert_dir/priv-fullchain-bundle.pem ]]; then
	printf >&2 "Error: '$letsencrypt_cert_dir' doesn't contain cert.pem or priv-fullchain-bundle.pem\n" 
	if [[ -t 1 ]]; then
		usage
	fi
exit 1
fi

# Compare the certificate fingerprints to see if anything needs to happen.
if compare_certs; then
	# UniFi Controller keystore is current.
	if [[ -t 1 ]]; then
		printf "Nothing to do. Keystore contains current certificate.\n" 
	fi
exit 0
fi

# Check the user hasn't given us a bum steer.
if [[ ! -d $unifi_keystore_dir ]]; then 
	printf >&2 "Error: '$unifi_keystore_dir' needs to be a writeable directory.\n" 
	if [[ -t 1 ]]; then
		usage
	fi
exit 1
fi

# Backup any existing keystore file.
if [[ -f $unifi_keystore_dir/keystore ]]; then
	rm $unifi_keystore_dir/keystore.bck 2>/dev/null
	mv $unifi_keystore_dir/keystore $unifi_keystore_dir/keystore.bck
fi

# Generate a new UniFi Controller keystore & restart UC.
if generate_keystore; then
	if [[ -t 1 ]]; then
		exit 0
	else
		# Set permissions.
		chown $USER.$USER $unifi_keystore_dir/keystore
		chmod $MODE $unifi_keystore_dir/keystore
		# Restart UniFi Controller service.
		command $restart_uc >/dev/null 2>&1 && printf "Success: UniFi Controller service restarted.\n" \
		|| { printf >&2 "Error: Could not restart UniFi Controller.\n"; exit 1; }
		exit 0
	fi
fi

# We shouldn't get to here... but we'll handle it if we do.
printf >&2 "Error: Couldn't generate UniFi Controller keystore file.\n"
exit 1
