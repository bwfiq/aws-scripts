# aws-scripts

## Requirements
- AWS CLI and SSH locally installed
- VPC and Subnet configured in AWS

## Scripts
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
If the script is ended or errors, the security group, key pair, and instance will be deleted from AWS.

## To Do
- Provision a new VPS and subnet