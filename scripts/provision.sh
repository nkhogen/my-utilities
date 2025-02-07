#!/usr/bin/env bash
set -ex

# Please install jq if it is not already installed.

#---------------------------------------------------------------------------------------#
# Change these values to customize for you. You may need to also modify
# the non placeholder (NOT in angle brackets) values in node-agent-provision.yaml
# if more customizations are needed.
#---------------------------------------------------------------------------------------#

yba_url="<yba_address>"
api_token="<your_api_key>"
customer_uuid="f33e3c9b-75ab-4c30-80ad-cba85646ea39"
instance_name="my-instance-1"
launched_by="<your user id>"
instance_type="c5.large"
os_type="linux"
arch_type="amd64"


#---------------------------------------------------------------------------------------#
# Some internal constants. Not needed to be changed.
#---------------------------------------------------------------------------------------#
create_instance_template_json="create_instance_template.json"
create_instance_input_json="create_instance_input.json"
create_instances_output_json="create_instances_output.json"
node_agent_download_url="$yba_url/api/v1/node_agents/download"
node_agent_package="node-agent.tgz"
ynp_template_yaml="./node-agent-provision.yaml"
ynp_config_output_yaml="./node-agent-provision-output.yml"
key_pair_name="yb-dev-aws-2"
ssh_key_path="~/.yugabyte/yb-dev-aws-2.pem"
instance_user="ec2-user"


# Run a remote command.
run_remote_command() {
  ip="$1"
  shift
  command=$@
  ssh -q -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i "$ssh_key_path" ${instance_user}\@$ip "$command"
}

# Create an instance if it is not present by the name.
create_instance() {
  output=$(aws ec2 describe-instances --filters 'Name=tag:Name,Values='"${instance_name}"'')
  instance_absent=$(echo -n $output | jq -r 'all(.Reservations[].Instances[]; .State.Name == "terminated")')
  if [ "$instance_absent" == "false" ]; then
    echo "Instance ${instance_name} already exists. Skipping create instance."
    return 0
  fi
  echo "Creating instance $instance_name"
  instance_name="$instance_name" create_instance_input_json="$create_instance_input_json" key_pair_name="$key_pair_name" \
  instance_type="$instance_type" launched_by="$launched_by" \
  python - "${create_instance_template_json}" <<EOF
import json
import os
import sys
dict={}
with open(sys.argv[1]) as file:
  dict = json.load(file)
keys = list(dict['TagSpecifications'])
for key in list(dict):
  if key == 'TagSpecifications':
    for key in list(dict['TagSpecifications']):
      if key['ResourceType'] == 'instance':
        for tag in list(key['Tags']):
          if tag['Key'] == 'Name':
            tag['Value'] = os.getenv('instance_name')
          elif tag['Key'] == 'launched-by':
            tag['Value'] = os.getenv('launched_by')
        break
  elif key == 'KeyName':
    dict[key] = os.getenv('key_pair_name')
  elif key == 'InstanceType':
    dict[key] = os.getenv('instance_type')
with open(os.getenv('create_instance_input_json'), 'w') as f:
  json.dump(dict, f, indent=4)
EOF

aws ec2 run-instances --cli-input-json file://"${create_instance_input_json}" > "$create_instances_output_json"
instance_id=$(jq -r '.Instances[0].InstanceId' "$create_instances_output_json")
echo "Waiting for instance $instance_id to be running"
aws ec2 wait instance-running --instance-ids $instance_id
echo "Instance $instance_id is running"
}


setup_local_python() {
  pip install -r python_requirements.txt
}

setup_remote_python() {
    ip="$1"
    command="sudo dnf install -y python3.11 && sudo dnf install -y python3-pip && sudo alternatives \
    --install /usr/bin/python python /usr/bin/python3 0 && sudo dnf install -y python3-pip"
    run_remote_command $ip "$command"
}

# Generate the customized ynp node provisioner yaml and uploaded to the remote node.
generate_copy_ynp_yaml() {
  ip="$1"
  node_agent_folder="$2"
  ip="$ip" ynp_config_output_yaml="$ynp_config_output_yaml" yba_url="$yba_url" api_token="$api_token" \
  instance_name="$instance_name" customer_uuid="$customer_uuid" \
  python - "${ynp_template_yaml}" <<EOF
import os
import sys
import yaml
dict={}
with open(sys.argv[1]) as file:
  try:
    dict = yaml.safe_load(file)
  except yaml.YAMLError as exc:
    print(exc)
dict['yba']['url'] = os.getenv('yba_url')
dict['yba']['api_key'] = os.getenv('api_token')
dict['yba']['customer_uuid'] = os.getenv('customer_uuid')
dict['yba']['node_external_fqdn'] =  os.getenv('ip')
dict['yba']['node_name'] = os.getenv('instance_name')
dict['yba']['instance_type']['name'] = os.getenv('instance_name')
with open(os.getenv('ynp_config_output_yaml'), 'w') as file:
    yaml.dump(dict, file)
EOF
  scp -q -o 'StrictHostKeyChecking=no' -o UserKnownHostsFile=/dev/null  -i "$ssh_key_path" "${ynp_config_output_yaml}" \
  ${instance_user}\@$ip:"${node_agent_folder}/scripts/${ynp_template_yaml}"
}

provision_instance() {
  instance_id=$(jq -r '.Instances[0].InstanceId' "$create_instances_output_json")
  echo "Instance ID: $instance_id"
  private_ip_address=$(jq -r '.Instances[0].PrivateIpAddress' "$create_instances_output_json")
  echo "Private IP: $private_ip_address"
  root_device_name=$(jq -r '.Instances[0].RootDeviceName' "$create_instances_output_json")
  echo "Root Device: $root_device_name"
  lsblk_output=$(run_remote_command $private_ip_address "lsblk --noheadings -p -o +SERIAL | grep -s vol")
  readarray -t volumes <<< $lsblk_output
  for volume in "${volumes[@]}"; do
    echo "Volume: $volume"
    device_name=$(echo -n "$volume" | awk '{print $1}')
    volume_id=$(echo -n "$volume" | awk '{print $7}')
    echo "Device Name: $device_name, Volume ID: $volume_id"
    if run_remote_command $private_ip_address "grep -qs $device_name /proc/mounts"; then
      echo "Device $device_name is already mounted"
    else
      echo "Mounting device $device_name"
      run_remote_command $private_ip_address "sudo mkfs -t xfs $device_name"
      run_remote_command $private_ip_address "sudo mkdir -p /mnt/d0; sudo mount $device_name /mnt/d0"
    fi
    device_uuid=$(run_remote_command $private_ip_address "sudo blkid | awk '\$1==\"${device_name}:\" {print \$2}' | sed 's/\"//g' | cut -d '=' -f 2")
    echo $device_uuid
    if run_remote_command $private_ip_address "cat /etc/fstab | grep -qs UUID=$device_uuid"; then
      echo "Device $device_name is already in /etc/fstab"
    else
      echo "Adding device $device_name with UUID $device_uuid to /etc/fstab"
      run_remote_command $private_ip_address "echo \"UUID=$device_uuid /mnt/d0 xfs defaults 0 0\" | sudo tee -a /etc/fstab"
    fi
  done
  setup_remote_python $private_ip_address
  download_command="curl -s -k -w \"%{http_code}\" --location --request GET \
    \"$node_agent_download_url?downloadType=package&os=${os_type}&arch=${arch_type}\" \
    --header \"X-AUTH-YW-API-TOKEN: ${api_token}\" --output \"$node_agent_package\""
  run_remote_command $private_ip_address "$download_command"
  run_remote_command $private_ip_address "tar -zxf \"$node_agent_package\""
  node_agent_folder=$(run_remote_command $private_ip_address "tar -tzf \"$node_agent_package\" | grep \"version_metadata.json\" | awk -F '/' '\$2{print \$2;exit}'")
  generate_copy_ynp_yaml $private_ip_address $node_agent_folder
  run_remote_command $private_ip_address "cd \"$node_agent_folder/scripts\" && sudo ./node-agent-provision.sh"
}

cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd
setup_local_python
create_instance
provision_instance

