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

dest_name_from_source() {
  local src_image="$1" # 可能为 ghcr.io/org/app 或 library/alpine 或 org/app
  if [[ "${src_image}" == */*/* ]]; then
    local p1="${src_image%%/*}"          # 如 ghcr.io
    local rest="${src_image#*/}"         # org/app
    local p2="${rest%%/*}"               # org
    local name="${rest#*/}"              # app
    printf '%s/%s' "${p1//./-}-${p2}" "${name}"
  else
    local ns="${src_image%%/*}"
    local name="${src_image#*/}"
    printf '%s/%s' "${ns}" "${name}"
  fi
}

mirror_one_image() {
  local src_image="$1"        # 不带 tag 的源，如: adguard/adguardhome 或 ghcr.io/org/app
  local src_ref="docker://${src_image}"
  log "List tags for ${src_image}"
  mapfile -t tags < <(skopeo list-tags "${src_ref}" | jq -r '.Tags[]' | sort -V)

  if [[ "${TAG_POLICY}" == "recent_N" ]]; then
    mapfile -t tags < <(printf '%s\n' "${tags[@]}" | tail -n "${RECENT_N}")
  fi

  local dest_name
  dest_name="$(dest_name_from_source "${src_image}")"
  local dest_repo="docker://${ALIYUN_REGISTRY}/${ALIYUN_NAME_SPACE}/${dest_name}"

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


