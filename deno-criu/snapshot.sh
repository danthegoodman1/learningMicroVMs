PID=$(ps aux | grep deno | grep -v grep | awk '{print $2}')

rm -rf images
mkdir images

echo dumping process and ending it
sudo criu dump -t $PID -vvvv --manage-cgroups -o dump.log --shell-job --tcp-established --file-locks --images-dir ./images && echo done

echo restarting process
sudo criu restore -vvvv --manage-cgroups -o dump.log --shell-job --tcp-established --file-locks --images-dir ./images
