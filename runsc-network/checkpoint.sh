sudo runc run -pid-file pid.txt serv

# IN ANOTHER TERMINAL:
sudo runc pause serv
sudo runc list

echo sleeping 1s
sleep 1

sudo runc checkpoint --tcp-established --file-locks --image-path ckpt serv
sudo runc create serv
sudo runc restore -image-path ckpt serv
