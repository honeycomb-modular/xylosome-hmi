#!/bin/bash
# Runs on the BECKHOFF during shutdown — powers off the Windows capture PC over SSH.
ssh -i /root/.ssh/id_capture -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    hoyte@192.168.2.50 'shutdown /s /f /t 0' || true
