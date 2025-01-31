#!/bin/bash

source ./utils.sh

# Ask if the user wants to clean up resources first (can be given as an argument -y to clean up or -n to not clean up)
if [ "$1" = "-y" ]; then
    ./clean-up-resources.sh
elif [ "$1" = "-n" ]; then
    log "Skipping cleanup of resources."
else
    read -p "Do you want to clean up resources first? (y/n): " clean_up
    if [ "$clean_up" = "y" ]; then
        ./clean-up-resources.sh
    else
        log "Skipping cleanup of resources."
    fi
fi

# STATIC PARAMETERS
AMI_ID="ami-00ba9561b67b5723f" # Amazon Linux 2
USERNAME="ec2-user" # default for Amazon Linux

# PARAMETERS
IDENTIFIER=$RANDOM
STATIC_SITE_DIR="./static-site"
VPC_ID="vpc-07ef57799012c1cc9"
SUBNET_ID="subnet-000d0e8794b2fd59f"

# Create the tmp directory if it does not exist
mkdir --parents ./tmp \
    || { error "Failed to create the ./tmp directory."; exit 1; }

# Get the first instance type that is free tier eligible
INSTANCE_TYPE=$(aws ec2 describe-instance-types \
                    --filters Name=free-tier-eligible,Values=true \
                    --query 'InstanceTypes[0].InstanceType' \
                 | xargs
               )
[ -z "$INSTANCE_TYPE" ] \
    && { error "Failed to get free tier eligible instance type.";}

# Generate the key pair and set the permissions so SSH is happy
log "Generating SSH key pair..."
ssh-keygen \
    -t rsa \
    -b 2048 \
    -f ./tmp/$IDENTIFIER \
    -N "" \
    > /dev/null \
    || { error "Failed to generate SSH key."; }
chmod 600 ./tmp/$IDENTIFIER && chmod 600 ./tmp/$IDENTIFIER.pub
# Import the key pair to AWS
log "Importing SSH key pair to AWS..."
aws ec2 import-key-pair \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=${TAG_NAME},Value=\"\"}]" \
    --key-name "$IDENTIFIER" \
    --public-key-material fileb://./tmp/$IDENTIFIER.pub \
> /dev/null # quiet mode

# Create a security group for the EC2 instance
log "Creating security group..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
                        --tag-specifications "ResourceType=security-group,Tags=[{Key=${TAG_NAME},Value=\"\"}]" \
                        --group-name "$IDENTIFIER" \
                        --description "Temporary security group for static web server EC2 instances" \
                        --vpc-id "$VPC_ID" \
                        --query 'GroupId' \
                        --output text
                    )
# Check if the creation was successful
if [ "$SECURITY_GROUP_ID" = "None" ]; then
    error "Failed to create security group."
else
    log "Security group created with ID: $SECURITY_GROUP_ID"
fi
# Set the ingress rules for the security group to allow SSH, HTTP, and HTTPS
log "Setting ingress rules for security group..."
aws ec2 authorize-security-group-ingress \
    --group-id ${SECURITY_GROUP_ID} \
    --ip-permissions 'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]' \
                     'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]' \
                     'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' \
> /dev/null

# Start the EC2 instance with the given parameters
INSTANCE_ID=$(aws ec2 run-instances \
                --tag-specifications "ResourceType=instance,Tags=[{Key=${TAG_NAME},Value=\"\"}]" \
                --image-id "$AMI_ID" \
                --instance-type "$INSTANCE_TYPE" \
                --key-name "$IDENTIFIER" \
                --security-group-ids "${SECURITY_GROUP_ID}" \
                --subnet-id "$SUBNET_ID" \
                --count 1 \
                --associate-public-ip-address \
                --query 'Instances[0].InstanceId' --output text
            )
[ -z "$INSTANCE_ID" ] \
    && { error "Failed to launch EC2 instance.";}
log "EC2 instance started. Waiting for instance status ok..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances \
                --instance-ids "$INSTANCE_ID" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' \
                --output text \
           )
log "Instance is up at $PUBLIC_IP."

# Copy over static files with scp
log "Copying over static files."
scp -i ./tmp/$IDENTIFIER \
    -o StrictHostKeyChecking=no \
    -r $STATIC_SITE_DIR $USERNAME@$PUBLIC_IP:/home/$USERNAME/static-site \
> /dev/null

# Run commands through SSH
log "Installing Docker and running the container."
ssh -i ./tmp/$IDENTIFIER \
    -o StrictHostKeyChecking=no $USERNAME@$PUBLIC_IP \
    << SSH_COMMANDS > /dev/null 2>&1
        # Install Docker
        sudo yum update -y
        sudo yum install docker -y
        sudo usermod -a -G docker ec2-user
        id ec2-user
        newgrp docker
        sudo systemctl start docker
        sudo systemctl enable docker

        # Navigate to the static site directory
        cd /home/$USERNAME/static-site
        
        # Build the Docker container
        docker build -t static-site .
        
        # Run the Docker container
        docker run -d -p 80:3000 static-site
SSH_COMMANDS

log "The static site is now up at http://${PUBLIC_IP}/."