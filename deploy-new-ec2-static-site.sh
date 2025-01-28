#!/bin/bash

# Utility function for logging
log() {
    printf "$(date +'%Y-%m-%d %H:%M:%S') - $1\n"
}

# Trap signals and execute cleanup
clean_up() {
    log "Cleaning up..."
    log "Terminating instance..."
    # Check if ssh key exists before sshing in to shut the instance down
    [ -f ./tmp/$KEY_NAME ] \
        && ssh -i ./tmp/$KEY_NAME \
            -o StrictHostKeyChecking=no \
            $USERNAME@$PUBLIC_IP \
            "sudo shutdown -h now"
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
    log "Deleting key pair..."
    aws ec2 delete-key-pair --key-name "$KEY_NAME" > /dev/null
    log "Removing existing ingress rules..."
    aws ec2 revoke-security-group-ingress \
        --group-id ${SECURITY_GROUP_ID} \
        --ip-permissions 'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]' \
                         'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]' \
                         'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' \
    > /dev/null
    log "Deleting security group..."
    aws ec2 delete-security-group --group-id "$SECURITY_GROUP_ID" > /dev/null
    log "Removing temp files..."
    rm -f ./tmp/$KEY_NAME ./tmp/$KEY_NAME.pub
    exit 0
}
trap clean_up SIGINT SIGTERM EXIT

# PARAMETERS
KEY_NAME="tmp-static-site-key"
SECURITY_GROUP_NAME="temp-static-site-group"
SECURITY_GROUP_DESCRIPTION="Temporary security group for static web server EC2 instances"
STATIC_SITE_DIR="./static-site"

# STATIC PARAMETERS
AMI_ID="ami-00ba9561b67b5723f" # Amazon Linux 2
USERNAME="ec2-user" # default for Amazon Linux
VPC_ID="vpc-07ef57799012c1cc9"
SUBNET_ID="subnet-000d0e8794b2fd59f"

# VARIABLES TO BE ASSIGNED LATER
INSTANCE_ID="None"
SECURITY_GROUP_ID="None"
PUBLIC_IP="None"

# Create the tmp directory if it does not exist
mkdir --parents ./tmp \
    || { log "Failed to create the ./tmp directory."; exit 1; }

# Check if the key pair exists and delete it if so
[ -f ./tmp/$KEY_NAME ] \
    && rm -f ./tmp/$KEY_NAME ./tmp/$KEY_NAME.pub

# Generate the key pair and set the permissions so SSH is happy
log "Generating SSH key pair..."
ssh-keygen \
    -t rsa \
    -b 2048 \
    -f ./tmp/$KEY_NAME \
    -N "" \
    > /dev/null \
    || { log "Failed to generate SSH key."; exit 1; }
chmod 600 ./tmp/$KEY_NAME \
    && chmod 600 ./tmp/$KEY_NAME.pub

# Import the key pair to AWS
log "Importing SSH key pair to AWS..."
aws ec2 import-key-pair \
    --key-name "$KEY_NAME" \
    --public-key-material fileb://./tmp/$KEY_NAME.pub \
> /dev/null # quiet mode

# Get the first instance type that is free tier eligible
INSTANCE_TYPE=$(aws ec2 describe-instance-types \
                    --filters Name=free-tier-eligible,Values=true \
                    --query 'InstanceTypes[0].InstanceType' \
                 | xargs
                )
[ -z "$INSTANCE_TYPE" ] \
    && { log "Failed to get free tier eligible instance type."; exit 1; }

# Attempt to get the Security Group ID
log "Checking if security group exists..."
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
                        --filters Name=group-name,Values="$SECURITY_GROUP_NAME" \
                        --query 'SecurityGroups[0].GroupId' \
                        --output text
                    )
if [ "$SECURITY_GROUP_ID" = "None" ]; then
    # Create the security group
    log "Creating security group..."
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
                            --group-name "$SECURITY_GROUP_NAME" \
                            --description "$SECURITY_GROUP_DESCRIPTION" \
                            --vpc-id "$VPC_ID" \
                            --query 'GroupId' \
                            --output text
                        )
    # Check if the creation was successful
    if [ "$SECURITY_GROUP_ID" = "None" ]; then
        log "Failed to create security group."
        exit 1
    else
        log "Security group created with ID: $SECURITY_GROUP_ID"
    fi
else
    log "Security group already exists with ID: $SECURITY_GROUP_ID"
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
                --image-id "$AMI_ID" \
                --instance-type "$INSTANCE_TYPE" \
                --key-name "$KEY_NAME" \
                --security-group-ids "${SECURITY_GROUP_ID}" \
                --subnet-id "$SUBNET_ID" \
                --count 1 \
                --associate-public-ip-address \
                --query 'Instances[0].InstanceId' --output text
            )
[ -z "$INSTANCE_ID" ] \
    && { log "Failed to launch EC2 instance."; exit 1;}
log "EC2 instance started."

# Wait for the health checks to pass and get the public IP address
log "Waiting for instance status ok..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances \
                --instance-ids "$INSTANCE_ID" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' \
                --output text \
           )
log "Instance is up at $PUBLIC_IP."

# Copy over static files with scp
log "Copying over static files."
scp -i ./tmp/$KEY_NAME \
    -o StrictHostKeyChecking=no \
    -r $STATIC_SITE_DIR $USERNAME@$PUBLIC_IP:/home/$USERNAME/static-site \
> /dev/null

# Run commands through SSH
log "Installing Docker and running the container."
ssh -i ./tmp/$KEY_NAME \
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

# Keep the script running until error or manual exit
while true; do
    sleep 1
done