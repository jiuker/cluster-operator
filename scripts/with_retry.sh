#!/bin/bash

with_retry() {
  local retries=5
  until eval "$1"; do
    ((retries--))
    [ "$retries" -eq 0 ] && echo "Timed out." && exit 1
    echo "Retrying in 10 seconds ($retries retries left)..."
    sleep 10
  done
}
