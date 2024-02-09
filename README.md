# CircleCI Scripts & Tools

This repository contains various tools and scripts which supports CircleCI server installation and migrations.

## [passwords](./passwords)

`passwords` directory contains [generate_password.sh](./passwords/generate_password.sh) script which generates various password or secrets for CircleCI `server 4.x` helm value file.

## [support](./support/)

`support` directory contains support-bundle template and instruction to generate support-bundle.

## [vault-to-tink](./vault-to-tink/)

`vault-to-tink` enables a migration from a Vault installation to a (Google) Tink installation.
