#!/bin/sh
journalctl | grep NovaCore | grep "GPU name:" 
if [ $? -ne 0 ]; then
  exit 1
fi
