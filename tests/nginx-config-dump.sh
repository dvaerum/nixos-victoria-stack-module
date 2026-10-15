conf=$(systemctl cat nginx.service | sed -n "s/^ExecStart=.*nginx -c '\{0,1\}\([^' ]*\).*/\1/p")
test -n "$conf"
nginx -T -c "$conf" 2>&1
