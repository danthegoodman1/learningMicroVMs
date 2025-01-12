bwrap   --ro-bind /usr /usr   --ro-bind /root/.deno /root/.deno   --ro-bind . /app   --ro-bind /etc/resolv.conf /etc/resolv.conf   --symlink usr/lib64 /lib64   --unshare-all   bash /app/thing.sh
