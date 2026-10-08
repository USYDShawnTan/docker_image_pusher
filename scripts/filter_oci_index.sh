#!/usr/bin/env bash
set -euo pipefail

# Remove non-runnable descriptors (such as BuildKit attestation manifests)
# from a local OCI layout produced with skopeo copy --all to OCI.
# Preserve a source digest annotation so filtered images can be skipped later.
oci_dir="${1:?need OCI layout directory}"
ref_tag="${2:?need OCI reference tag}"
source_digest="${3:?need original source digest}"
index_file="${oci_dir}/index.json"

old_digest="$(jq -r --arg tag "${ref_tag}" \
  '[.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == $tag) | .digest] | first // empty' \
  "${index_file}")"
[[ "${old_digest}" == sha256:* ]] || { echo "OCI ref ${ref_tag} not found" >&2; exit 1; }

old_blob="${oci_dir}/blobs/sha256/${old_digest#sha256:}"
[[ -f "${old_blob}" ]] || { echo "Missing OCI index blob: ${old_blob}" >&2; exit 1; }

# Reject unexpected layout instead of silently producing a broken image.
jq -e '.manifests | type == "array"' "${old_blob}" >/dev/null || {
  echo "Ref ${ref_tag} is not an image index" >&2
  exit 1
}

new_index="$(mktemp)"
new_root="$(mktemp)"
trap 'rm -f "${new_index}" "${new_root}"' EXIT

jq --arg source_digest "${source_digest}" '
  .manifests |= map(select(
    (.platform.os? // "") != "" and
    (.platform.architecture? // "") != "" and
    .platform.os != "unknown" and
    .platform.architecture != "unknown" and
    (.annotations["vnd.docker.reference.type"]? != "attestation-manifest")
  )) |
  .annotations = ((.annotations // {}) + {
    "io.github.docker_image_pusher.upstream.digest": $source_digest
  })
' "${old_blob}" >"${new_index}"

old_count="$(jq '.manifests | length' "${old_blob}")"
new_count="$(jq '.manifests | length' "${new_index}")"
(( new_count > 0 )) || { echo "No runnable platform manifests remain" >&2; exit 1; }

new_sha="$(sha256sum "${new_index}" | awk '{print $1}')"
new_size="$(wc -c <"${new_index}" | tr -d ' ')"
new_digest="sha256:${new_sha}"
cp "${new_index}" "${oci_dir}/blobs/sha256/${new_sha}"

jq --arg old "${old_digest}" --arg new "${new_digest}" --argjson size "${new_size}" '
  .manifests |= map(if .digest == $old then .digest = $new | .size = $size else . end)
' "${index_file}" >"${new_root}"
mv "${new_root}" "${index_file}"
echo "[mirror] OCI index filtered: kept ${new_count}/${old_count} runnable manifests"
