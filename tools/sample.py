#!/usr/bin/python3
# Per-second snapshot while a transfer runs: network and disk throughput, load per CPU core
# (in brackets: share spent in interrupts), and the busiest threads with the core they ran on.
# Usage: python3 sample.py SECONDS [IFACE] [DISK]      e.g.  python3 sample.py 30 wlan0 sda
import os, sys, time

secs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
iface = sys.argv[2] if len(sys.argv) > 2 else 'wlan0'
disk = sys.argv[3] if len(sys.argv) > 3 else 'sda'
HZ = os.sysconf('SC_CLK_TCK')


def net():
    for l in open('/proc/net/dev'):
        if l.strip().startswith(iface + ':'):
            f = l.split(':')[1].split()
            return int(f[0]), int(f[8])
    return 0, 0


def dsk():
    for l in open('/proc/diskstats'):
        f = l.split()
        if f[2] == disk:
            return int(f[5]) * 512, int(f[9]) * 512
    return 0, 0


def cpus():
    r = {}
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3].isdigit():
            f = l.split()
            v = [int(x) for x in f[1:9]]
            r[f[0]] = (sum(v), v[3] + v[4], v[5] + v[6])  # total, idle+iowait, irq+softirq
    return r


def procs():
    r = {}
    for d in os.listdir('/proc'):
        if not d.isdigit():
            continue
        try:
            for t in os.listdir('/proc/%s/task' % d):
                s = open('/proc/%s/task/%s/stat' % (d, t)).read()
                name = s[s.index('(') + 1:s.rindex(')')]
                f = s[s.rindex(')') + 2:].split()
                r[t] = (name, int(f[11]) + int(f[12]), f[36])
        except (OSError, ValueError):
            pass
    return r


n0, d0, c0, p0, t0 = net(), dsk(), cpus(), procs(), time.time()
rows = []
for i in range(secs):
    time.sleep(1.0)
    n1, d1, c1, p1, t1 = net(), dsk(), cpus(), procs(), time.time()
    dt = t1 - t0
    rx = (n1[0] - n0[0]) / dt / 1048576
    tx = (n1[1] - n0[1]) / dt / 1048576
    dr = (d1[0] - d0[0]) / dt / 1048576
    dw = (d1[1] - d0[1]) / dt / 1048576
    core = []
    for k in sorted(c1):
        tot = c1[k][0] - c0[k][0] or 1
        busy = 100.0 * (tot - (c1[k][1] - c0[k][1])) / tot
        irq = 100.0 * (c1[k][2] - c0[k][2]) / tot
        core.append('%3.0f(%2.0f)' % (busy, irq))
    top = []
    for pid, (name, ticks, cpu) in p1.items():
        if pid in p0:
            pc = 100.0 * (ticks - p0[pid][1]) / HZ / dt
            if pc >= 4:
                top.append((pc, name, cpu))
    top.sort(reverse=True)
    tops = ' '.join('%s@%s=%.0f' % (nm.replace(' ', '_')[:14], cpu, pc) for pc, nm, cpu in top[:7])
    print('%3d rx %5.1f tx %5.1f | hd r %5.1f w %5.1f | cores %s | %s' % (i + 1, rx, tx, dr, dw, ' '.join(core), tops))
    sys.stdout.flush()
    n0, d0, c0, p0, t0 = n1, d1, c1, p1, t1
