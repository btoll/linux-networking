#!/bin/bash

set -euo pipefail

LANG=C
umask 0022

bash bridge.sh --op add --ns foo --cidr 172.18.0.0/20
bash bridge.sh --op add --ns bar --cidr 172.19.0.0/20

