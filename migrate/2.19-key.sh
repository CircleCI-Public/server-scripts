#!/bin/bash

##
# CircleCI encryption & signing keys
##
function export_keys() {
    echo ... copying over encryption and signing keys

    mkdir -p "$KEY_BU"

    cp /data/circle/circleci-encryption-keys/* "$KEY_BU"
}
