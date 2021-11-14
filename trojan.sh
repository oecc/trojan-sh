#!/bin/bash

# vultr: api_key, ssh_key, region, plan, os, label
API_KEY="your_vultr_api_key"    # vultr api key
SSH_KEY_ID="your_ssh_key_id"    # curl -X GET 'https://api.vultr.com/v2/ssh-keys' -H 'Authorization: Bearer ${API_KEY}'
REGION="nrt"            # sgp:Singapore nrt:Tokyo dfw:Dallas, curl -X GET 'https://api.vultr.com/v2/regions'
VPS_PLAN="vc2-1c-1gb"   # vc2-1c-1gb:$5/month, curl -X GET 'https://api.vultr.com/v2/plans'
OS_ID="452"             # 452:AlmaLinux x64, curl -X GET 'https://api.vultr.com/v2/os'
LABEL="trojan-auto"     # vps instance lable, create/deploy/stop find vps through it

BASE_URL="https://api.vultr.com/v2" # vultr api base url
INSTANCES_URL="$BASE_URL/instances" # vultr create/list/remove instance url

# trojan: domain, site, cert, password
DOMAIN_NAME="www.your_domain.com"   # freenom registered domain
SITE_PATH="./www.tar.gz"            # site file and cert package
TROJAN_PWD='your_trojan_password'   # trojan password
CLIENT_IP="192.168.1.4"             # raspbreey pi4, docker running on it
DOWNLOAD_URL="https://github.com/p4gefau1t/trojan-go/releases/download/v0.10.6/trojan-go-linux-amd64.zip"

# ip temp, is not change
VPS_IP="0.0.0.0"                    # save vps ip temp value
VPS_ID="9a9b9c9d-4444-ffff-eeee"    # save vps id temp value, curl -X GET 'https://api.vultr.com/v2/instances' -H 'Authorization: Bearer ${API_KEY}'

# script help
function usage() {
    echo "usage: ./trojsn.sh [OPTION]"
    echo ""
    echo "options:"
    echo "  start   Create VPS instance and start Trojan server"
    echo "  stop    Stop Trojan server and destory VPS instance"
    echo "  help    Show this message."
}

# nginx config template, output to nginx.conf
NGINX_TEMPLATE="user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;
events {
    worker_connections 1024;
}
http {
    log_format  main  '\\\$remote_addr - \\\$remote_user [\\\$time_local] \"\\\$request\" '
                        '\\\$status \\\$body_bytes_sent \"\\\$http_referer\" '
                        '\"\\\$http_user_agent\" \"\\\$http_x_forwarded_for\"';
    access_log  /var/log/nginx/access.log  main;
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
    server {
        listen       80 default_server;
        listen       [::]:80 default_server;
        server_name  %s;
        root         /usr/share/nginx/html;
        include /etc/nginx/default.d/*.conf;
        location / {
        }
        error_page 404 500 502 503 504 /404.html;
        location = /40x.html {
        }
    }
}"

# trojan config template, output to server.ymal
TROJAN_TEMPLATE="run-type: server
local-addr: 0.0.0.0
local-port: 443
remote-addr: 127.0.0.1
remote-port: 80
password:
  - %s
ssl:
  cert: /mnt/cert/fullchain.pem
  key: /mnt/cert/privkey.pem
  sni: %s
  fallback-port: 80
router:
  enabled: true
  block:
    - 'geoip:private'
  geoip: ./geoip.dat
  geosite: ./geosite.dat"

# find vps lable is ${LABEL}
function findVps() {
    local result=$(curl -s -X GET "${INSTANCES_URL}" -H "Content-Type: application/json" -H "Authorization: Bearer ${API_KEY}")
    local label='"label":"'${LABEL}'"'
    if ! ([[ "$result" =~ "$label" ]] && [[ "$result" =~ '"main_ip":"' ]] && [[ "$result" =~ '"id":"' ]] && [[ "$result" =~ '"power_status":"' ]])
    then
        echo "[-] Not find vps."
        return 1
    fi
    local trojan_json=$(echo ${result} | sed -nr -e 's/^.*({.*'"${label}"')/\1/g' -e 's/}.*$//gp')
    local vps_ip=$(echo ${result} | sed -n -e 's/^.*"main_ip":"//g' -e 's/".*$//gp')
    local vps_id=$(echo ${result} | sed -n -e 's/^.*"id":"//g' -e 's/".*$//gp')
    local vps_status=$(echo ${result} | sed -n -e 's/^.*"power_status":"//g' -e 's/".*$//gp')
    
    if [ "$vps_status" != "running" ]
    then
        echo "[-] Find vps, ip: ${vps_ip}, but not running."
        return 1
    fi

    if [ -n "$vps_ip" ] && [ -n "$vps_id" ]
    then
        echo "[+] Find vps, ip: ${vps_ip}, id: ${vps_id}"
        VPS_IP=$vps_ip
        VPS_ID=$vps_id
        return 0
    else
        echo "[-] Find vps fail, ip not match."
        return 1
    fi
}

# create vps instance, and wait it running
function createVps() {
    local param='{"region" : "'${REGION}'","plan" : "'${VPS_PLAN}'","label" : "'${LABEL}'","os_id" : '${OS_ID}',"sshkey_id" : ["'${SSH_KEY_ID}'"]}'
    local result=$(curl -s -X POST "${INSTANCES_URL}" -H "Content-Type: application/json" -H "Authorization: Bearer ${API_KEY}" -d "$param")
    if ! ([[ "$result" =~ '"default_password":"' ]])
    then
        echo "[-] Create vps fail, result: ${result}"
        exit 1
    fi
    local password=$(echo ${result} | sed -n -e 's/^.*"default_password":"//g' -e 's/".*$//gp')
    echo "[+] Create vps sucess, password: ${password}"
    # wait runing
    for i in {1..20}
    do
        findVps
        if [ $? == 0 ]
        then
            break
        fi
    done
    echo "[-] Vps status is not running."
    exit 1
}

# delete vps instance
function deleteVps() {
    local result=$(curl -s -X DELETE "${INSTANCES_URL}/${VPS_ID}" -H "Authorization: Bearer ${API_KEY}" -w %{http_code})
    if [ "$result" != '204' ]
    then
        echo "[-] Delete vps fail, result: ${result}"
    else
        echo "[+] Delete vps success, id: ${VPS_ID}"
    fi
}

# upload file to remote, target ip is $1, local path is $2, remote path is $3
function uploadFile() {
    scp -qC -o StrictHostKeyChecking=no "$2" "root@$1:$3"
    if [ $? != 0 ]
    then
        echo "[-] Upload site and cert fail."
    else
        echo "[+] Upload site and cert success."
    fi
}

# run script, user is $1, target ip is $2, script is $3
function runScript() {
    local date_now=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\n${date_now} $1@$2 >> $3" >> script.log
    ssh -o StrictHostKeyChecking=no "$1@$2" "$3" >> script.log
    if [ $? != 0 ]
    then
        echo "[-] Excute script fail."
    else
        echo "[+] Excute script success, ip: $2"
    fi
}

# start trojan
function start() {
    # 0.find vps
    findVps
    # 1.create vps
    if [ $? != 0 ]; then createVps; fi
    # 2.upload site and cert
    uploadFile "${VPS_IP}" "${SITE_PATH}" "/mnt"
    # 3.script: nginx, trojan, selinux, firewall
    local script='cd /mnt;yum install nginx;wget -O trojan-go-linux-amd64.zip '${DOWNLOAD_URL}';setenforce Permissive;firewall-cmd --add-port=443/tcp;'
    # 4.script: move, nginx, trojan
    local site_file=$(echo "${SITE_PATH}" | sed -n 's/^.*\///gp')
    script=${script}'mv /usr/share/nginx/html/ /usr/share/nginx/html1;tar -xf '${site_file}';mv www /usr/share/nginx/html;chown -R nginx:users /usr/share/nginx/html;'
    local nginx_conf=$(printf "${NGINX_TEMPLATE}" "${DOMAIN_NAME}")
    script=${script}'cp /etc/nginx/nginx.conf /etc/nginx/nginx_bak.conf;echo "'${nginx_conf}'" > /etc/nginx/nginx.conf;systemctl start nginx;systemctl enable nginx;'
    script=${script}'unzip trojan-go-linux-amd64.zip -d trojan;'
    local trojan_conf=$(printf "${TROJAN_TEMPLATE}" "${TROJAN_PWD}" "${DOMAIN_NAME}")
    script=${script}'echo "'${trojan_conf}'" > /mnt/trojan/server.yaml;cd /mnt/trojan;nohup /mnt/trojan/trojan-go -config /mnt/trojan/server.yaml >/dev/null 2>&1 &'
    # 5.execute script
    runScript "root" "${VPS_IP}" "$script"
    # 6.change dns
    # TODO freenom
    # 7.start client container
    echo "[+] Trojan server is running."
}

# stop trojan
function stop() {
    # 0.find vps
    findVps
    if [ $? != 0 ]; then exit 1; fi
    # 1.stop client container
    local script='container_id=$(docker ps -a | grep trojan-go | awk "{print \$1}");if [ -n "$container_id" ]; then docker stop "$container_id";docker rm "$container_id"; fi;unset -v container_id;'
    runScript "pi" "${CLIENT_IP}" "$script"
    # 2.destroy vps
    deleteVps
}

# parse args
function parse() {
    if [ "$#" != 1 ]; then usage; exit 1; fi
    if [ "$1" == "start" ]; then start; exit 0; fi
    if [ "$1" == "stop" ]; then stop; exit 0; fi
    usage
}

parse $*