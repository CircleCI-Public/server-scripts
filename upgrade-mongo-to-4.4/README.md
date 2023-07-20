# Upgrading the MongoDB Image to 4.4

This script is to be used when [upgrading the MongoDB image](https://circleci.com/docs/server/v4.1/operator/upgrade-mongo/) used in your CircleCI server installs from 3.6 to 4.4.

## Prerequisites
- kubectl
- mongoDB is `internal` to your CircleCI server install

## Usage
1. Run: `./upgrade-mongo-image.sh -n <namespace>` 
2. Update the `mongodb` block values.yaml file with the following
```
mongodb:
  ...
  image:
    tag: 4.4.15-debian-10-r8
```
