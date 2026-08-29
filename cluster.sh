#!/bin/bash

set -eo pipefail

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

trap cleanup ERR

cleanup() {
    local ns
    for ns in $(ip netns list | awk '/node[0-9]+(-pod[0-9]+)?/ {print $1}')
    do
        ip netns delete "$ns"
    done
    ip link delete "host-$BRIDGE" type bridge
    # The sandbox-init process anchors will be re-parented to PID 1 in the host network namespace.
    for pid in $(pidof sandbox-init)
    do
        kill -SIGKILL "$pid"
    done
    iptables -t nat -D POSTROUTING -o enp2s0 -j MASQUERADE 2> /dev/null
}

create_host_bridge() {
    local first_three_octets="${NODE_BRIDGE_IP%.*}"
    local last_octet="${NODE_BRIDGE_IP##*.}"
    local node_netmask="${NODE_NETWORK#*/}"
    local i

    ip link add name "host-$BRIDGE" type bridge
    ip link set "host-$BRIDGE" up

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
}

create_iptables_rules() {
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    iptables -t nat -A POSTROUTING -o enp2s0 -j MASQUERADE

    for nodens in $(ip netns list | awk '$0 !~ /-/ {print $1}')
    do
        # 1. The Forwarding "On" Switch
        # The node must be allowed to move packets between the pod veth and the vxlan/br0 interfaces.
        ip netns exec "$nodens" sysctl -w net.ipv4.ip_forward=1 > /dev/null
        ip netns exec "$nodens" sysctl -w net.ipv4.ip_forward=1 > /dev/null

        # 2. The PREROUTING Chain (The "Load Balancer")
        # Since you no longer have IPVS to intercept the VIP, you must use DNAT.
        # To avoid cluttering your main chain, create a dedicated chain for your services.
        #
        # Create the chain
        ip netns exec "$nodens" iptables -t nat -N KUBE-SERVICES
        # Jump to this chain from PREROUTING
        ip netns exec "$nodens" iptables -t nat -I PREROUTING 1 -j KUBE-SERVICES

        # Add the actual mapping (The "Service" rule)
        # Format: -d <VIP> -p <PROTO> --dport <PORT> -j DNAT --to-destination <POD_IP>:<PORT>
        ip netns exec "$nodens" iptables -t nat -A KUBE-SERVICES -d 10.96.64.10 -p udp --dport 53 -j DNAT --to-destination 172.16.0.10:53

        # (Note: If you have multiple pods for one service, you'd add multiple rules here
        # using the -m statistic --mode random --probability module to load balance.)

        #3. The POSTROUTING Chain (The "Return Path")
        #
        #This is the most common point of failure. When the destination pod replies,
        # the packet must be masqueraded so it returns through the node, not directly to the requester.
        #
        # Masquerade all traffic leaving the node that originated from a pod
        ip netns exec "$nodens" iptables -t nat -A POSTROUTING -s 172.16.0.0/16 -j MASQUERADE

        #4. The FORWARD Chain (The "Permission")
        #
        #Finally, ensure the filter table isn't dropping the packets as they move between interfaces.
        #
        # Allow traffic from pods to services
        ip netns exec "$nodens" iptables -A FORWARD -s 172.16.0.0/16 -d 10.96.0.0/16 -j ACCEPT
        # Allow return traffic from services to pods
        ip netns exec "$nodens" iptables -A FORWARD -s 10.96.0.0/16 -d 172.16.0.0/16 -j ACCEPT
        # Allow pod-to-pod traffic (for the actual delivery)
        ip netns exec "$nodens" iptables -A FORWARD -s 172.16.0.0/16 -d 172.16.0.0/16 -j ACCEPT
    done

    #Summary of the Flow now:
    #
    #    Packet arrives in node0 destined for 10.96.64.10.
    #    PREROUTING →→ KUBE-SERVICES →→ DNAT changes destination to 172.16.0.11.
    #    FORWARD chain checks if 172.16.0.11 is allowed →→ ACCEPT.
    #    Packet is routed to the pod.
    #    Pod replies →→ POSTROUTING →→ MASQUERADE changes source to the node's IP.
    #    Packet returns to original requester.

    # If the source and destination are both the same pod, masquerade the source
    # NOTE: I haven't had luck with this.
    # ip netns exec node0 iptables -t nat -A POSTROUTING -s 172.16.0.11 -d 172.16.0.11 -j MASQUERADE
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

        # Add IP address to the endpoint that was moved into its own net namespace
        # (the "cable" plugged into the bridge does NOT get an IP address).
        ip -netns "$podns" address add "$first_three_octets.$((last_octet + POD_COUNTER))/$pod_netmask" dev "ceth$n"
        ip -netns "$podns" link set "ceth$n" up

        # Bring up loopback (optional).
        ip -netns "$podns" link set lo up

        # Add the container anchor.  This is the supervisor that will reap all re-parented children and trap signals.
        # Maybe put behind a CLI flag.
        if [ -f sandbox-init ] && [ -x sandbox-init ]
        then
            ip netns exec "$podns" unshare --fork --pid --mount-proc --uts -- ./sandbox-init &
        fi

        POD_COUNTER=$((POD_COUNTER + 1))
    done
}

enable_cluster_internet_connectivity() {
    local index

    # Adding an address for the host gateway enables nodes to use it as the next hop
    # for traffic leaving the cluster.
    ip address add 10.0.0.254/16 dev host-br0

    # Get only node net namespaces, i.e., node0, node1, etc.
    # What is that `awk` command doing?
    # It is filtering the node namespaces (pod namespaces include hyphens).
    #   $ ip netns list | awk '$0 !~ /-/
    #   node1 (id: 1)
    #   node0 (id: 0)
    #   $ ip netns list | awk '$0 !~ /-/ {print $1}'
    #   node1
    #   node0
    for nodens in $(ip netns list | awk '$0 !~ /-/ {print $1}')
    do
        # Extract the numeric suffix, i.e., node111 -> 111.
        index="${nodens#node}"
        node_gateway="172.16.0.$((index + 1))"

        # Make each node bridge a layer 3 gateway for its pods.
        ip -netns "$nodens" address add "$node_gateway"/16 dev br0

        # Add a route through the host namespace for Internet-bound traffic.
        # It sets the host namespace as the node's default gateway.
        ip -netns "$nodens" route add default via 10.0.0.254 dev host-ceth"$index"

        for ((n=0; n < PODS; n++))
        do
            ip -netns "$nodens-pod$n" route add default via "$node_gateway" dev "ceth$n"
        done
    done
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
        # vxlan adds a 50-byte header.
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
--internet      Flag to enable the cluster (all nodes and pods) access to the Internet.
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
INTERNET=
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
        --destroy) DESTROY=1 ;;
        --internet) INTERNET=1 ;;
        --node-cidr) shift; NODE_CIDR=$1 ;;
        --nodes) shift; NODES=$1 ;;
        --pod-cidr) shift; POD_CIDR=$1 ;;
        --pods) shift; PODS=$1 ;;
#        --service-cidr) shift; SERVICE_CIDR=$1 ;;
        --status) STATUS=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help) usage 0 ;;
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
    read -r NODE_NETWORK NODE_BRIDGE_IP < <(parse_cidr "$NODE_CIDR")
    read -r POD_NETWORK _ < <(parse_cidr "$POD_CIDR")

    for ((i=0; i < NODES; i++))
    do
        create_node "$i"
    done

    create_host_bridge
    setup_vxlan_vteps

    if [ "$INTERNET" = 1 ]
    then
        # Add the addresses and routes to the virtual devices.
        enable_cluster_internet_connectivity

        # Configure the firewall.
        create_iptables_rules
    fi

    modprobe br_netfilter

    printf "%b Cluster and network topology created.\n" "$SUCCESS"
    printf "%b Run \`$SCRIPTNAME --status [--verbose]\` for details.\n" "$INFO"
fi

