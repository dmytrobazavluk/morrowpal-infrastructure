#!/usr/bin/env bash

set -Eeuo pipefail

readonly aws_region="us-east-2"
readonly expected_aws_account_id="384078510608"
readonly repository="morrowpal/prod/website"
readonly scan_attempts=30
readonly scan_wait_seconds=10

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
infrastructure_dir="$(cd -- "$script_dir/../.." && pwd)"
website_dir="${WEBSITE_DIR:-$infrastructure_dir/../www}"
website_container_dir="$script_dir/../website"
logged_in=false
registry=""

usage() {
    cat <<'EOF'
Usage: publish-website-image.sh BUILD_NUMBER

Build, publish, and scan the production landing-page image.

Arguments:
  BUILD_NUMBER  Positive, increasing integer used in the immutable image tag.

Example:
  ./infrastructure/prod/scripts/publish-website-image.sh 1

Set WEBSITE_DIR to override the default sibling www source directory.
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

if (($# != 1)); then
    usage >&2
    exit 2
fi

readonly build_number="$1"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "BUILD_NUMBER must be a positive integer"

require_command aws
require_command docker
require_command sha256sum

for required_path in index.html robots.txt sitemap.xml styles.css assets; do
    [[ -e "$website_dir/$required_path" ]] \
        || fail "Website source is missing: $website_dir/$required_path"
done

source_sha="$(
    cd "$website_dir"
    {
        printf '%s\0' index.html robots.txt sitemap.xml styles.css
        find assets -type f -print0
    } | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-7
)"
readonly source_sha
readonly image_tag="build-$build_number-$source_sha"

actual_account_id="$(aws sts get-caller-identity --query Account --output text --region "$aws_region")"
[[ "$actual_account_id" == "$expected_aws_account_id" ]] \
    || fail "AWS account $actual_account_id does not match production account $expected_aws_account_id"

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

registry="$expected_aws_account_id.dkr.ecr.$aws_region.amazonaws.com"
readonly image="$registry/$repository:$image_tag"

docker build \
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

printf 'Published %s\n' "$image"
