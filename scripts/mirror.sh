#!/usr/bin/env bash
set -euo pipefail

# 环境变量（由 GitHub Actions 注入）
: "${ALIYUN_REGISTRY:?need ALIYUN_REGISTRY}"
: "${ALIYUN_NAME_SPACE:?need ALIYUN_NAME_SPACE}"
TAG_POLICY="${TAG_POLICY:-semver_with_latest}"   # all | semver | semver_with_latest | latest_only | recent_N | exact
RECENT_N="${RECENT_N:-50}"

# semver 正则：支持 v 前缀、预发布、构建元数据
SEMVER_RE='^(v?[0-9]+\.[0-9]+\.[0-9]+([\-+].*)?)$'

log() {
  echo "[mirror] $*"
}

inspect_digest_hash() {
  local ref="$1"
  if ! raw=$(skopeo inspect --raw "${ref}" 2>/dev/null); then
    return 1
  fi
  echo -n "${raw}" | sha256sum | awk '{print $1}'
}

declare -A DUPLICATE_MAP=()
declare -A NAME_SPACE_OF_IMAGE=()

# 预扫描 images.txt，找出同名镜像（不同上游命名空间）
detect_duplicates() {
  while IFS= read -r line; do
    line="$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${line}" || "${line}" =~ ^# ]] && continue
    local entry="${line%% --platform=*}"
    entry="${entry%%@*}"
    local src_no_tag="${entry%%:*}"

    local seg_count
    seg_count=$(awk -F'/' '{print NF}' <<<"${src_no_tag}")
    local image_name image_ns
    image_name="${src_no_tag##*/}"
    if [[ ${seg_count} -eq 3 ]]; then
      image_ns="$(awk -F'/' '{print $2}' <<<"${src_no_tag}")"
    elif [[ ${seg_count} -eq 2 ]]; then
      image_ns="$(awk -F'/' '{print $1}' <<<"${src_no_tag}")"
    else
      image_ns=""
    fi

    if [[ -z "${NAME_SPACE_OF_IMAGE["${image_name}"]+x}" ]]; then
      NAME_SPACE_OF_IMAGE["${image_name}"]="${image_ns}_"
    else
      if [[ "${NAME_SPACE_OF_IMAGE["${image_name}"]}" != "${image_ns}_" ]]; then
        DUPLICATE_MAP["${image_name}"]=true
      fi
    fi
  done < images.txt
}

# 生成符合 ACR 的目标仓库（仅两级：命名空间/仓库名）
dest_repo_from_source() {
  local src_image="$1"
  local seg_count
  seg_count=$(awk -F'/' '{print NF}' <<<"${src_image}")
  local image_name image_ns
  image_name="${src_image##*/}"
  if [[ ${seg_count} -eq 3 ]]; then
    image_ns="$(awk -F'/' '{print $2}' <<<"${src_image}")"
  elif [[ ${seg_count} -eq 2 ]]; then
    image_ns="$(awk -F'/' '{print $1}' <<<"${src_image}")"
  else
    image_ns=""
  fi

  local prefix=""
  if [[ -n "${DUPLICATE_MAP["${image_name}"]+x}" ]]; then
    if [[ -n "${image_ns}" ]]; then
      prefix="${image_ns}_"
    fi
  fi

  local repo_name
  repo_name="${prefix}${image_name}"
  repo_name="${repo_name,,}"
  repo_name="${repo_name//[^a-z0-9._-]/_}"

  printf 'docker://%s/%s/%s' "${ALIYUN_REGISTRY}" "${ALIYUN_NAME_SPACE}" "${repo_name}"
}

mirror_one_image() {
  local src_image="$1"        # 不带 tag 的源，如: adguard/adguardhome 或 ghcr.io/org/app
  local src_ref="docker://${src_image}"
  log "List tags for ${src_image}"
  mapfile -t tags < <(skopeo list-tags "${src_ref}" | jq -r '.Tags[]' | sort -V)

  if [[ "${TAG_POLICY}" == "recent_N" ]]; then
    mapfile -t tags < <(printf '%s\n' "${tags[@]}" | tail -n "${RECENT_N}")
  fi

  local dest_repo
  dest_repo="$(dest_repo_from_source "${src_image}")"

  for t in "${tags[@]}"; do
    case "${TAG_POLICY}" in
      all) : ;;
      semver)
        [[ "${t}" =~ ${SEMVER_RE} ]] || continue
        ;;
      semver_with_latest)
        if [[ "${t}" != "latest" && ! "${t}" =~ ${SEMVER_RE} ]]; then
          continue
        fi
        ;;
      latest_only)
        [[ "${t}" == "latest" ]] || continue
        ;;
      exact)
        # exact 策略需配合 images.txt 行内指定 tag，这里按需扩展
        :
        ;;
    esac

    local src_tag="${src_ref}:${t}"
    local dest_tag="${dest_repo}:${t}"

    log "Inspect source ${src_tag}"
    if ! src_hash=$(inspect_digest_hash "${src_tag}"); then
      log "Skip ${src_tag}: cannot inspect"
      continue
    fi

    dest_hash=""
    if dest_hash=$(inspect_digest_hash "${dest_tag}"); then
      :
    else
      dest_hash=""
    fi

    if [[ -n "${dest_hash}" && "${src_hash}" == "${dest_hash}" ]]; then
      log "Skip up-to-date ${dest_tag}"
      continue
    fi

    log "Copy ${src_tag} => ${dest_tag}"
    skopeo copy --all --retry-times 3 "${src_tag}" "${dest_tag}"
  done
}

# 读取 images.txt
detect_duplicates

while IFS= read -r line; do
  line="$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "${line}" || "${line}" =~ ^# ]] && continue

  # 去掉行末平台参数（如存在）以便全标签同步；如需按平台复制，可改为不使用 --all
  entry="${line%% --platform=*}"

  # 去掉 @sha256:... 指定，避免影响 list-tags
  entry="${entry%%@*}"

  # 若行中显式带 tag，如 org/app:1.2.3，这里仍按“全仓库”同步；
  # 如需仅同步该标签，可扩展 TAG_POLICY=exact 并按需解析。
  src_no_tag="${entry%%:*}"
  mirror_one_image "${src_no_tag}"
done < images.txt

log "All done."


