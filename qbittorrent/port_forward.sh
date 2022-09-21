#!/bin/bash 
#export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/root/bin
# Source our persisted env variables from container startup
## this is an amalgamation of two scripts to keep my PIA working, credit to the main authors, the original scripts linked in the READ.ME
#v0.2

# Settings

sleep 5

###### PIA Variables ######
WEBUI_PORT=8080
curl_max_time=15
curl_retry=5
curl_retry_delay=15
user=${VPN_USERNAME}
pass=${VPN_PASSWORD}
pf_host=$(ip route | grep tun | grep -v src | head -1 | awk '{ print $3 }')

###### Nextgen PIA port forwarding      ##################

get_auth_token () {
            tok=$(curl --insecure --silent --show-error --request POST --max-time $curl_max_time \
                 --header "Content-Type: application/json" \
                 --data "{\"username\":\"$user\",\"password\":\"$pass\"}" \
                "https://www.privateinternetaccess.com/api/client/v2/token" | jq -r '.token')
            [ $? -ne 0 ] && echo "Failed to acquire new auth token" && exit 1
            #echo "$tok"
    }


get_sig () {
  pf_getsig=$(curl --insecure --get --silent --show-error \
    --retry $curl_retry --retry-delay $curl_retry_delay --max-time $curl_max_time \
    --data-urlencode "token=$tok" \
    $verify \
    "https://$pf_host:19999/getSignature")
  if [ "$(echo $pf_getsig | jq -r .status)" != "OK" ]; then
    echo "$(date): getSignature error"
    echo $pf_getsig
    echo "the has been a fatal_error"
  fi
  pf_payload=$(echo $pf_getsig | jq -r .payload)
  pf_getsignature=$(echo $pf_getsig | jq -r .signature)
  pf_port=$(echo $pf_payload | base64 -d | jq -r .port)
  pf_token_expiry_raw=$(echo $pf_payload | base64 -d | jq -r .expires_at)
  if date --help 2>&1 /dev/null | grep -i 'busybox' > /dev/null; then
    pf_token_expiry=$(date -D %Y-%m-%dT%H:%M:%S --date="$pf_token_expiry_raw" +%s)
  else
    pf_token_expiry=$(date --date="$pf_token_expiry_raw" +%s)
  fi
}

bind_port () {
  pf_bind=$(curl --insecure --get --silent --show-error \
      --retry $curl_retry --retry-delay $curl_retry_delay --max-time $curl_max_time \
      --data-urlencode "payload=$pf_payload" \
      --data-urlencode "signature=$pf_getsignature" \
      $verify \
      "https://$pf_host:19999/bindPort")
  if [ "$(echo $pf_bind | jq -r .status)" = "OK" ]; then
    echo "Reserved Port: $pf_port  $(date)"		
  else  
    echo "$(date): bindPort error"
    echo $pf_bind
    echo "the has been a fatal_error"
  fi
}
bind_qbittorrent() {
# identify protocol, used by curl to connect to api
	if grep -q 'WebUI\\HTTPS\\Enabled=true' '/config/qBittorrent/config/qBittorrent.conf'; then
		web_protocol="https"
	else
		web_protocol="http"
	fi

	# note -k flag required to support insecure connection (self signed certs) when https used
	curl -k -i -X POST -d "json={\"random_port\": false}" "${web_protocol}://localhost:${WEBUI_PORT}/api/v2/app/setPreferences" &> /dev/null
	curl -k -i -X POST -d "json={\"listen_port\": ${pf_port}}" "${web_protocol}://localhost:${WEBUI_PORT}/api/v2/app/setPreferences" &> /dev/null

}

echo "Running functions for token based port fowarding"
get_auth_token
get_sig
bind_port
bind_qbittorrent
echo $pf_port
format_expiry=$(date -d @$pf_token_expiry)
pf_minreuse=$(( 60 * 60 * 24 * 7 ))
pf_remaining=$((  $pf_token_expiry - $(date +%s) ))

while true; do
	echo "#######################"
	echo "        SUCCESS        "
	echo "#######################"
	echo "Port: $pf_port"
	echo "Expiration $format_expiry"
	echo "#######################"
	echo "Entering infinite while loop"
	echo "Every 15 minutes, check port status"
	pf_remaining=$((  $pf_token_expiry - $(date +%s) ))
	if [ $pf_remaining -lt $pf_minreuse ]; then
		echo "60 day port reservation reached"
		echo "Getting a new one"
		get_auth_token
		get_sig
		bind_port
		bind_qbittorrent
	fi
	sleep 900 &
	wait $!
	bind_port
	bind_qbittorrent
done
