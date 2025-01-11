# https://criu.org/Simple_loop
# not working yet on restore
set -e

PID=$(ps aux | grep deno | grep -v grep | awk '{print $2}')
echo got pid $PID

rm -rf images
mkdir images

echo dumping process and ending it
sudo criu dump -t $PID -vvvv --manage-cgroups -o dump.log --tcp-established --file-locks --images-dir ./images && echo done

ps aux | grep deno

echo restarting process
sudo criu restore -vvvv --manage-cgroups -o restore.log -d --tcp-established --file-locks --images-dir ./images && echo done
