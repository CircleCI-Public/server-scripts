# genPass.sh

This utility script will generate the passwords for CircleCI Server installation. 

## Prerequisite
- [docker](https://www.docker.com/get-started/) must be installed and running

## Usage

```
curl -Ls https://raw.githubusercontent.com/CircleCI-Public/server-scripts/main/passwords/generate_password.sh | bash 

# if docker is expecting sudo
curl -Ls https://raw.githubusercontent.com/CircleCI-Public/server-scripts/main/passwords/generate_password.sh | sudo bash 
```

## Supported Platform
- Mac
- Linux
- Windows (WSL)
