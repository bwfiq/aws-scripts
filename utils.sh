#!/bin/bash

TAG_NAME="automatically-deployed-by-bwfiq-scripts"

log() {
    printf "$(date +'%Y-%m-%d %H:%M:%S') - $1\n"
}

error() {
    log "ERROR: $1"
    exit 1
}