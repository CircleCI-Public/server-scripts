#!/bin/bash

function key_reminder() {
    echo ""
    echo "###################################"
    echo "##   Encryption & Signing keys   ##"
    echo "##   must be uploaded to kots.   ##"
    echo "###################################"
    echo ""
    echo "You may find your keys here:  $(pwd)/${KEY_BU}"

    ls -lh $KEY_BU | grep -v ^total
}