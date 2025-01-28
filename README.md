# aws-scripts

## Requirements
- AWS CLI and SSH locally installed

## Scripts
*deploy-new-ec2-static-site.sh*
- Generates a new key pair and imports it to AWS
- Provisions a new EC2 instance
- SSHs into the new instance and installs docker
- Copies over files in the static-site directory (Dockerfile and HTML)
- Builds and runs the container
If the script is ended or errors, the key pair and instance will be deleted from AWS.