#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/filter_oci_index.sh"
root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
mkdir -p "${root}/blobs/sha256"

cat > "${root}/child.json" <<'JSON'
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:aaa", "size": 100, "platform": {"os": "linux", "architecture": "amd64"}},
    {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:bbb", "size": 200, "platform": {"os": "unknown", "architecture": "unknown"}, "annotations": {"vnd.docker.reference.type": "attestation-manifest"}},
    {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:ccc", "size": 150, "platform": {"os": "linux", "architecture": "arm64"}}
  ]
}
JSON
old_sha="$(sha256sum "${root}/child.json" | awk '{print $1}')"
cp "${root}/child.json" "${root}/blobs/sha256/${old_sha}"
jq -n --arg digest "sha256:${old_sha}" --argjson size "$(wc -c <"${root}/child.json")" \
  '{schemaVersion:2,manifests:[{mediaType:"application/vnd.oci.image.index.v1+json",digest:$digest,size:$size,annotations:{"org.opencontainers.image.ref.name":"mirror"}}]}' \
  >"${root}/index.json"

bash "${script}" "${root}" mirror sha256:source123
new_sha="$(jq -r '.manifests[0].digest | split(":")[1]' "${root}/index.json")"
child="${root}/blobs/sha256/${new_sha}"
[[ "$(jq -r '.manifests | length' "${child}")" == 2 ]]
[[ "$(jq -r '[.manifests[].platform.architecture] | join(",")' "${child}")" == 'amd64,arm64' ]]
[[ "$(jq -r '.annotations["io.github.docker_image_pusher.upstream.digest"]' "${child}")" == 'sha256:source123' ]]
[[ "$(wc -c <"${child}" | tr -d ' ')" == "$(jq -r '.manifests[0].size' "${root}/index.json")" ]]
echo "PASS: attestation removed, two runnable architectures and source digest preserved"

# Fail closed on a malformed or attestation-only image index.
mkdir -p "${root}/empty/blobs/sha256"
printf '%s\n' '{"schemaVersion":2,"manifests":[{"platform":{"os":"unknown","architecture":"unknown"},"digest":"sha256:x","size":2}]}' >"${root}/empty/blob"
empty_sha="$(sha256sum "${root}/empty/blob" | awk '{print $1}')"
cp "${root}/empty/blob" "${root}/empty/blobs/sha256/${empty_sha}"
jq -n --arg digest "sha256:${empty_sha}" '{schemaVersion:2,manifests:[{digest:$digest,annotations:{"org.opencontainers.image.ref.name":"mirror"}}]}' >"${root}/empty/index.json"
if bash "${script}" "${root}/empty" mirror sha256:source123 >/dev/null 2>&1; then
  echo "FAIL: accepted an index with no runnable platforms" >&2
  exit 1
fi
[[ "$(jq -r '.manifests[0].digest' "${root}/empty/index.json")" == "sha256:${empty_sha}" ]]
echo "PASS: invalid image index rejected without modifying root index"
