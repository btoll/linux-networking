#!/bin/bash
# shellcheck disable=2174,2181

set -euo pipefail

LANG=C
umask 0022

trap cleanup ERR

cleanup() {
    true
}

ERROR="\e[31m[ERROR]\e[0m"
INFO="\e[34m[INFO]\e[0m"

if [ $EUID -ne 0 ]
then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

if ! command -v ipvsadm > /dev/null
then
    printf "%b \`ipvsadm\` not found within PATH.\n" "$ERROR"
    exit 1
fi

SCRIPTNAME=$(basename "$0")

usage() {
    printf "Usage: %s OPTIONS

Options:
--name       The service name.
--ip         The service IP address.
--port       The service port.
--protocol   The service protocol [tcp|udp] (defaults to tcp).
--help, -h   Help.\n" "$SCRIPTNAME"
    exit "$1"
}

PROTOCOL=tcp

while [ "$#" -gt 0 ]
do
    OPT="$1"
    case $OPT in
        --name) shift; NAME=$1 ;;
        --ip) shift; IP=$1 ;;
        --port) shift; PORT=$1 ;;
        --protocol) shift; PROTOCOL=$1 ;;
        -h|--help) usage 0 ;;
        *) printf "Unknown flag %s\n" "$OPT"; usage 1 ;;
    esac
    shift
done

if [ -z "$NAME" ]
then
    printf "%b Service name is required.\n" "$ERROR"
    usage 1
fi

if [ -z "$IP" ]
then
    printf "%b Service IP address is required.\n" "$ERROR"
    usage 1
fi

if [ -z "$PORT" ]
then
    printf "%b Service port is required.\n" "$ERROR"
    usage 1
fi

if [ ! -f "/etc/dnsmasq.d/$NAME.host" ]
then
    printf "%s    %s.service.local\n" "$IP" "$NAME" > "/etc/dnsmasq.d/$NAME.host"
    printf "%b Host file \`%s.host\` written to /etc/dnsmasq.d.\n" "$INFO" "$NAME"
fi

SERVICES_DIR=/run/cluster/services.d
mkdir --mode 0755 --parents "$SERVICES_DIR"

if [ -f "$SERVICES_DIR/$NAME.json" ]
then
    printf "%b The service file %s already exists.\n" "$ERROR" "$SERVICES_DIR/$NAME.json"
    exit 1
fi

printf '{
    "name": "%s",
    "ip": "%s",
    "port": %s,
    "protocol": "%s",
    "scheduler": "rr",
    "servers": []
}
' "$NAME" "$IP" "$PORT" "$PROTOCOL" > "$SERVICES_DIR/$NAME.json"
printf "%b Service file \`%s.json\` written to %s.\n" "$INFO" "$NAME" "$SERVICES_DIR"

if ! ipvsadm --add-service "--${PROTOCOL}-service" "$IP:$PORT" --scheduler rr 2> /dev/null
then
    printf "%b \`%s\` service already exists.\n" "$INFO" "$NAME"
else
    printf "%b\n" "$INFO"
    printf "%b \`%s\` service added to \`ipvs\` in host.\n" "$INFO" "$NAME"
fi

# What is that `awk` command doing?
#   $ ip netns list | awk '$0 !~ /-/'
#   node1 (id: 1)
#   node0 (id: 0)
#   $ ip netns list | awk '$0 !~ /-/ {print $1}'
#   node1
#   node0
for ns in $(ip netns list | awk '$0 !~ /-/ {print $1}')
do
    printf "%b\n" "$INFO"

    if ! ip netns exec "$ns" ipvsadm --add-service "--${PROTOCOL}-service" "$IP:$PORT" --scheduler rr 2> /dev/null
    then
        printf "%b \`%s\` service not added to \`ipvs\` in \`%s\` namespace.\n" "$ERROR" "$NAME" "$ns"
    else
        printf "%b \`%s\` service added to \`ipvs\` in \`%s\` namespace.\n" "$INFO" "$NAME" "$ns"
    fi

    if ! ip netns exec "$ns" ip link show dummy0 &> /dev/null
    then
        ip netns exec "$ns" ip link add dummy0 type dummy
        ip netns exec "$ns" ip link set up dummy0
    fi

    if ip netns exec "$ns" ip address add "$IP"/32 dev dummy0
    then
        printf "%b Added VIP \`%s\` to \`dummy0\` in \`%s\` namespace.\n" "$INFO" "$IP" "$ns"
    fi
done

