#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: check-replacement-images.sh ENVIRONMENT RECORD.json\nRead-only AWS release tag/digest checks; not a complete cutover preflight.\n'; }
if [[ $# == 1 && "$1" == --help ]]; then usage; exit 0; fi
[[ $# == 2 ]] || { usage >&2; exit 2; }
environment="$1"
case "$environment" in staging|prod) ;; *) fail 'Environment must be staging or prod' ;; esac
for tool in aws jq ansible; do command -v "$tool" >/dev/null || fail "Required command not found: $tool"; done
umask 077
work_directory="$(mktemp -d)"
trap 'rm -rf -- "$work_directory"' EXIT
cp -- "$2" "$work_directory/record.json"
record="$work_directory/record.json"
bash "$script_directory/validate-replacement-record.sh" "$environment" "$record" >/dev/null
account="$(jq -r .accountId "$record")"
region="$(jq -r .region "$record")"
stack="morrowpal-$environment-ecr"
registry="$account.dkr.ecr.$region.amazonaws.com"
for variable in AWS_REGION AWS_DEFAULT_REGION; do
    [[ -z "${!variable:-}" || "${!variable}" == "$region" ]] || fail "$variable does not match the record Region"
done
export AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off
[[ "$(aws sts get-caller-identity --region "$region" --query Account --output text)" == "$account" ]] \
    || fail 'AWS account does not match the replacement record'
aws cloudformation describe-stacks --stack-name "$stack" --region "$region" --output json >"$work_directory/stack.json"
jq -e --arg arn "arn:aws:cloudformation:$region:$account:stack/$stack/" '
    (.Stacks | length) == 1 and (.Stacks[0].StackId | startswith($arn))
    and (.Stacks[0].StackStatus | IN("CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_ROLLBACK_COMPLETE"))
' "$work_directory/stack.json" >/dev/null || fail 'ECR stack identity/state mismatch'
# Both backend repositories use the backend release tag, with distinct recorded digests.
jq -r '[
    ["backend-api","BackendApi",.releases.backend.tag,.releases.backend.apiDigest],
    ["backend-job","BackendJob",.releases.backend.tag,.releases.backend.jobDigest],
    ["app","App",.releases.app.tag,.releases.app.digest],
    ["website","Website",.releases.website.tag,.releases.website.digest]
][] | @tsv' "$record" >"$work_directory/images.tsv"
while IFS=$'\t' read -r component output_key tag digest; do
    repository="morrowpal/$environment/$component"
    uri="$registry/$repository"
    arn="arn:aws:ecr:$region:$account:repository/$repository"
    jq -e --arg key "$output_key" --arg repository "$repository" --arg uri "$uri" '
        .Stacks[0] |
        [.Outputs[]? | select(.OutputKey == ($key + "RepositoryName")) | .OutputValue] == [$repository]
        and [.Outputs[]? | select(.OutputKey == ($key + "RepositoryUri")) | .OutputValue] == [$uri]
    ' "$work_directory/stack.json" >/dev/null || fail "$component ECR stack outputs mismatch"
    aws ecr describe-repositories --registry-id "$account" --repository-names "$repository" \
        --region "$region" --output json >"$work_directory/repository.json"
    jq -e --arg account "$account" --arg repository "$repository" --arg uri "$uri" --arg arn "$arn" '
        (.repositories | length) == 1 and (.repositories[0] |
            .registryId == $account and .repositoryName == $repository
            and .repositoryUri == $uri and .repositoryArn == $arn and .imageTagMutability == "IMMUTABLE")
    ' "$work_directory/repository.json" >/dev/null || fail "$component repository identity or tag immutability mismatch"
    aws ecr describe-images --registry-id "$account" --repository-name "$repository" \
        --image-ids "imageTag=$tag" --region "$region" --output json >"$work_directory/image.json"
    jq -e --arg account "$account" --arg repository "$repository" --arg tag "$tag" --arg digest "$digest" '
        (.imageDetails | length) == 1 and (.imageDetails[0] |
            .registryId == $account and .repositoryName == $repository and .imageDigest == $digest
            and (.imageTags | type == "array" and index($tag) != null)
            and (.imageStatus == null or .imageStatus == "ACTIVE"))
    ' "$work_directory/image.json" >/dev/null || fail "$component release tag/digest mismatch or inactive image"
done <"$work_directory/images.tsv"
printf '%s recorded release tags match all four ECR manifest digests. Scan, pull permissions, running containers and other cutover checks remain required.\n' "$environment"
