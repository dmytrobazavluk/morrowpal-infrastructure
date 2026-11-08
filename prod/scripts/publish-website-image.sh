#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    _publish_website_image_and_export() {
        local tag_output_file
        local publish_status

        if (($# == 1)) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
            "${BASH_SOURCE[0]}" "$1"
            return
        fi

        tag_output_file="$(mktemp)" || return 1
        MORROWPAL_IMAGE_TAG_OUTPUT_FILE="$tag_output_file" "${BASH_SOURCE[0]}" "$@"
        publish_status=$?

        if ((publish_status == 0)); then
            if ! IFS= read -r WEBSITE_TAG <"$tag_output_file" || [[ -z "$WEBSITE_TAG" ]]; then
                printf 'Error: Publisher did not return WEBSITE_TAG\n' >&2
                publish_status=1
            else
                export WEBSITE_TAG
                printf 'Exported WEBSITE_TAG=%s\n' "$WEBSITE_TAG"
            fi
        fi

        rm -f "$tag_output_file"
        return "$publish_status"
    }

    if _publish_website_image_and_export "$@"; then
        unset -f _publish_website_image_and_export
        return 0
    else
        unset -f _publish_website_image_and_export
        return 1
    fi
fi

set -Eeuo pipefail

readonly scan_attempts=30
readonly scan_wait_seconds=10

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
infrastructure_dir="$(cd -- "$script_dir/../.." && pwd)"
website_dir="${WEBSITE_DIR:-$infrastructure_dir/../www}"
website_container_dir="$script_dir/../website"
# shellcheck source=morrowpal-runtime-config.sh
source "$script_dir/morrowpal-runtime-config.sh"
# shellcheck source=morrowpal-publish-config.sh
source "$script_dir/morrowpal-publish-config.sh"
logged_in=false
registry=""

usage() {
    cat <<'EOF'
Usage: publish-website-image.sh ENVIRONMENT BUILD_NUMBER

Build, publish, and scan a landing-page image.

Arguments:
  ENVIRONMENT   Target environment: prod or staging.
  BUILD_NUMBER  Positive, increasing integer used in the immutable image tag.

Example:
  source ./infrastructure/prod/scripts/publish-website-image.sh staging 1

Set WEBSITE_DIR to override the default sibling www source directory.
When sourced, the script exports WEBSITE_TAG in the current shell.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ "$logged_in" == true ]]; then
        docker logout "$registry" >/dev/null 2>&1 || true
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

wait_for_scan() {
    local scan_image_tag="$1"
    local attempt
    local status=""
    local critical
    local high

    for ((attempt = 1; attempt <= scan_attempts; attempt++)); do
        if status="$(aws ecr describe-image-scan-findings \
            --repository-name "$repository" \
            --image-id "imageTag=$scan_image_tag" \
            --query 'imageScanStatus.status' \
            --output text \
            --region "$aws_region" 2>/dev/null)"; then
            case "$status" in
                COMPLETE)
                    aws ecr describe-image-scan-findings \
                        --repository-name "$repository" \
                        --image-id "imageTag=$scan_image_tag" \
                        --query '{status:imageScanStatus.status,findings:imageScanFindings.findingSeverityCounts}' \
                        --output json \
                        --region "$aws_region"

                    critical="$(aws ecr describe-image-scan-findings \
                        --repository-name "$repository" \
                        --image-id "imageTag=$scan_image_tag" \
                        --query 'imageScanFindings.findingSeverityCounts.CRITICAL' \
                        --output text \
                        --region "$aws_region")"
                    high="$(aws ecr describe-image-scan-findings \
                        --repository-name "$repository" \
                        --image-id "imageTag=$scan_image_tag" \
                        --query 'imageScanFindings.findingSeverityCounts.HIGH' \
                        --output text \
                        --region "$aws_region")"
                    [[ "$critical" == "None" ]] && critical=0
                    [[ "$high" == "None" ]] && high=0
                    ((critical == 0 && high == 0)) \
                        || fail "$repository:$scan_image_tag has $critical critical and $high high severity findings"
                    return 0
                    ;;
                IN_PROGRESS)
                    ;;
                *)
                    fail "Image scan for $repository:$scan_image_tag ended with status $status"
                    ;;
            esac
        fi

        if ((attempt < scan_attempts)); then
            printf 'Waiting for the ECR scan of %s:%s (%d/%d)...\n' \
                "$repository" "$scan_image_tag" "$attempt" "$scan_attempts"
            sleep "$scan_wait_seconds"
        fi
    done

    fail "Timed out waiting for the ECR scan of $repository:$scan_image_tag"
}

trap cleanup EXIT

if (($# == 1)) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

if (($# != 2)); then
    usage >&2
    exit 2
fi

readonly environment="$1"
readonly build_number="$2"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "BUILD_NUMBER must be a positive integer"

require_command aws
morrowpal_load_publish_environment "$environment" "$infrastructure_dir"

readonly aws_region="$MORROWPAL_AWS_REGION"
readonly expected_aws_account_id="$MORROWPAL_AWS_ACCOUNT_ID"
readonly repository="$MORROWPAL_ECR_REPOSITORY_PREFIX/website"
registry="$MORROWPAL_ECR_REGISTRY"

actual_account_id="$(aws sts get-caller-identity --query Account --output text --region "$aws_region")"
[[ "$actual_account_id" == "$expected_aws_account_id" ]] \
    || fail "AWS account $actual_account_id does not match $environment account $expected_aws_account_id"

case "${MORROWPAL_PUBLISH_DRY_RUN:-false}" in
    true)
        printf 'Dry run: website image would publish to %s/%s in %s.\n' \
            "$registry" "$repository" "$aws_region"
        exit 0
        ;;
    false)
        ;;
    *)
        fail "MORROWPAL_PUBLISH_DRY_RUN must be true or false"
        ;;
esac

require_command docker
require_command sha256sum

for required_path in index.html robots.txt sitemap.xml styles.css assets privacy child-safety notifications; do
    [[ -e "$website_dir/$required_path" ]] \
        || fail "Website source is missing: $website_dir/$required_path"
done

source_sha="$(
    cd "$website_dir"
    {
        printf '%s\0' index.html robots.txt sitemap.xml styles.css
        find assets privacy child-safety notifications -type f -print0
    } | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-7
)"
readonly source_sha
readonly image_tag="build-$build_number-$source_sha"

existing_tags="$(aws ecr list-images \
    --repository-name "$repository" \
    --filter tagStatus=TAGGED \
    --query 'imageIds[].imageTag' \
    --output text \
    --region "$aws_region")"
latest_build_number=0
for existing_tag in $existing_tags; do
    if [[ "$existing_tag" =~ ^build-([0-9]+)- ]]; then
        existing_build_number="${BASH_REMATCH[1]}"
        if ((existing_build_number > latest_build_number)); then
            latest_build_number="$existing_build_number"
        fi
    fi
    [[ "$existing_tag" != "$image_tag" ]] \
        || fail "Immutable tag already exists: $repository:$image_tag"
done

((build_number > latest_build_number)) \
    || fail "BUILD_NUMBER must be greater than the latest published build number ($latest_build_number)"

readonly image="$registry/$repository:$image_tag"

docker build \
    --no-cache \
    --pull \
    --platform linux/amd64 \
    --build-context "website=$website_dir" \
    --label "org.opencontainers.image.revision=$source_sha" \
    --label "org.opencontainers.image.version=$image_tag" \
    --tag "$image" \
    "$website_container_dir"

aws ecr get-login-password --region "$aws_region" \
    | docker login --username AWS --password-stdin "$registry"
logged_in=true

docker push "$image"
wait_for_scan "$image_tag"

docker logout "$registry" >/dev/null 2>&1
logged_in=false

if [[ -n "${MORROWPAL_IMAGE_TAG_OUTPUT_FILE:-}" ]]; then
    printf '%s\n' "$image_tag" >"$MORROWPAL_IMAGE_TAG_OUTPUT_FILE"
fi

printf 'Published %s\n' "$image"
