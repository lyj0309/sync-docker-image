#!/usr/bin/env bash
set -Eeuo pipefail

############################################
# 可配置项（按需修改/用环境变量覆盖）
############################################
# 目标仓库（必填，或运行前导出环境变量）
TARGET_REGISTRY="registry.ap-southeast-1.aliyuncs.com"

# 目标命名空间：
#  - 为空：保持原始路径（如 supabase/studio -> registry/supabase/studio）
TARGET_NAMESPACE="lyjp"

# 每个仓库同步的 tag 数量
NUM_TAGS="${NUM_TAGS:-10}"

# 优先使用 skopeo；设置为 0 强制用 docker CLI
# USE_SKOPEO="${USE_SKOPEO:-1}"
USE_SKOPEO="0"

# 干跑：1 只打印将要执行的动作，不实际拷贝
DRY_RUN="${DRY_RUN:-0}"

# （可选）排除某些 tag（正则），例如：'^latest$|^dev'
EXCLUDE_TAGS_REGEX="${EXCLUDE_TAGS_REGEX:-''}"
############################################
# 待同步的镜像列表
############################################
if [[ -n "${REPOS:-}" ]]; then
  # 去掉空行/注释，并处理可能的 \r
  readarray -t REPOS_ARR < <(printf '%s\n' "$REPOS" | sed 's/\r$//' | awk 'NF && $1!~/^#/')
else
  REPOS_ARR=(
    supabase/studio
    supabase/kong
    supabase/gotrue
    supabase/realtime
    supabase/storage-api
    supabase/imgproxy
    supabase/postgres-meta
    supabase/logflare
    supabase/vector
  )
fi

############################################
# 依赖检查
############################################
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_tools() {
  apt update && apt install -y curl jq  
  for c in curl jq; do
    if ! have_cmd "$c"; then
      echo "缺少依赖：$c" >&2
      exit 2
    fi
  done

  if [[ "$USE_SKOPEO" -eq 1 ]]; then
    if ! have_cmd skopeo; then
      echo "提示：未发现 skopeo，将回退到 docker CLI（仅同步当前架构）。" >&2
      USE_SKOPEO=0
    fi
  fi

  if [[ "$USE_SKOPEO" -eq 0 ]]; then
    for c in docker; do
      if ! have_cmd "$c"; then
        echo "缺少依赖：$c" >&2
        exit 2
      fi
    done
  fi
}

############################################
# 工具函数
############################################
# Docker Hub 按 last_updated 获取最新 N 个 tag
# 公有仓库无需认证；如要拉私有仓库，可在 curl 加 Authorization 头
list_latest_tags() {
  local repo="$1" n="${2:-10}"
  local ns="${repo%%/*}"
  local name="${repo##*/}"
  local url="https://hub.docker.com/v2/repositories/${ns}/${name}/tags?page_size=${n}&ordering=last_updated"

  # 简单重试 3 次
  local tries=0
  while (( tries < 3 )); do
    if out="$(curl -fsSL "$url")"; then
      echo "$out" | jq -r '.results[].name' | head -n "$n"
      return 0
    fi
    tries=$((tries+1))
    sleep $((2**tries))
  done

  echo "从 Docker Hub 获取 tags 失败：${repo}" >&2
  return 1
}

# 计算目标仓库的 repo 路径
# 输入：源 repo（如 supabase/studio）
# 输出：目标路径（不含 registry，不含 tag）
target_repo_path() {
  local repo="$1"
  local src_ns="${repo%%/*}"
  local src_name="${repo##*/}"

  if [[ -z "$TARGET_NAMESPACE" ]]; then
    echo "${src_ns}/${src_name}"
  else
        if [[ -z "$src_ns" ]]; then
      echo "${TARGET_NAMESPACE}/${src_name}"
        else
            echo "${TARGET_NAMESPACE}/${src_ns}-${src_name}"
        fi
  fi
}

# 目标是否已存在该 tag
exists_in_target() {
  local image_path="$1" tag="$2"
  if have_cmd skopeo; then
    skopeo inspect --raw "docker://${TARGET_REGISTRY}/${image_path}:${tag}" >/dev/null 2>&1
  else
    docker manifest inspect "${TARGET_REGISTRY}/${image_path}:${tag}" >/dev/null 2>&1
  fi
}

copy_one_tag_skopeo() {
  local src="$1" dst="$2"
  local cmd=(skopeo copy --all "docker://${src}" "docker://${dst}")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] ${cmd[*]}"
  else
    "${cmd[@]}"
  fi
}

copy_one_tag_docker() {
  local src="$1" dst="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] docker pull $src && docker tag $src $dst && docker push $dst"
    return 0
  fi
  docker pull "$src"
  docker tag "$src" "$dst"
  docker push "$dst"
}

############################################
# 主流程
############################################
main() {
  if [[ -z "$TARGET_REGISTRY" ]]; then
    echo "请设置 TARGET_REGISTRY，例如：export TARGET_REGISTRY=registry.example.com" >&2
    exit 2
  fi

  require_tools

  echo "开始同步到：${TARGET_REGISTRY}"
  echo "目标命名空间：${TARGET_NAMESPACE:-<保持原路径>}"
  echo "每个仓库同步最新 ${NUM_TAGS} 个 tag"
  [[ -n "$EXCLUDE_TAGS_REGEX" ]] && echo "将排除匹配正则的 tag：${EXCLUDE_TAGS_REGEX}"
  [[ "$DRY_RUN" -eq 1 ]] && echo "DRY-RUN 模式，仅显示将执行的操作。"

  for repo in "${REPOS[@]}"; do
    echo "==== 处理仓库：${repo} ===="
    mapfile -t tags < <(list_latest_tags "$repo" "$NUM_TAGS")
    if [[ "${#tags[@]}" -eq 0 ]]; then
      echo "未获取到 tags，跳过：${repo}"
      continue
    fi

    local_target_path="$(target_repo_path "$repo")"

    for tag in "${tags[@]}"; do
      # 可选过滤
      if [[ -n "$EXCLUDE_TAGS_REGEX" ]] && [[ "$tag" =~ $EXCLUDE_TAGS_REGEX ]]; then
        echo "跳过 tag（匹配排除规则）：$repo:$tag"
        continue
      fi

      src_ref="docker.io/${repo}:${tag}"
      dst_ref="${TARGET_REGISTRY}/${local_target_path}:${tag}"

    #   if exists_in_target "$local_target_path" "$tag"; then
    #     echo "已存在，跳过：$dst_ref"
    #     continue
    #   fi

      echo "复制：$src_ref  ->  $dst_ref"
      if [[ "$USE_SKOPEO" -eq 1 ]]; then
        copy_one_tag_skopeo "$src_ref" "$dst_ref"
      else
        copy_one_tag_docker "$src_ref" "$dst_ref"
      fi
    done
  done

  echo "全部完成。"
}

main "$@"
