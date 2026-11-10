#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    _morrowpal_build_and_export() {
        local variable output tag status
        case "${1:-}" in
            backend) variable=BACKEND_TAG ;;
            app) variable=APP_TAG ;;
            website) variable=WEBSITE_TAG ;;
            *) "${BASH_SOURCE[0]}" "$@"; return $? ;;
        esac
        output="$(mktemp)" || return 1
        if MORROWPAL_IMAGE_TAG_OUTPUT_FILE="$output" "${BASH_SOURCE[0]}" "$@"; then
            if IFS= read -r tag <"$output" && [[ -n "$tag" ]]; then
                printf -v "$variable" '%s' "$tag"
                export "$variable"
                printf 'Exported %s=%s\n' "$variable" "$tag"
                status=0
            else
                printf 'Error: Builder did not return an image tag.\n' >&2
                status=1
            fi
        else
            status=$?
        fi
        rm -f -- "$output"
        return "$status"
    }
    if _morrowpal_build_and_export "$@"; then
        unset -f _morrowpal_build_and_export
        return 0
    else
        unset -f _morrowpal_build_and_export
        return 1
    fi
fi

set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
infrastructure_directory="$(cd -- "$script_directory/../.." && pwd)"

usage() {
    cat <<'EOF'
Usage: build-images.sh COMPONENT [APP_VERSION]

Build local release images and reserve the component's next build number.
COMPONENT is backend, app, or website. APP_VERSION is required for app.
When sourced, exports BACKEND_TAG, APP_TAG, or WEBSITE_TAG respectively.

Examples:
  source shared/scripts/build-images.sh backend
  source shared/scripts/build-images.sh app 1.1.0
  source shared/scripts/build-images.sh website
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

# The descriptor holds the component lock until the build exits, including on
# failure. Call directly so the reservation and lock stay in this process.
morrowpal_reserve_build_number() {
    local selected_component="$1"
    local repository_directory="$2"
    local counter_file="$repository_directory/build-numbers/$selected_component"
    local previous

    case "$selected_component" in backend|app|website) ;; *) return 1 ;; esac
    command -v flock >/dev/null 2>&1 || {
        printf 'Required command not found: flock\n' >&2
        return 1
    }
    [[ -f "$counter_file" ]] || {
        printf 'Build counter not found: %s\n' "$counter_file" >&2
        return 1
    }
    exec {MORROWPAL_BUILD_LOCK_FD}<>"$counter_file"
    flock --nonblock "$MORROWPAL_BUILD_LOCK_FD" || {
        printf 'Another %s release build is running in this checkout.\n' "$selected_component" >&2
        return 1
    }
    previous="$(cat "$counter_file")"
    [[ "$previous" =~ ^(0|[1-9][0-9]{0,8})$ ]] || {
        printf 'Invalid build counter: %s\n' "$counter_file" >&2
        return 1
    }
    MORROWPAL_BUILD_NUMBER=$((previous + 1))
    printf '%s\n' "$MORROWPAL_BUILD_NUMBER" >"$counter_file"
    printf 'Reserved %s build %s. Commit %s even if the build fails.\n' \
        "$selected_component" "$MORROWPAL_BUILD_NUMBER" "$counter_file" >&2
}

if (($# == 1)) && [[ "$1" == -h || "$1" == --help ]]; then usage; exit 0; fi
if (($# < 1)); then usage >&2; exit 2; fi
readonly component="$1"
case "$component" in
    backend|website)
        if (($# != 1)); then usage >&2; exit 2; fi ;;
    app)
        if (($# != 2)); then usage >&2; exit 2; fi
        [[ "$2" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
            || fail 'APP_VERSION must use major.minor.patch with non-negative integers' ;;
    *) fail 'Component must be backend, app, or website' ;;
esac

require_command docker
docker info >/dev/null 2>&1 || fail 'Docker daemon is not available'
case "$component" in
    backend) source_directory="${BACKEND_DIR:-$infrastructure_directory/../backend}" ;;
    app) source_directory="${APP_DIR:-$infrastructure_directory/../frontend}"
        require_command flutter
        require_command dart ;;
    website) source_directory="${WEBSITE_DIR:-$infrastructure_directory/../www}" ;;
esac

if [[ "$component" == website ]]; then
    require_command sha256sum
    for path in index.html robots.txt sitemap.xml styles.css assets privacy child-safety notifications; do
        [[ -e "$source_directory/$path" ]] || fail "Website source is missing: $source_directory/$path"
    done
    source_sha="$(
        cd "$source_directory"
        {
            printf '%s\0' index.html robots.txt sitemap.xml styles.css
            find assets privacy child-safety notifications -type f -print0
        } | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-7
    )"
else
    require_command git
    git -C "$source_directory" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || fail "$source_directory is not a Git worktree"
    [[ -z "$(git -C "$source_directory" status --porcelain)" ]] \
        || fail 'Source worktree must be clean before building'
    source_sha="$(git -C "$source_directory" rev-parse --short=7 HEAD)"
    if [[ "$component" == backend ]]; then
        [[ -f "$source_directory/Dockerfile" ]] || fail 'Backend Dockerfile is missing'
        [[ -x "$source_directory/gradlew" ]] || fail 'Gradle wrapper is not executable'
    fi
fi

morrowpal_reserve_build_number "$component" "$infrastructure_directory"
readonly image_tag="build-$MORROWPAL_BUILD_NUMBER-$source_sha"
labels=(--label "org.opencontainers.image.revision=$source_sha"
    --label "org.opencontainers.image.version=$image_tag")

case "$component" in
    backend)
        (
            cd "$source_directory"
            ./gradlew test apiTest jobTest --no-daemon
            for service in api job; do
                docker build --no-cache-filter runtime-base --pull --platform linux/amd64 \
                    --target "$service-runtime" "${labels[@]}" \
                    --tag "morrowpal/backend-$service:$image_tag" .
            done
        ) ;;
    app)
        (
            cd "$source_directory"
            flutter pub get
            dart run tool/build_web.dart "$2" "$MORROWPAL_BUILD_NUMBER"
            docker build --no-cache --pull --platform linux/amd64 \
                --build-context "web=$source_directory/build/web" "${labels[@]}" \
                --tag "morrowpal/app:$image_tag" "$infrastructure_directory/shared/runtime/app"
        ) ;;
    website)
        docker build --no-cache --pull --platform linux/amd64 \
            --build-context "website=$source_directory" "${labels[@]}" \
            --tag "morrowpal/website:$image_tag" "$infrastructure_directory/shared/runtime/website" ;;
esac

if [[ -n "${MORROWPAL_IMAGE_TAG_OUTPUT_FILE:-}" ]]; then
    printf '%s\n' "$image_tag" >"$MORROWPAL_IMAGE_TAG_OUTPUT_FILE"
fi
printf 'Built %s images locally: %s\n' "$component" "$image_tag"
