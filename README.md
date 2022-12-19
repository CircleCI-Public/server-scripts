# CircleCI Scripts & Tools

This repository contains various tools and scripts which supports CircleCI server installation and migrations.

### [kots-exporter](./kots-exporter)

`kots-exporter` script downloads the KOTS config from CircleCI `server 3.x` and create a helm value file which can be used in CircleCI `server 4.0` installation.

### [migrate](./migrate)

`migrate` directory holds collection of scripts which is resposible for backing-up the data from CircleCI `server 2.x` which can be restored into CircleCI `server 3.x` or `server 4.x` instance.

### [passwords](./passwords)

`passwords` directory contains [generate_password.sh](./passwords/generate_password.sh) script which generates various password or secrets for CircleCI `server 4.x` helm value file.

### [support](./support/)

`support` directory contains support-bundle template and instruction to generate support-bundle.
