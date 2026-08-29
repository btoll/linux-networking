#!/bin/bash

set -euo pipefail

LANG=C
umask 0022

ERROR="\e[31m[ERROR]\e[0m"
INFO="\e[34m[INFO]\e[0m"
SUCCESS="\e[32m[SUCCESS]\e[0m"

if [ $EUID -ne 0 ]
then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

BINS=(
    ipvsadm
    jq
)

for bin in "${BINS[@]}"
do
    if ! command -v "$bin" > /dev/null
    then
        printf "[ERROR] \`%s\` not found within PATH.\n" "$bin"
        exit 1
    fi
done

SCRIPTNAME=$(basename "$0")

usage() {
    printf "Usage: %s OPTIONS

Options:
--ns             The name of the pod net namespace in which to run the container.
--process        The full executable string.
--service-name   If fronted by a service, give the name so the IP:PORT will be added to it.
--help, -h       Help.\n" "$SCRIPTNAME"
    exit "$1"
}

CONTAINER_ANCHOR=
NAMESPACE=
PROCESS=
SERVICE_NAME=

while [ "$#" -gt 0 ]
do
    OPT="$1"
    case $OPT in
        --ns) shift; NAMESPACE=$1 ;;
        --process) shift; PROCESS=$1 ;;
        --service-name) shift; SERVICE_NAME=$1 ;;
        -h|--help) usage 0 ;;
        *) printf "Unknown flag %s\n" "$OPT"; usage 1 ;;
    esac
    shift
done

if [ -z "$NAMESPACE" ]
then
    printf "%b Namespace is required.\n" "$ERROR"
    usage 1
fi

if [ -z "$PROCESS" ]
then
    printf "%b Process is required.\n" "$ERROR"
    usage 1
fi

# Given the net namesspace name, we now need to find the pause anchor container
# that the new process should be re-parented to.
for pid in /proc/[0-9]*
do
    [[ $(readlink "$pid/exe" 2>/dev/null) = */pause ]] || continue
    p="${pid##*/}"
    if [[ $(ip netns identify "$p") = "$NAMESPACE" ]]
    then
        CONTAINER_ANCHOR="$p"
    fi
done

if [ -z "$CONTAINER_ANCHOR" ]
then
    printf "%b Namespace \`%s\` could not be found.\n" "$ERROR" "$CONTAINER_ANCHOR"
    usage 1
fi

if ! nsenter --target "$CONTAINER_ANCHOR" --net --pid --mount --uts -- sh -c "$PROCESS &"
then
    printf "%b Program could not be re-parented to %s.\n" "$ERROR" "$CONTAINER_ANCHOR"
fi

printf "%b Program was re-parented to %s in container \`%s\`.\n" "$SUCCESS" "$CONTAINER_ANCHOR" "$NAMESPACE"

SERVICES_DIR=/run/cluster/services.d
if [ -n "$SERVICE_NAME" ] && [ -f "$SERVICES_DIR/$SERVICE_NAME.json" ]
then

    #container_ip=$(ip -n "$NAMESPACE" addr show "ceth$INDEX" | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+')
    # /ceth/: Only look at lines containing the text "ceth".
    # split($3, a, "/"): Take the 3rd column ($3), split it into an array named a using the / character as the divider.
    # print a[1]: Print the first part of that array (the IP).
    container_ip=$(ip -n node0-pod1 -br a | awk '/ceth/ {split($3, a, "/"); print a[1]}')
    # `@tsv` ensures that values containing spaces don't break the `read` command.
    read -r ip port protocol < <(jq -r '[.ip, .port, .protocol] | @tsv' /run/cluster/services.d/dnsmasq.json)

    # Add the server to `ipvs` for each node net namespace.
    for ns in $(ip netns list | awk '$0 !~ /-/ {print $1}')
    do
        # Note that `masquerading` is crucial here and cannot be ommitted.
        ip netns exec "$ns" ipvsadm --add-server "--${protocol}-service" "$ip:$port" --real-server "$container_ip:$port" --masquerading
        printf "%b Added server to service \`%s\` reachable at \`%s:%s\` in node net namespace \`%s\`.\n" "$INFO" "$SERVICE_NAME" "$ip" "$port" "$ns"
    done
fi

