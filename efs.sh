#!/usr/bin/env bash
set -eo pipefail

# A bunch of text colors for echoing
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NOC='\033[0m'

# Checks if a value exists in an array
# Usage: elementIn "some_value" "${VALUES[@]}"; [[ #? -eq 0 ]] && echo "EXISTS!" || echo "DOESNT EXIST! :("
function elementIn () {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

function printUsage () {
    set -e
    cat <<EOF
  This plugin provides the ability to insert the AWS EFS FileSystemId variable into your
  value files to allow for dynamically populating this value  into the Helm chart during installs or upgrades.  I wrote this module
  because we use Terraform to bring up our EFS backed EKS environment and then run Helm Charts to bring up the application containers in EKS.

  Usage:
  Simply use helm as you would normally, but add 'efs' before any command,
  the plugin will query AWS for the FileSystemID value based on the name of the File system:

      {{efs EFSName region}}

  and populate that field with the value..
  Note: You must have permission to query EFS from the node where the Helm deploy is running..

  E.g:
  helm install stable/efs-provisioner -f value.dev.yaml efs

  value.dev.yaml:
  ---
  efsProvisioner:
    efsFileSystemId: "{{efs EFSName us-east-1}}"
    awsRegion: us-east-1
    storageClass:
      isDefault: false
    mountOptions:
      - tls
  ---
EOF
    exit 0
}


# Handle dependencies
# AWS cli
if ! [[ -x "$(command -v aws)" ]]; then
    echo -e "${RED}[ERROR] aws cli is not installed." >&2
    exit 1
fi


# get the first command (install\list\template\etc...)
cmd="$1"

# "helm efs/helm efs help/helm efs -h/helm efs --help"
if [[ $# -eq 0 || "$cmd" == "help" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
    printUsage
fi

# if the command is not "install" or "upgrade", or just a single command (no value files is a given in this case), pass the args to the regular helm command
if [[ $# -eq 1 || ( "$cmd" != "install" && "$cmd" != "upgrade" && "$cmd" != "template") ]]; then
    set +e # disable fail-fast
    helm "$*"
    EXIT_CODE=$?

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo -e "${RED}[EFS]${NOC} Helm exited with a non 0 code - this is most likely not a problem with the EFS plugin, but a problem with Helm itself." >&2
    fi

    exit ${EXIT_CODE} # exit with the same error code as the command
fi


VALUE_FILES=() # An array of paths to value files
OPTIONS=() # An array of all the other options given
while [[ "$#" -gt 0 ]]
do
    case "$1" in
    -h|--help)
        echo "usage!" # TODO proper usage
        exit 0
        ;;
    -f|--values)
        if [ $# -gt 1 ]; then # if we werent given just an empty '-f' option
            VALUE_FILES+=($2) # then add the path to the array
        fi
        ;;
    *)
        # we go over each options, and if the option isnt a value file, we add it to the options array
        set +e # we turn off fast-fail because the check of if the array contains a value returns exit code 0 or 1 depending on the result
        elementIn "$1" "${VALUE_FILES[@]}"
        [[ $? -eq 1 ]] && OPTIONS+=($1)
        set -e # when we're finished with the check, we turn on fast-fail
        ;;
    esac
    shift
done

echo -e "${GREEN}[EFS]${NOC} Options: ${OPTIONS[@]}"
echo -e "${GREEN}[EFS]${NOC} Value files: ${VALUE_FILES[@]}"

set +e # we disable fail-dast because we want to give the user a proper error message in case we cant read the value file
MERGED_TEXT=""
for FILEPATH in "${VALUE_FILES[@]}"; do
    echo -e "${GREEN}[EFS]${NOC} Reading ${FILEPATH}"

    if [[ ! -f ${FILEPATH} ]]; then
        echo -e "${RED}[EFS]${NOC} Error: open ${FILEPATH}: no such file or directory" >&2
        exit 1
    fi

    VALUE=$(cat ${FILEPATH} 2> /dev/null) # read the content of the values file silently (without outputing an error in case it fails)
    EXIT_CODE=$?

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo -e "${RED}[EFS]${NOC} Error: open ${FILEPATH}: failed to read contents" >&2
        exit 1
    fi

    VALUE=$(echo -e "${VALUE}" | sed s/\%/\%\%/g) # we turn single % to %% to escape percent signs
    printf -v MERGED_TEXT "${MERGED_TEXT}\n${VALUE}" # We concat the files together with a newline in between using printf and put output into variable MERGED_TEXT
done

PARAMETERS=$(echo -e "${MERGED_TEXT}" | grep -Eo "\{\{efs [^\}]+\}\}") # Look for {{efs EFSName us-east-1}} patterns, delete empty lines
PARAMETERS_LENGTH=$(echo "${PARAMETERS}" | grep -v '^$' | wc -l | xargs)
if [ "${PARAMETERS_LENGTH}" != 0 ]; then
    echo -e "${GREEN}[EFS]${NOC} Found $(echo "${PARAMETERS}" | grep -v '^$' | wc -l | xargs) parameters"
    echo -e "${GREEN}[EFS]${NOC} Parameters: \n${PARAMETERS[@]}"
else
    echo -e "${GREEN}[EFS]${NOC} No parameters were found, continuing..."
fi
echo -e "==============================================="


set +e
# using 'while' instead of 'for' allows us to use newline as a delimiter instead of a space
while read -r PARAM_STRING; do
    [ -z "${PARAM_STRING}" ] && continue # if parameter is empty for some reason

    CLEANED_PARAM_STRING=$(echo ${PARAM_STRING:2} | rev | cut -c 3- | rev) # we cut the '{{' and '}}' at the beginning and end
    EFSNAME=$(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 2) # {{efs *EFSName* us-east-1}}
    REGION=$(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 3) # {{efs EFSName *us-east-1*}}
    PROFILE=$(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 4) # {{efs EFSName us-east-1 *production*}}
    if [[ -n ${PROFILE}  ]]; then
       PROFILE_PARAM="--profile ${PROFILE}"
    fi
    PARAM_OUTPUT="$(aws efs describe-file-systems --query FileSystems[?Tag.Name=='EFSName'].FileSystemId --output text --region ${REGION} $PROFILE_PARAM  2>&1)" # Get the File Sytem ID or return error message
    EXIT_CODE=$?

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo -e "${RED}[EFS]${NOC} Error: Could not get parameter: ${EFSNAME}. AWS cli output: ${PARAM_OUTPUT}" >&2
        exit 1
    fi

    EFS_ID="$(echo -e "${PARAM_OUTPUT}" | sed -e 's/[]\&\/$*.^[]/\\&/g')"
    MERGED_TEXT=$(echo -e "${MERGED_TEXT}" | sed "s|${PARAM_STRING}|${EFS_ID}|g")
    sleep 0.5 # very basic rate limits
done <<< "${PARAMETERS}"

set +e
echo -e "${MERGED_TEXT}" | helm "${OPTIONS[@]}" --values -
EXIT_CODE=$?
if [[ ${EXIT_CODE} -ne 0 ]]; then
    echo -e "${RED}[EFS]${NOC} Helm exited with a non 0 code - this is most likely not a problem with the EFS plugin, but a problem with Helm itself." >&2
    exit ${EXIT_CODE}
fi
