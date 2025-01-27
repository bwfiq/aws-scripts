#!/bin/bash


# Trap signals and execute cleanup
clean_up() {
    echo "Cleaning up..."
    echo "Terminating instance..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null
    echo "Deleting key pair..."
    aws ec2 delete-key-pair --key-name "$KEY_NAME" > /dev/null
    echo "Removing temp files..."
    rm -f ./tmp/$KEY_NAME ./tmp/$KEY_NAME.pub
    exit 0
}
trap clean_up SIGINT SIGTERM EXIT

# Params
KEY_NAME="tmp-static-site-key"
INSTANCE_TYPE="t2.micro"
AMI_ID="ami-0c4e27b0c52857dd6" # Amazon Linux
USERNAME="ec2-user" # default for Amazon Linux
SECURITY_GROUP_IDS=("sg-0e15d2cc385cf72ec" "sg-063ee5c76100a8572")
SUBNET_ID="subnet-000d0e8794b2fd59f"
STATIC_SITE_DIR="./static-site"

# Create the tmp directory if it does not exist
mkdir -p ./tmp || { echo "Failed to create the ./tmp directory."; exit 1; }

# Check if the key pair was left over and delete it if so
[ -f ./tmp/$KEY_NAME ] && rm -f ./tmp/$KEY_NAME ./tmp/$KEY_NAME.pub

# Generate the key pair and import it to AWS
ssh-keygen -t rsa -b 2048 -f ./tmp/$KEY_NAME -N "" > /dev/null || { echo "Failed to generate SSH key."; exit 1; }
chmod 600 ./tmp/$KEY_NAME && chmod 600 ./tmp/$KEY_NAME.pub

# Import public key to AWS (fileb is binary file)
aws ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material fileb://./tmp/$KEY_NAME.pub > /dev/null

# Start the EC2 instance with the given parameters
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" --security-group-ids "${SECURITY_GROUP_IDS[@]}" --subnet-id "$SUBNET_ID" --count 1 --associate-public-ip-address --query 'Instances[0].InstanceId' --output text)
[ -z "$INSTANCE_ID" ] && { echo "Failed to launch EC2 instance."; exit 1;}
echo "EC2 instance started. Waiting for instance status ok..."
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Instance is up at $PUBLIC_IP."

# Copy over static files and run the container
echo "Copying over static files and running the container."
scp -i ./tmp/$KEY_NAME -o StrictHostKeyChecking=no -r $STATIC_SITE_DIR $USERNAME@$PUBLIC_IP:/home/$USERNAME/static-site
ssh -i ./tmp/$KEY_NAME  -o StrictHostKeyChecking=no $USERNAME@$PUBLIC_IP << EOF
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
EOF

# Keep the script running
while true; do
    sleep 1
done