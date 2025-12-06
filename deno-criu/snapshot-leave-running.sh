PID=$(ps aux | grep deno | grep -v grep | awk '{print $2}')

rm -rf images
mkdir images

echo "dumping process (leaving it running)"
sudo criu dump -t $PID -vvvv --manage-cgroups -o dump.log --shell-job --tcp-established --file-locks --leave-running --images-dir ./images && echo "dump done"

echo "sleeping 3 seconds..."
sleep 3

echo "killing process"
kill $PID

echo "restarting process from checkpoint"
sudo criu restore -vvvv --manage-cgroups -o dump.log --shell-job --tcp-established --file-locks --images-dir ./images
