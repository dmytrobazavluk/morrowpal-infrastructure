#!/usr/bin/env bash

set -Eeuo pipefail

readonly AWS_REGION="us-east-2"
readonly EXPECTED_AWS_ACCOUNT_ID="384078510608"
readonly API_REPOSITORY="morrowpal/prod/backend-api"
readonly JOB_REPOSITORY="morrowpal/prod/backend-job"
readonly SCAN_ATTEMPTS=30
readonly SCAN_WAIT_SECONDS=10

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="${BACKEND_DIR:-$INFRASTRUCTURE_DIR/../backend}"

logged_in=false
registry=""

usage() {
    cat <<'EOF'
Usage: publish-images.sh BUILD_NUMBER

Build, test, publish, and scan the production backend API and job images.

Arguments:
  BUILD_NUMBER  Positive, increasing integer used in the immutable image tag.

Example:
  ./infrastructure/prod/scripts/publish-images.sh 2

Set BACKEND_DIR to override the default sibling backend repository location.
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

list_repository_tags() {
    local repository="$1"

    aws ecr list-images \
        --repository-name "$repository" \
        --filter tagStatus=TAGGED \
        --query 'imageIds[].imageTag' \
        --output text \
        --region "$AWS_REGION"
}

wait_for_scan() {
    local repository="$1"
    local image_tag="$2"
    local attempt
    local status=""
    local critical
    local high

    for ((attempt = 1; attempt <= SCAN_ATTEMPTS; attempt++)); do
        if status="$(aws ecr describe-image-scan-findings \
            --repository-name "$repository" \
            --image-id "imageTag=$image_tag" \
            --query 'imageScanStatus.status' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null)"; then
            case "$status" in
                COMPLETE)
                    aws ecr describe-image-scan-findings \
                        --repository-name "$repository" \
                        --image-id "imageTag=$image_tag" \
                        --query '{status:imageScanStatus.status,findings:imageScanFindings.findingSeverityCounts}' \
                        --output json \
                        --region "$AWS_REGION"

                    critical="$(aws ecr describe-image-scan-findings \
                        --repository-name "$repository" \
                        --image-id "imageTag=$image_tag" \
                        --query 'imageScanFindings.findingSeverityCounts.CRITICAL' \
                        --output text \
                        --region "$AWS_REGION")"
                    high="$(aws ecr describe-image-scan-findings \
                        --repository-name "$repository" \
                        --image-id "imageTag=$image_tag" \
                        --query 'imageScanFindings.findingSeverityCounts.HIGH' \
                        --output text \
                        --region "$AWS_REGION")"
                    [[ "$critical" == "None" ]] && critical=0
                    [[ "$high" == "None" ]] && high=0

                    if ((critical > 0 || high > 0)); then
                        fail "$repository:$image_tag has $critical critical and $high high severity findings"
                    fi
                    return
                    ;;
                IN_PROGRESS)
                    ;;
                *)
                    fail "Image scan for $repository:$image_tag ended with status $status"
                    ;;
            esac
        fi

        if ((attempt < SCAN_ATTEMPTS)); then
            printf 'Waiting for the ECR scan of %s:%s (%d/%d)...\n' \
                "$repository" "$image_tag" "$attempt" "$SCAN_ATTEMPTS"
            sleep "$SCAN_WAIT_SECONDS"
        fi
    done

    fail "Timed out waiting for the ECR scan of $repository:$image_tag"
}

trap cleanup EXIT

if (($# != 1)); then
    usage >&2
    exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

readonly BUILD_NUMBER="$1"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "BUILD_NUMBER must be a positive integer"

require_command aws
require_command docker
require_command git

[[ -f "$BACKEND_DIR/Dockerfile" ]] || fail "Backend Dockerfile not found at $BACKEND_DIR/Dockerfile"
[[ -x "$BACKEND_DIR/gradlew" ]] || fail "Gradle wrapper is not executable at $BACKEND_DIR/gradlew"

git -C "$BACKEND_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "$BACKEND_DIR is not a Git worktree"

if [[ -n "$(git -C "$BACKEND_DIR" status --porcelain)" ]]; then
    fail "Backend worktree must be clean before publishing"
fi

readonly GIT_SHA="$(git -C "$BACKEND_DIR" rev-parse --short=7 HEAD)"
readonly IMAGE_TAG="build-$BUILD_NUMBER-$GIT_SHA"

actual_account_id="$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")"
[[ "$actual_account_id" == "$EXPECTED_AWS_ACCOUNT_ID" ]] \
    || fail "AWS account $actual_account_id does not match production account $EXPECTED_AWS_ACCOUNT_ID"

registry="$EXPECTED_AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
readonly API_IMAGE="$registry/$API_REPOSITORY:$IMAGE_TAG"
readonly JOB_IMAGE="$registry/$JOB_REPOSITORY:$IMAGE_TAG"

latest_build_number=0
for repository in "$API_REPOSITORY" "$JOB_REPOSITORY"; do
    repository_tags="$(list_repository_tags "$repository")"
    for existing_tag in $repository_tags; do
        if [[ "$existing_tag" =~ ^build-([0-9]+)- ]]; then
            existing_build_number="${BASH_REMATCH[1]}"
            if ((existing_build_number > latest_build_number)); then
                latest_build_number="$existing_build_number"
            fi
        fi
        [[ "$existing_tag" != "$IMAGE_TAG" ]] \
            || fail "Immutable tag already exists: $repository:$IMAGE_TAG"
    done
done

if ((BUILD_NUMBER <= latest_build_number)); then
    fail "BUILD_NUMBER must be greater than the latest published build number ($latest_build_number)"
fi

docker info >/dev/null 2>&1 || fail "Docker daemon is not available"

printf 'Publishing backend commit %s as %s\n' "$GIT_SHA" "$IMAGE_TAG"

(
    cd "$BACKEND_DIR"

    ./gradlew test apiTest jobTest --no-daemon

    docker build \
        --pull \
        --platform linux/amd64 \
        --target api-runtime \
        --label "org.opencontainers.image.revision=$GIT_SHA" \
        --label "org.opencontainers.image.version=$IMAGE_TAG" \
        --tag "$API_IMAGE" \
        .

    docker build \
        --pull \
        --platform linux/amd64 \
        --target job-runtime \
        --label "org.opencontainers.image.revision=$GIT_SHA" \
        --label "org.opencontainers.image.version=$IMAGE_TAG" \
        --tag "$JOB_IMAGE" \
        .
)

aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$registry"
logged_in=true

docker push "$API_IMAGE"
docker push "$JOB_IMAGE"

for repository in "$API_REPOSITORY" "$JOB_REPOSITORY"; do
    aws ecr describe-images \
        --repository-name "$repository" \
        --image-ids "imageTag=$IMAGE_TAG" \
        --query 'imageDetails[0].{tag:imageTags[0],digest:imageDigest,sizeBytes:imageSizeInBytes,pushedAt:imagePushedAt}' \
        --output json \
        --region "$AWS_REGION"

    wait_for_scan "$repository" "$IMAGE_TAG"
done

printf 'Published and verified %s\n' "$IMAGE_TAG"
