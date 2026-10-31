#!/bin/bash
# t715-gps on the tablet, as root, with no sky: the switch, the start on demand, the network
# confinement, the stop without a client, the stop after a crash.  Prints no position: it counts
# sentences.  Usage: t715-gps.sh
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
SOCK=/run/t715-gps/nmea.sock
power() { /usr/lib/t715-gps/t715-gps-power status; }
active() { systemctl -q is-active t715-gpsd.service; }
gpsd_pid() { systemctl show -p MainPID --value t715-gpsd.service; }
wait_off() { for _ in $(seq 1 75); do active || return 0; sleep 0.2; done; return 1; }

# Holds the socket for $1 seconds, or until killed, and says how many sentences came.
client() {
    python3 -c '
import socket, sys, time
c = socket.socket(socket.AF_UNIX); c.connect(sys.argv[1]); c.settimeout(1)
end = time.time() + float(sys.argv[2]); n = 0
while time.time() < end:
    try: n += c.recv(4096).count(b"\n")
    except socket.timeout: pass
print("sentences", n)' "$SOCK" "$1"
}

omamobile-gnss off
check "off: no socket" test ! -S "$SOCK"
check "off: receiver stopped" sh -c '! systemctl -q is-active t715-gpsd.service'
omamobile-gnss status --json | grep -q '"location":"off"' && ok "status says off" || no "status says off"

omamobile-gnss on
check "on: socket there" test -S "$SOCK"
check "on: the tree came from SYSTEM" test -x /var/lib/t715-gps/root/system/bin/gpsd
check "on: receiver not running without a client" sh -c '! systemctl -q is-active t715-gpsd.service'

client 12 > /tmp/gps-client.out &
cl=$!
sleep 6
check "client: gpsd started" active
[ "$(power)" = 1 ] && ok "client: power high" || no "client: power high ($(power))"
pid=$(gpsd_pid)
[ "$(stat -c %U /proc/$pid)" = t715-gps ] && ok "gpsd is not root" || no "gpsd is not root ($(stat -c %U /proc/$pid))"
grep -q '^CapEff:\s*0*$' /proc/$pid/status && ok "gpsd has no capability" || no "gpsd has no capability"
[ "$(readlink /proc/$pid/ns/net)" != "$(readlink /proc/1/ns/net)" ] && ok "gpsd is in its own network namespace" || no "gpsd is in its own network namespace"
up=$(nsenter -t "$pid" -n ip -o link | grep -v ': lo: ' | grep -vc 'state DOWN')
[ "$up" = 0 ] && ok "nothing but its own loopback is up there" || no "an interface is up there"
routes=$(nsenter -t "$pid" -n ip route; nsenter -t "$pid" -n ip -6 route | grep -v '^::1 ')
[ -z "$routes" ] && ok "no route there" || no "a route exists there"
for host in 1.1.1.1 8.8.8.8; do
    nsenter -t "$pid" -n python3 -c '
import socket, sys
s = socket.socket(); s.settimeout(3)
try: s.connect((sys.argv[1], 443)); sys.exit("connected")
except OSError as e: sys.exit(0 if e.errno == 101 else "error %s" % e)' "$host" && ok "$host unreachable from there" || no "$host unreachable from there"
done
wait "$cl"
grep -q 'sentences [1-9]' /tmp/gps-client.out && ok "client: $(cat /tmp/gps-client.out)" || no "client: no sentence"
SECONDS=0
wait_off && ok "client gone: gpsd stopped within $((SECONDS + 1)) s" || no "client gone: gpsd stopped"
[ "$(power)" = 0 ] && ok "client gone: power low" || no "client gone: power low"

client 12 > /dev/null &
cl=$!
sleep 6
kill -9 "$(gpsd_pid)"
sleep 3
[ "$(power)" = 0 ] && ok "crash: power low" || no "crash: power low"
wait_off && ok "crash: receiver not left running" || no "crash: receiver not left running"
wait "$cl"

client 8 > /tmp/gps-client.out
grep -q 'sentences [1-9]' /tmp/gps-client.out && ok "starts again after a crash" || no "starts again after a crash"
wait_off

# GeoClue's GeoIP lookup ignores [wifi] enable=false: run with the network up, this is the test.
systemctl restart geoclue
timeout 20 runuser -u alarm -- /usr/lib/geoclue-2.0/demos/where-am-i -t 15 > /tmp/gps-wai.out 2>&1 &
wai=$!
sleep 6
gc=$(systemctl show -p MainPID --value geoclue.service)
[ "$(readlink /proc/$gc/ns/net)" != "$(readlink /proc/1/ns/net)" ] && ok "GeoClue is in its own network namespace" || no "GeoClue is in its own network namespace"
check "GeoClue started the receiver through the socket" active
nsenter -t "$gc" -n python3 -c '
import socket, sys
s = socket.socket(); s.settimeout(3)
try: s.connect(("1.1.1.1", 443)); sys.exit("connected")
except OSError as e: sys.exit(0 if e.errno == 101 else "error %s" % e)' && ok "nothing outside is reachable from GeoClue" || no "nothing outside is reachable from GeoClue"
wait "$wai"
grep -q GeoIP /tmp/gps-wai.out && no "GeoClue gave a GeoIP position" || ok "no GeoIP position"
wait_off

omamobile-gnss off
check "off again: no socket" test ! -S "$SOCK"
[ "$(power)" = 0 ] && ok "off again: power low" || no "off again: power low"
echo "RESULT: $pass ok, $fail failed"
[ "$fail" = 0 ]
