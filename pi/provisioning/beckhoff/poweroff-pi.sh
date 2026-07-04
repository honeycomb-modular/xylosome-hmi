#!/bin/bash
# Runs on the BECKHOFF during shutdown — powers off the Pi HMI cleanly over SSH.
ssh -i /root/.ssh/id_pi -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    hoyte@192.168.2.3 'sudo systemctl poweroff' || true
