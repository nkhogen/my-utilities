### Modify the below in scripts/provision.sh before running
```
yba_url="<yba_address>"
api_token="<your_api_key>"
customer_uuid="f33e3c9b-75ab-4c30-80ad-cba85646ea39"
instance_name="my-instance-1"
launched_by="<your user id>"

```

### Some other places that may need modifications in scripts/node-agent-provision.yaml. Modify only the non-placeholder ones. The placeholders are replaced when the script is run.
```
  provider:
    # Name of the cloud or infrastructure provider.
    # Examples: 'aws', 'gcp', 'azure', 'onprem'.
    name: my-test-provider

    # Region-specific settings.
    region:
      # Name of the region where the node is located.
      # Example: 'us-west-1'.
      name: us-west-2

      # Zone-specific settings within the region.
      zone:
        # Name of the availability zone.
        # Example: 'us-west-1a'.
        name: us-west-2a
```

### To run, simply do
```
cd ./scripts && ./provision.sh
or
./scripts/provision.sh
```
If it fails, keep running it as it is idempotent.
