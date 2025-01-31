#!/bin/bash

source ./utils.sh

# Clean up resources created by other scripts
TAG_NAME="automatically-deployed-by-bwfiq-scripts"

# Clean up all EC2 instances with the specified tag
# First describe-instances to get the instance IDs, then if its not empty, terminate-instances and wait for them to be terminated
log "Terminating all EC2 instances with tag $TAG_NAME..."
instance_ids=$(aws ec2 describe-instances \
                    --filters "[{\"Name\":\"tag:$TAG_NAME\",\"Values\":[\"\"]}]" \
                    --query "Reservations[*].Instances[*].InstanceId" \
                    --output text
                )
if [ -n "$instance_ids" ]; then
    aws ec2 terminate-instances --instance-ids $instance_ids > /dev/null
    log "Waiting for instances to be terminated..."
    aws ec2 wait instance-terminated --instance-ids $instance_ids
fi

# Clean up all security groups with the specified tag
# Since delete-security-group only works on one group at a time, we need to loop through all groups
log "Deleting all security groups with tag $TAG_NAME..."
for group_id in $(aws ec2 describe-security-groups \
                    --filters "[{\"Name\":\"tag:$TAG_NAME\",\"Values\":[\"\"]}]" \
                    --query "SecurityGroups[*].GroupId" \
                    --output text
                )
do
    aws ec2 delete-security-group --group-id $group_id > /dev/null
done

# Clean up all key pairs with the specified tag
# Since delete-key-pair only works on one key pair at a time, we need to loop through all key pairs
log "Deleting all key pairs with tag $TAG_NAME..."
for key_name in $(aws ec2 describe-key-pairs \
                    --filters "[{\"Name\":\"tag:$TAG_NAME\",\"Values\":[\"\"]}]" \
                    --query "KeyPairs[*].KeyName" \
                    --output text
                )
do
    aws ec2 delete-key-pair --key-name $key_name > /dev/null
done

# Clean up the ./tmp directory and delete all files under it
log "Cleaning up ./tmp directory..."
[ -d ./tmp ] || exit 0
find ./tmp -type f -print0 | xargs -0 rm -f
find ./tmp -type d -print0 | xargs -0 rmdir