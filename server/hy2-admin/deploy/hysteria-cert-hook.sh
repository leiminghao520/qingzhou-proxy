#!/bin/sh
set -eu
install -d -m 0750 -o root -g hysteria /etc/hysteria/tls
install -m 0640 -o root -g hysteria /etc/letsencrypt/live/proxy.lmh1103.icu/fullchain.pem /etc/hysteria/tls/fullchain.pem
install -m 0640 -o root -g hysteria /etc/letsencrypt/live/proxy.lmh1103.icu/privkey.pem /etc/hysteria/tls/privkey.pem
systemctl try-reload-or-restart hysteria-server.service
