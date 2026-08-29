#!/bin/bash

# Everything created in this script is not accessible from the host namespace.
# The virtual bridge is created in the net namespace passed in as --ns,
# so to see that and the other net namespaces that are "plugged" into it
# one must `ip netns exec foo bash`.

# pod namespaces                       pod namespaces
# 10.0.0.10, 10.0.0.11                 10.0.0.12, 10.0.0.13
#        |                                      |
#      veth                                  veth
#        |                                      |
#    node0/br0                           node1/br0
#        |                                      |
#    vxlan100  =======================  vxlan100
#        |          UDP/4789                 |
#  node0 underlay                       node1 underlay
#  172.16.0.1                           172.16.0.2
#        \                                      /
#         \                                    /
#               host namespace bridge

# host ns
# - host-br0 bridge virtual interface (no IP)
# - host-veth0 plugged into host-br0 (no IP)
# - host-veth1 plugged into host-br0 (no IP)
#
# node0 ns
# - host-ceth0 connected to host-veth0 in host ns (underlay IP 172.16.0.1/16)
# - br0 virtual bridge interface (no IP)
# - veth0 plugged into br0 (no IP)
# - vxlan100 tunneled to vxlan100 in node1 ns (no IP)
#
# node1 ns
# - host-ceth1 connected to host-veth1 in host ns (underlay IP 172.16.0.2/16)
# - br0 virtual bridge interface (no IP)
# - veth1 plugged into br0 (no IP)
# - vxlan100 tunneled to vxlan100 in node0 ns (no IP)

set -eo pipefail

LANG=C
umask 0022

ERROR="\e[31m[ERROR]\e[0m"
INFO="\e[34m[INFO]\e[0m"
SUCCESS="\e[32m[SUCCESS]\e[0m"
#YELLOW="\e[43m[INFO]\e[0m"

if [ $EUID -ne 0 ]
then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

trap cleanup ERR

cleanup() {
    local ns
    for ns in $(ip netns list | awk '/node[0-9]+(-pod[0-9]+)?/ {print $1}')
    do
        ip netns delete "$ns"
    done
    ip link delete "host-$BRIDGE" type bridge
    # The pause container anchors will be re-parented to PID 1 in the host net ns.
    for pid in $(pidof pause)
    do
        kill -SIGKILL "$pid"
    done
    iptables -t nat -D POSTROUTING -o enp2s0 -j MASQUERADE
}

create_node() {
    local index="$1"
    local nodens="node$index"
    local podns

    local first_three_octets="${NODE_BRIDGE_IP%.*}"
    local last_octet="${NODE_BRIDGE_IP##*.}"
    local pod_netmask="${POD_NETWORK#*/}"

    # Create the node (i.e., the new net namespace which will include
    # the bridge and the veth pair.
    ip netns add "$nodens"

    # Each node gets its own bridge.
    ip -netns "$nodens" link add name "$BRIDGE" type bridge
    ip -netns "$nodens" link set "$BRIDGE" up

    # Yes, we're going to reuse these local vars.
    first_three_octets="${POD_NETWORK%.*}"
    last_octet="${POD_NETWORK##*.}"

    # Bring up loopback (optional).
    ip -netns "$nodens" link set lo up

    # These commands allow the containers to access the Internet.
    # Maybe put behind a CLI flag.
    ip -netns "$nodens" address add 172.16.0.$((index + 1))/16 dev br0
    ip netns exec "$nodens" sysctl net.ipv4.ip_forward=1 > /dev/null
    ip netns exec "$nodens" iptables -t nat -A POSTROUTING -o "host-ceth$index" -j MASQUERADE

    for ((n=0; n < PODS; n++))
    do

        # Create the veth pair.
        ip -netns "$nodens" link add "veth$n" type veth peer name "ceth$n"
        ip -netns "$nodens" link set "veth$n" up

        # Create new "pod" net namespace and move one end of the veth pair into it.
        podns="${nodens}-pod$n"
        ip netns add "$podns"
        ip -netns "$nodens" link set "ceth$n" netns "$podns"

        # Attach the other end to the bridge device.
        ip -netns "$nodens" link set dev "veth$n" master "$BRIDGE"

        # Add IP address to endpoint that was moved into its own net namespace
        # (the "cable" plugged into the bridge does NOT get an IP address).
        ip -netns "$podns" address add "$first_three_octets.$((last_octet + POD_COUNTER))/$pod_netmask" dev "ceth$n"
        ip -netns "$podns" link set "ceth$n" up
        # Bring up loopback (optional).
        ip -netns "$podns" link set lo up

        # These command allows the containers to access the Internet.
        # Maybe put behind a CLI flag.
        ip -netns "$podns" route add default via 172.16.0.$((index + 1)) dev "ceth$n"

        # Add the container anchor.  This is the supervisor that will reap all re-parented children and trap signals.
        # Maybe put behind a CLI flag.
        if [ -f pause ] && [ -x pause ]
        then
            ip netns exec "$podns" unshare --fork --pid --mount-proc --uts -- ./pause &
        fi

        POD_COUNTER=$((POD_COUNTER + 1))
    done
}

create_host_bridge() {
    local first_three_octets="${NODE_BRIDGE_IP%.*}"
    local last_octet="${NODE_BRIDGE_IP##*.}"
    local node_netmask="${NODE_NETWORK#*/}"
    local i

    ip link add name "host-$BRIDGE" type bridge
#    ip address add "$NODE_BRIDGE_IP/$NODE_NETMASK" dev "node$BRIDGE"

    for ((i=0; i < NODES; i++))
    do
        # Create veth pair.
        ip link add "host-veth$i" type veth peer name "host-ceth$i"
        # Move one end into node ns, add IP address and bring it up.
        ip link set "host-ceth$i" netns "node$i"
        ip -n "node$i" address add "$first_three_octets.$((last_octet + i))/$node_netmask" dev "host-ceth$i"
        ip -n "node$i" link set "host-ceth$i" up
        # Add other end to node bridge and bring it up.
        ip link set dev "host-veth$i" master "host-$BRIDGE"
        ip link set "host-veth$i" up
    done

    ip link set "host-$BRIDGE" up
}

enable_node_internet_connectivity() {
    ip address add 10.0.0.254/16 dev host-br0

    # Get only node net namespaces, i.e., node0, node1, etc.
    # What is that `awk` command doing?
    #   $ ip netns list | awk '$0 !~ /-/
    #   node1 (id: 1)
    #   node0 (id: 0)
    #   $ ip netns list | awk '$0 !~ /-/ {print $1}'
    #   node1
    #   node0
    for ns in $(ip netns list | awk '$0 !~ /-/ {print $1}')
    do
        # Chop off the last char to get the number to match the veth device
        # (fails if > 9).
        ip -netns "$ns" route add default via 10.0.0.254 dev host-ceth"${ns: -1}"
    done

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    iptables -t nat -A POSTROUTING -o enp2s0 -j MASQUERADE

}

parse_cidr() {
    local cidr="$1"
    local network
    local bridge_ip

    while IFS= read -r line
    do
        case "$line" in
            Network:*) network=$(printf "%s" "$line" | awk '{print $2}') ;;
            HostMin:*) bridge_ip=$(printf "%s" "$line" | awk '{print $2}') ;;
        esac
    done <<< "$(ipcalc "$cidr")" # We'll know if the CIDR address is invalid if the vars are empty.

    if [ -z "$network" ]
    then
        printf "%b \`%s\` is an invalid CIDR address.\n" "$ERROR" "$cidr"
        usage 1
    fi

    echo "$network $bridge_ip"
}

setup_vxlan_vteps() {
    local vni=100
    local vtep="vxlan$vni"
    local index
    local local_ip
    local peer_index
    local peer_ip

    for ((index = 0; index < NODES; index++)); do
        local_ip="${NODE_BRIDGE_IP%.*}.$(( ${NODE_BRIDGE_IP##*.} + index ))"

        ip -netns "node$index" link add "$vtep" type vxlan \
            id "$vni" \
            local "$local_ip" \
            dev "host-ceth$index" \
            dstport 4789

        ip -netns "node$index" link set dev "$vtep" master "$BRIDGE"
        ip -netns "node$index" link set "$vtep" mtu 1450
        ip -netns "node$index" link set "$vtep" up

        for ((peer_index = 0; peer_index < NODES; peer_index++)); do
            [ "$peer_index" -eq "$index" ] && continue

            peer_ip="${NODE_BRIDGE_IP%.*}.$(( ${NODE_BRIDGE_IP##*.} + peer_index ))"

            ip netns exec "node$index" bridge fdb append \
                00:00:00:00:00:00 \
                dev "$vtep" \
                dst "$peer_ip" \
                self permanent
        done
    done
}

status() {
    local n=()
    local p=()
    local a
    local ns
    local v
    local line

    printf "%b net namespaces\n" "$INFO"
    # Remove the network namespace IDS, i.e., `node0 (id: 0)`.
    # This is safe b/c there cannot be a space in a network name.
    for ns in $(ip netns list | awk '{print $1}')
    do
        printf "%b \t\t%s\n" "$INFO" "$ns"
        if [[ "$ns" =~ - ]]
        then
            p+=("$ns")
        else
            n+=("$ns")
        fi
    done

    printf "%b \n" "$INFO"

    printf "%b host\n" "$INFO"
    while read -r line
    do
        printf "%b \t\t%s\n" "$INFO" "$line"
    done < <(ip -br a)

    printf "%b \n" "$INFO"

    for a in n p
    do
        # Create a nameref (`current_array`) that points to the array name stored in `a`.
        declare -n current_array="$a"
        for v in "${current_array[@]}"
        do
            if [ "$VERBOSE" = 1 ]
            then
                if [[ ! ( "$v" =~ - ) ]]
                then
                    printf "%b %s - bridge fdb\n" "$INFO" "$v"
                    while read -r line
                    do
                        printf "%b \t\t%s\n" "$INFO" "$line"
                    done < <(ip netns exec "$v" bridge fdb show br "$BRIDGE")

                    printf "%b \n" "$INFO"

                    printf "%b %s - vxlan fdb\n" "$INFO" "$v"
                    while read -r line
                    do
                        printf "%b \t\t%s\n" "$INFO" "$line"
                    done < <(ip netns exec "$v" bridge fdb show dev vxlan100)

                    printf "%b \n" "$INFO"
                fi
            fi

            printf "%b %s\n" "$INFO" "$v"
            while read -r line
            do
                printf "%b \t\t%s\n" "$INFO" "$line"
            done < <(ip -n "$v" -br a)
            printf "%b \n" "$INFO"
        done
    done
}

if ! command -v ipcalc > /dev/null
then
    printf "%b \`ipcalc\` not found within PATH.\n" "$ERROR"
    exit 1
fi

usage() {
    printf "Usage: %s OPTIONS

Options:
--pod-cidr      The CIDR address for the pods (defaults to 10.0.0.0/16).
--pods          The pods within each node (defaults to 2).
                Each pod gets its own isolated net namespace.
--destroy       Teardown.
--node-cidr     The CIDR address for the nodes (defaults to 172.16.0.0/16).
--nodes         Number of nodes in the cluster (defaults to 2).
                Each node gets its own isolated net namespace.
--service-cidr  The CIDR address for the nodes (defaults to 10.96.64.0/18).
--status        Prints the network topology.
-v, --verbose   If set, prints bridge and VXLAN fdb entries when --status is set.
-h, --help      Show usage.\n" "$SCRIPTNAME"
    exit "$1"
}

BRIDGE=br0
DESTROY=
NODES=2
NODE_CIDR=10.0.0.0/16
NODE_NETWORK=
NODE_BRIDGE_IP=
PODS=2
POD_CIDR=172.16.0.0/16
POD_COUNTER=10
POD_NETWORK=
SCRIPTNAME=$(basename "$0")
#SERVICE_CIDR=10.96.64.0/18
STATUS=
VERBOSE=

while [ "$#" -gt 0 ]
do
    OPT="$1"
    case $OPT in
        --pod-cidr) shift; POD_CIDR=$1 ;;
        --pods) shift; PODS=$1 ;;
        --destroy) DESTROY=1 ;;
        --node-cidr) shift; NODE_CIDR=$1 ;;
        --nodes) shift; NODES=$1 ;;
        -h|--help) usage 0 ;;
#        --service-cidr) shift; SERVICE_CIDR=$1 ;;
        --status) STATUS=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        *) printf "Unknown flag %s\n" "$OPT"; usage 1 ;;
    esac
    shift
done

if [ -n "$DESTROY" ]
then
    cleanup
    printf "%b Network topology destroyed.\n" "$SUCCESS"
elif [ -n "$STATUS" ]
then
    status
else
    # 172.18.0.0/20 - 4096 addresses
    # 172.18.0.0/21 - 2048 addresses
    # 172.18.8.0/21 - 2048 addresses

    read -r NODE_NETWORK NODE_BRIDGE_IP < <(parse_cidr "$NODE_CIDR")
    read -r POD_NETWORK _ < <(parse_cidr "$POD_CIDR")

    for ((i=0; i < NODES; i++))
    do
        create_node "$i"
    done

    create_host_bridge
    setup_vxlan_vteps
    enable_node_internet_connectivity

    modprobe br_netfilter

    printf "%b Cluster and network topology created.\n" "$SUCCESS"
    printf "%b Run \`$SCRIPTNAME --status [--verbose]\` for details.\n" "$INFO"
fi

