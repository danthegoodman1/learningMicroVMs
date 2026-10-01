import re, sys
names={0:"read",1:"write",2:"open",3:"close",7:"poll",9:"mmap",10:"mprotect",11:"munmap",13:"rt_sigaction",14:"rt_sigprocmask",17:"pread64",18:"pwrite64",19:"readv",20:"writev",28:"madvise",33:"dup2",44:"sendto",45:"recvfrom",46:"sendmsg",47:"recvmsg",56:"clone",72:"fcntl",202:"futex",232:"epoll_wait",257:"openat",262:"newfstatat",281:"epoll_pwait",291:"epoll_create1",290:"eventfd2",317:"seccomp",318:"getrandom",435:"clone3",16:"ioctl",157:"prctl",323:"userfaultfd",285:"fallocate",4:"stat",5:"fstat",8:"lseek",41:"socket",42:"connect",288:"accept4",49:"bind",50:"listen",131:"sigaltstack",302:"prlimit64",233:"epoll_ctl",
}
kvm={0xae01:"CREATE_VM",0xae80:"RUN",0xae41:"CREATE_VCPU",0x4020ae46:"SET_USER_MEMORY_REGION",0x4040ae77:"CREATE_PIT2",0xae60:"CREATE_IRQCHIP",0x4090ae82:"SET_REGS",0x4138ae84:"SET_SREGS",0x4008ae89:"SET_MSRS",0xc008ae88:"GET_MSRS",0x4008ae90:"SET_CPUID2",0x4400ae8f:"SET_LAPIC",0x5000aea5:"SET_XSAVE",0x4188aea7:"SET_XCRS",0x4040aea0:"SET_VCPU_EVENTS",0x4030ae7b:"SET_CLOCK",0x4020ae76:"IRQFD",0x4040ae79:"IOEVENTFD",0x4008ae6a:"SET_GSI_ROUTING",0xc008ae05:"GET_SUPPORTED_CPUID",0xae04:"GET_VCPU_MMAP_SIZE",0xae03:"CHECK_EXTENSION",0xae47:"SET_TSS_ADDR",0x400454ca:"TUNSETIFF",0xc018aa3f:"UFFDIO_API",0x8020aa00:"UFFDIO_REGISTER",0xc028aa03:"UFFDIO_COPY",0xae00:"GET_API_VERSION"}
txt = open(sys.argv[1]).read()  # bpftrace output of sys.bt
pids = [int(m.group(1)) for m in re.finditer(r'@ioctl_n\[(\d+), 44545\]', txt)]  # CREATE_VM
pid = int(sys.argv[2]) if len(sys.argv) > 2 else max(pids)
for l in txt.splitlines():
    if l.startswith(f"SLOW {pid} "): print(l)
def parse(name):
    d = {}
    for m in re.finditer(r'@'+name+r'\['+str(pid)+r', (\d+)\]: (\d+)', txt):
        d[int(m.group(1))] = int(m.group(2))
    return d
sn, sc, inn, ic = parse("sys_ns"), parse("sys_n"), parse("ioctl_ns"), parse("ioctl_n")
rows = [(v, f"sys {names.get(k,k)}", sc.get(k)) for k, v in sn.items()] + [(v, f"ioctl {kvm.get(k & 0xffffffff, hex(k & 0xffffffff))}", ic.get(k)) for k, v in inn.items()]
for v, n, c in sorted(rows, reverse=True)[:int(sys.argv[3]) if len(sys.argv) > 3 else 20]:
    print(f"{v/1e6:8.2f} ms  n={c:<6} {n}")
for k in ("kvm_pf", "user_pf", "uffd"):
    m = re.search(r'@'+k+r'\['+str(pid)+r'\]: (\d+)', txt); print(k, m.group(1) if m else 0)
