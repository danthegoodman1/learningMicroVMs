import re, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
n = int(sys.argv[2]) if len(sys.argv) > 2 else 20
prev = 0.0
out = []
calls = []
for l in lines:
    m = re.match(r'(?:<\d+>)?\[\s*([\d.]+)\]\s?(.*)', l)
    if not m:
        continue
    t = float(m.group(1)); out.append((t - prev, t, m.group(2))); prev = t
    c = re.search(r'initcall (\S+) returned \S+ after (\d+) usecs', l)
    if c:
        calls.append((int(c.group(2)), c.group(1)))
print(f"last timestamp: {prev*1000:.1f} ms")
print("-- largest gaps before a line")
for d, t, l in sorted(out, reverse=True)[:n]:
    print(f"{d*1000:8.2f}ms @{t*1000:8.1f}  {l[:130]}")
if calls:
    print("-- slowest initcalls")
    for us, name in sorted(calls, reverse=True)[:n]:
        print(f"{us/1000:8.2f}ms  {name}")
    print(f"sum of initcalls: {sum(u for u,_ in calls)/1000:.1f} ms")
