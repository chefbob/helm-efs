# helm-efs
A low-dependency tool used to retrieves and inject the EFS File System ID based on the name.  This code was based heavily on https://github.com/totango/helm-ssm

## Installation
```bash
$ helm plugin install https://github.com/chefbob/helm-efs
```

## Overview
This plugin provides the ability to dynamically retrieve the EFS File System ID by passing in the name of the file system.
It can be used in combination with Terraform where Terraform creates a new EFS and Helm connects the EKS cluster to EFS with the efs-provisioner chart, https://github.com/helm/charts/tree/master/stable/efs-provisioner.

During installation or upgrade, the plugin retrieves the File System ID based on the name tag, and passes it to Tiller.

Usage:
Simply use helm as you would normally, but add 'efs' before any command,
the plugin will automatically search for values with the pattern:
```
{{efs EFSName aws-region}}
```
and replace them with the File System ID

Optionally, if you have the same EFS Name for different profiles, you can set it like this:
```
{{efs EFSName aws-region profile}}
```


>Note: You must have an IAM access policy in place that allows the instance running Helm to read the EFS parameters.

>Note #2: Wrap the template with quotes, otherwise helm will confuse the brackets for json, and will fail rendering.

>Note #3: Currently, helm-efs does not work when the value of the parameter is in the default chart values.

E.g:

helm install stable/efs-provisioner -f value.dev.yaml efs
```
value.dev.yaml:
---
efsProvisioner:
  efsFileSystemId: "{{efs EFSName us-east-1}}"
  awsRegion: us-east-1
  storageClass:
    isDefault: false
  mountOptions:
    - tls
```
---

## Testing
Create an EFS with the name TestEFS, then run the following command
```
$ ./efs.sh install tests/testchart/ --debug --dry-run -f tests/testchart/values.yaml
```
