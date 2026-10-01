import bisect, subprocess, sys, collections
trace, vmlinux = sys.argv[1], sys.argv[2]
syms = []
for l in subprocess.run(["nm", "-n", vmlinux], capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if len(p) == 3 and p[1] in "tTwW":
        syms.append((int(p[0], 16), p[2]))
addrs = [a for a, _ in syms]
def sym(rip):
    i = bisect.bisect_right(addrs, rip) - 1
    return syms[i][1] if i >= 0 else hex(rip)
lines = [l.split() for l in open(trace) if l.strip()]
ex = [i for i, l in enumerate(lines) if l[:2] == ["EV", "exec"]]
lines = lines[ex[-1]:]
t_exec = int(lines[0][2])
xs = [(int(l[1]), int(l[2]), int(l[3], 16)) for l in lines if l[0] == "X"]
evs = [(int(l[2]), l[1]) for l in lines if l[0] == "EV"]
# attribute each interval between consecutive exits to the function at the later exit's RIP
prof = collections.Counter()
reasons = collections.Counter()
for (t0, _, _), (t1, r, rip) in zip(xs, xs[1:]):
    prof[sym(rip)] += t1 - t0
    reasons[r] += 1
print(f"first exit at {(xs[0][0]-t_exec)/1e6:.2f} ms after exec, last at {(xs[-1][0]-t_exec)/1e6:.2f} ms, {len(xs)} exits")
for t, e in evs:
    print(f"  {(t-t_exec)/1e6:8.2f} ms {e}")
print("exit reasons:", dict(reasons.most_common(8)))
print("-- guest time attributed by RIP at next exit (ms)")
for f, ns in prof.most_common(int(sys.argv[3]) if len(sys.argv) > 3 else 30):
    print(f"{ns/1e6:8.2f}  {f}")
# timeline in 5ms buckets: top function per bucket
if len(sys.argv) > 4:
    b = collections.defaultdict(collections.Counter)
    for (t0, _, _), (t1, r, rip) in zip(xs, xs[1:]):
        b[int((t1 - t_exec) / 2e6)][sym(rip)] += t1 - t0
    for k in sorted(b):
        top = ", ".join(f"{f}:{ns/1e6:.1f}" for f, ns in b[k].most_common(3))
        print(f"  {k*2:4d}-{k*2+2:<4d}ms {top}")
