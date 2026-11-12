#!/usr/bin/python3
# Raw TCP throughput test, box side. Uses 1 MiB buffers, so unlike busybox nc it does not
# become the bottleneck itself.
# Usage: python3 nettest.py sink PORT            (box receives; PC sends)
#        python3 nettest.py source PORT BYTES    (box sends BYTES; PC receives)
# The PC side is tools/windows/net-test.ps1 (or any program that opens a TCP connection).
import socket, sys, time

mode, port = sys.argv[1], int(sys.argv[2])
total = int(sys.argv[3]) if len(sys.argv) > 3 else 0
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.bind(('::', port))
s.listen(1)
s.settimeout(30)
c, addr = s.accept()
c.settimeout(60)
buf = bytearray(1 << 20)
mv = memoryview(buf)
n = 0
t0 = time.time()
try:
    if mode == 'sink':
        while True:
            r = c.recv_into(mv)
            if not r:
                break
            n += r
    else:
        while n < total:
            n += c.send(mv[:min(len(buf), total - n)])
        c.shutdown(socket.SHUT_WR)
        c.recv(1)
except (BrokenPipeError, ConnectionResetError, socket.timeout):
    pass
dt = time.time() - t0
c.close()
print('box %s: %.1f MB in %.1f s = %.1f MB/s' % (mode, n / 1048576, dt, n / 1048576 / dt))
