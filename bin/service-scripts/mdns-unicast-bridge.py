#!/usr/bin/env python3
"""Listen for mDNS queries for our hostname arriving via multicast,
reply via unicast directly to the querier. Works around routers
that do not forward multicast from wired to Wi-Fi.

Auto-detects hostname and IP — deploy to any node without editing."""
import socket, struct, datetime

MDNS_ADDR = "224.0.0.251"
MDNS_PORT = 5353

def get_hostname():
    return socket.gethostname().split(".")[0]

def get_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.168.29.1", 80))
        return s.getsockname()[0]
    finally:
        s.close()

def log(msg):
    print(f"[{datetime.datetime.now()}] {msg}", flush=True)

def parse_name(data, offset):
    labels = []
    while offset < len(data):
        length = data[offset]
        if length == 0:
            offset += 1
            break
        if length >= 192:
            break
        offset += 1
        labels.append(data[offset:offset + length].decode(errors="ignore"))
        offset += length
    return ".".join(labels), offset

def build_response(qid, name, ip):
    header = struct.pack("!HHHHHH", qid, 0x8400, 1, 1, 0, 0)
    nb = b""
    for label in name.split("."):
        nb += bytes([len(label)]) + label.encode()
    nb += bytes([0])
    question = nb + struct.pack("!HH", 1, 1)
    answer = nb + struct.pack("!HHIH", 1, 0x8001, 120, 4) + socket.inet_aton(ip)
    return header + question + answer

my_hostname = get_hostname()
my_ip = get_ip()
target = my_hostname + ".local"

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
except AttributeError:
    pass
sock.bind(("", MDNS_PORT))
mreq = struct.pack("4s4s", socket.inet_aton(MDNS_ADDR), socket.inet_aton("0.0.0.0"))
sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)

send_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)

log(f"mDNS unicast bridge started")
log(f"Hostname: {my_hostname} | IP: {my_ip} | Answering: {target} -> {my_ip}")

while True:
    try:
        data, addr = sock.recvfrom(4096)
        if addr[0] == my_ip or len(data) < 12:
            continue
        qid, flags, qdcount = struct.unpack("!HHH", data[:6])
        if flags & 0x8000:
            continue
        qname, _ = parse_name(data, 12)
        if qname.lower() == target:
            send_sock.sendto(build_response(qid, target, my_ip), addr)
            log(f"-> {addr[0]} asked for {qname}, replied {my_ip} via unicast")
    except Exception as e:
        log(f"ERROR: {e}")
