# This runs the process without sharing resources with the terminal, so you don't need --shell-job. Works well for "recursive restore"

setsid deno run --allow-net counter.ts < /dev/null &> test.log &
