# aws-scripts

## Requirements
- AWS CLI and SSH locally installed
- VPC and Subnet configured in AWS

## Scripts
*utils.sh*
Contains helper functions for the other scripts and the global tag name for created resources.
- log: Logs a message with a timestamp
- error: Logs an error message with a timestamp

*clean-up-resources.sh*
- Deletes all resources with the tag 'automatically-deployed-by-bwfiq-scripts'

*deploy-new-ec2-static-site.sh*
- Generates a new key pair and imports it to AWS
- Provisions a new security group allowing SSH, HTTP, and HTTPS ingress
- Provisions a new EC2 instance with the set Params
    - Instance type is t2.micro (free tier eligible)
    - AMI is Amazon Linux 2 (chosen for fastest boot time possible)
- SSHs into the new instance and installs docker
    - Uses [lipanski/docker-static-website](https://github.com/lipanski/docker-static-website) (httpd docker container ~100kB in size)
- Copies over files in the static-site directory (Dockerfile and HTML)
- Builds and runs the container

## To Do
- Provision a new VPS and subnet