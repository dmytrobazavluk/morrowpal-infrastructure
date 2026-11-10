#!/usr/bin/env bash

set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
infrastructure_directory="$(cd -- "$script_directory/../.." && pwd)"

load_push_environment() {
    local selected_environment="$1"
    local repository_directory="$2"
    local environment_file
    local expected_registry variable

    case "$selected_environment" in
        prod|staging)
            ;;
        *)
            printf 'Environment must be prod or staging.\n' >&2
            return 1
            ;;
    esac

    command -v ansible >/dev/null 2>&1 || {
        printf 'Required command not found: ansible\n' >&2
        return 1
    }

    environment_file="$(mktemp)"
    if ! ANSIBLE_CONFIG="$repository_directory/ansible.cfg" \
        ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
            ansible localhost \
                -i localhost, \
                --connection local \
                --module-name ansible.builtin.template \
                --args "src=$repository_directory/shared/runtime/compose.env.j2 dest=$environment_file mode=0600" \
                --extra-vars "@$repository_directory/environments/$selected_environment/vars.yml" >/dev/null; then
        rm -f -- "$environment_file"
        return 1
    fi

    set -a
    # shellcheck source=/dev/null
    source "$environment_file"
    set +a
    rm -f -- "$environment_file"

    for variable in MORROWPAL_AWS_ACCOUNT_ID MORROWPAL_AWS_REGION \
        MORROWPAL_ECR_REGISTRY MORROWPAL_ECR_REPOSITORY_PREFIX; do
        [[ -n "${!variable:-}" ]] || {
            printf 'Required environment value is missing: %s\n' "$variable" >&2
            return 1
        }
    done

    expected_registry="${MORROWPAL_AWS_ACCOUNT_ID}.dkr.ecr.${MORROWPAL_AWS_REGION}.amazonaws.com"
    [[ "$MORROWPAL_ECR_REGISTRY" == "$expected_registry" ]] || {
        printf 'Configured ECR registry does not match the selected account and Region.\n' >&2
        return 1
    }
}

usage() {
    cat <<'EOF'
Usage: push-images.sh ENVIRONMENT COMPONENT IMAGE_TAG [--confirm-production] [--dry-run]

Push existing local images and verify ECR digests and vulnerability scans.
ENVIRONMENT is staging or prod. COMPONENT is backend, app, or website.
Backend pushes both API and job images. No builds or counter changes occur.
Production requires --confirm-production. No environment defaults are used.

Example: shared/scripts/push-images.sh staging app "$APP_TAG"
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

if (($# == 1)) && [[ "$1" == -h || "$1" == --help ]]; then usage; exit 0; fi
if (($# < 3)); then usage >&2; exit 2; fi
readonly environment="$1" component="$2" image_tag="$3"
shift 3
confirm_production=false
dry_run=false
for argument in "$@"; do
    case "$argument" in
        --confirm-production) confirm_production=true ;;
        --dry-run) dry_run=true ;;
        *) fail "Unknown argument: $argument" ;;
    esac
done
case "$environment" in
    staging) [[ "$confirm_production" == false ]] || fail 'Production confirmation cannot be used with staging' ;;
    prod) [[ "$confirm_production" == true ]] || fail 'Production push requires --confirm-production' ;;
    *) fail 'Environment must be staging or prod' ;;
esac
case "$component" in
    backend) repositories=(backend-api backend-job) ;;
    app|website) repositories=("$component") ;;
    *) fail 'Component must be backend, app, or website' ;;
esac
[[ "$image_tag" =~ ^build-[1-9][0-9]*-[0-9a-f]{7}$ ]] || fail 'IMAGE_TAG must use build-N-SOURCEHASH'
for command in aws docker jq; do
    command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
done

load_push_environment "$environment" "$infrastructure_directory"
readonly aws_region="$MORROWPAL_AWS_REGION" registry="$MORROWPAL_ECR_REGISTRY"
actual_account="$(aws sts get-caller-identity --query Account --output text --region "$aws_region")"
[[ "$actual_account" == "$MORROWPAL_AWS_ACCOUNT_ID" ]] || fail 'AWS account does not match the selected environment'

# Resolve every image before any writes; pin Docker IDs so a local retag during
# a push cannot substitute different content. Existing RepoDigests let the next
# environment push verify the same manifest as the previous one.
local_ids=()
known_digests=()
for repository in "${repositories[@]}"; do
    local_image="morrowpal/$repository:$image_tag"
    local_id="$(docker image inspect --format '{{.Id}}' "$local_image")" \
        || fail "Local image is missing: $local_image"
    local_ids+=("$local_id")
    digest="$(docker image inspect --format '{{json .RepoDigests}}' "$local_id" \
        | jq -r '.[0] // "" | split("@") | .[1] // ""')"
    known_digests+=("$digest")
    printf '%s -> %s/%s/%s:%s (%s)\n' "$local_image" "$registry" \
        "$MORROWPAL_ECR_REPOSITORY_PREFIX" "$repository" "$image_tag" "$local_id"
done
if [[ "$dry_run" == true ]]; then
    printf 'Dry run: no images pushed, built, or deployed; counters unchanged.\n'
    exit 0
fi

docker_auth_directory="$(mktemp -d)"
cleanup() { rm -rf -- "$docker_auth_directory"; }
trap cleanup EXIT
aws ecr get-login-password --region "$aws_region" \
    | docker --config "$docker_auth_directory" login --username AWS --password-stdin "$registry"

wait_for_scan() {
    local repository="$1" result status critical high attempt
    for ((attempt=1; attempt<=30; attempt++)); do
        if result="$(aws ecr describe-image-scan-findings \
            --repository-name "$repository" --image-id "imageTag=$image_tag" \
            --query '{status:imageScanStatus.status,findings:imageScanFindings.findingSeverityCounts}' \
            --output json --region "$aws_region" 2>"$docker_auth_directory/scan-error")"; then
            status="$(jq -r .status <<<"$result")"
            case "$status" in
                COMPLETE)
                    printf '%s\n' "$result"
                    critical="$(jq -r '.findings.CRITICAL // 0' <<<"$result")"
                    high="$(jq -r '.findings.HIGH // 0' <<<"$result")"
                    ((critical == 0 && high == 0)) || fail "$repository has critical or high findings"
                    return 0 ;;
                IN_PROGRESS|PENDING) ;;
                *) fail "Image scan for $repository ended with status $status" ;;
            esac
        elif ! grep -Fq ScanNotFoundException "$docker_auth_directory/scan-error"; then
            cat "$docker_auth_directory/scan-error" >&2
            fail "Could not check scan for $repository"
        fi
        printf 'Waiting for scan of %s:%s (%s/30)...\n' "$repository" "$image_tag" "$attempt"
        if ((attempt < 30)); then sleep 10; fi
    done
    fail "Timed out waiting for scan of $repository:$image_tag"
}

for index in "${!repositories[@]}"; do
    repository="$MORROWPAL_ECR_REPOSITORY_PREFIX/${repositories[$index]}"
    target="$registry/$repository:$image_tag"
    docker tag "${local_ids[$index]}" "$target"
    docker --config "$docker_auth_directory" push "$target"
    remote_digest="$(aws ecr describe-images --repository-name "$repository" \
        --image-ids "imageTag=$image_tag" --query 'imageDetails[0].imageDigest' \
        --output text --region "$aws_region")"
    [[ "$remote_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Missing remote digest for $target"
    docker image inspect --format '{{json .RepoDigests}}' "${local_ids[$index]}" \
        | jq --exit-status --arg ref "$registry/$repository@$remote_digest" 'index($ref) != null' >/dev/null \
        || fail "Remote digest does not match the pushed local image: $target"
    [[ -z "${known_digests[$index]}" || "${known_digests[$index]}" == "$remote_digest" ]] \
        || fail "Manifest digest differs from the previously pushed image: $target"
    printf 'Verified %s@%s\n' "$registry/$repository" "$remote_digest"
    wait_for_scan "$repository"
done
printf 'Pushed and verified %s %s to %s; no build, deployment, or counter change.\n' \
    "$component" "$image_tag" "$environment"
