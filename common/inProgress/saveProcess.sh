#!/bin/bash
# TODO передавать юзера (pbk / ergonode)
pm2 save
sudo env PATH=$PATH:/usr/bin /usr/local/lib/node_modules/pm2/bin/pm2 startup systemd -u pbk --hp /home/pbk