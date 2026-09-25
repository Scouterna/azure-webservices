#!/usr/bin/env bash
# Check that every image the cluster runs can still be pulled from its registry
# (docs/maintenance.md, "Upstream withdrawal").
#
# A running pod proves nothing: the node may be serving the image from its
# cache. Every node-image upgrade replaces the node and re-pulls everything, so
# an image deleted upstream breaks on the next weekly upgrade, not when it is
# deleted. On 2026-09-24 that took out the telemetry store, Loki and Thanos:
# MinIO Inc. had removed quay.io/minio/*.
#
# Asks each registry for the manifest anonymously, as a node does. Only reads.
# Needs kubectl (current context), curl and jq.
#
# Usage:
#   scripts/check-images-pullable.sh                  # every image in the cluster
#   echo quay.io/foo/bar:1.0 | scripts/check-images-pullable.sh -   # just these
set -euo pipefail

ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json'

list_cluster_images() {
  # Containers and init containers of pods, plus Job/CronJob templates (a
  # completed Job has no pod, but ArgoCD re-creates it on a rebuild).
  kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
  kubectl get jobs -A -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}'
  kubectl get cronjobs -A -o jsonpath='{range .items[*]}{range .spec.jobTemplate.spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}'
}

# Prints the HTTP status of an anonymous manifest HEAD for one image reference.
check() {
  local img=$1 ref digest="" reg path repo ver host challenge realm service token
  local -a auth=()
  ref=${img%@*}
  [[ $img == *@* ]] && digest=${img#*@}

  # Docker's rule: the first component is a registry only if there is a '/'
  # after it and it contains '.' or ':' or is localhost. `memcached:1.6` is not.
  reg=docker.io; path=$ref
  if [[ $ref == */* ]]; then
    local first=${ref%%/*}
    if [[ $first == *.* || $first == *:* || $first == localhost ]]; then
      reg=$first; path=${ref#*/}
    fi
  fi
  [[ $reg == docker.io && $path != */* ]] && path=library/$path
  repo=${path%:*}; ver=${path##*:}
  [[ $repo == "$path" ]] && ver=latest
  [[ -n $digest ]] && ver=$digest
  host=$reg; [[ $reg == docker.io ]] && host=registry-1.docker.io

  challenge=$(curl -s -o /dev/null -D - "https://$host/v2/" | tr -d '\r' \
    | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: *[Bb]earer *//p')
  if [[ -n $challenge ]]; then
    realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")
    service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")
    token=$(curl -s "$realm?service=$service&scope=repository:$repo:pull" | jq -r '.token // .access_token // empty')
    [[ -n $token ]] && auth=(-H "Authorization: Bearer $token")
  fi
  # -L: registry.k8s.io answers with a redirect to a regional mirror.
  curl -s -L -o /dev/null -w '%{http_code}' -I "${auth[@]}" -H "Accept: $ACCEPT" \
    "https://$host/v2/$repo/manifests/$ver"
}

if [[ ${1:-} == - ]]; then images=$(cat); else images=$(list_cluster_images); fi

failed=0
while read -r img; do
  [[ -z $img ]] && continue
  status=$(check "$img")
  if [[ $status == 200 ]]; then
    echo "ok    $img"
  else
    echo "FAIL  $img  (HTTP $status)"
    failed=$((failed + 1))
  fi
done < <(sort -u <<<"$images")

if (( failed )); then
  echo "$failed image(s) cannot be pulled. The next node replacement will leave their pods in ImagePullBackOff." >&2
  exit 1
fi
