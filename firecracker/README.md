Followed https://jvns.ca/blog/2021/01/23/firecracker--start-a-vm-in-less-than-a-second/#:~:text=how I put a Firecracker VM on the Docker bridge and https://gist.github.com/jvns/e13e6f498d26b584d8ab66651cdb04e0#file-firecracker-hello-world-docker-bridge-sh-L17 to get here


Likely also need to disable some other kernel args like serial console and such to improve the boot time

> The boot time is measured using a VM with the serial console disabled and a minimal kernel and root file system. For more details check the [boot time](https://github.com/firecracker-microvm/firecracker/blob/main/tests/integration_tests/performance/test_boottime.py) integration tests.

Need a faster init system too, faster than systemd, to boot faster, see https://github.com/alexellis/firecracker-init-lab which has an example Go init

See the API spec https://github.com/firecracker-microvm/firecracker/blob/main/src/firecracker/swagger/firecracker.yaml

See https://news.ycombinator.com/item?id=36666782 on memory usage specifically https://news.ycombinator.com/item?id=36669740 and codesandbox writes lots of great blog posts on firecracker and [he is very open to being DM’d about](https://x.com/CompuIves) the topic.
