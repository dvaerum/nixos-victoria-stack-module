# try-restart does nothing to a failed render oneshot, and "dependency failed"
# leaves the uploader inactive with no Restart=. A render that is `failed` (not
# `inactive`, which is what a deliberate stop leaves) means the previous file was
# unusable: start the uploader, which pulls the render oneshot in again.
if [ "$(systemctl show -p ActiveState --value victoria-collector-journal-upload-token.service)" = failed ]; then
  systemctl start --no-block systemd-journal-upload.service
fi
