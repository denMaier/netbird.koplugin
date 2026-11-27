#!/bin/sh
# Publish opds.internal as a NetBird FQDN resource, and its address as an IP resource,
# with this peer as their router.
set -eu
S=http://netbird-server
A="Authorization: Bearer $(cat /shared/token)"
J='Content-Type: application/json'
api() { curl -fsS -X POST "$S/api/$1" -H "$A" -H "$J" -d "$2"; }
all=$(curl -fsS "$S/api/groups" -H "$A" | jq -r '.[] | select(.name=="All") | .id')
self=$(curl -fsS "$S/api/peers" -H "$A" | jq -r --arg ip "$(cat /shared/peer.ip)" '.[] | select(.ip==$ip) | .id')
group=$(api groups '{"name":"opds"}' | jq -re .id)
net=$(api networks '{"name":"homelab"}' | jq -re .id)
api "networks/$net/resources" "{\"name\":\"opds\",\"address\":\"opds.internal\",\"enabled\":true,\"groups\":[\"$group\"]}" >/dev/null
api "networks/$net/resources" "{\"name\":\"opds-ip\",\"address\":\"172.30.99.10/32\",\"enabled\":true,\"groups\":[\"$group\"]}" >/dev/null
api "networks/$net/routers" "{\"peer\":\"$self\",\"metric\":9999,\"masquerade\":true,\"enabled\":true}" >/dev/null
api policies "{\"name\":\"opds\",\"enabled\":true,\"rules\":[{\"name\":\"opds\",\"enabled\":true,\"action\":\"accept\",\"bidirectional\":false,\"protocol\":\"all\",\"sources\":[\"$all\"],\"destinations\":[\"$group\"]}]}" >/dev/null
touch /shared/resource.ready
echo "resource published"
