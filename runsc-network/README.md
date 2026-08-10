Run
```
bash init.sh
bash network-setup.sh
bash run.sh
```

Following https://medium.com/@Mark.io/https-medium-com-mark-io-network-setup-with-runc-containers-46b5a9cc4c5b

Changes to config.json

```
"args": ["deno", "run", "--allow-net", "/app/counter.ts"],
...
"path": "/var/run/netns/test_net"
```

if you want to run the checkpoint, `"terminal": false`
