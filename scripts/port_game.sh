#!/usr/bin/env bash
# 一键 switch 游戏移植：把一个 Switch 游戏文件夹构建成 macOS .app（nxnative 仓库的薄封装）。
# 用法:
#   port_game.sh <游戏文件夹> -k <prod.keys> [-o <输出.app>] [--app-name <名字>]
#                [--platform mac-app|mac] [-l <语言>] [--seen-shaders] [--no-prebake]
#                [--survey-only] [-- <传给 build_ipa_from_nsp.py 的其它参数>]
# 不做的事: 不改仓库源码、不把游戏数据复制出游戏文件夹、不打印密钥内容。
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GAME_DIR=""; KEYS=""; OUT=""; APP_NAME=""; PLATFORM="mac-app"; LANG_CODE=""
SEEN=0; PREBAKE=1; SURVEY_ONLY=0; EXTRA=()

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

if [ $# -lt 1 ]; then usage; fi
GAME_DIR="${1%/}"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    -k|--keys) KEYS="${2:-}"; shift 2 ;;
    -o|--out) OUT="${2:-}"; shift 2 ;;
    --app-name) APP_NAME="${2:-}"; shift 2 ;;
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    -l|--language) LANG_CODE="${2:-}"; shift 2 ;;
    --seen-shaders) SEEN=1; shift ;;
    --no-prebake) PREBAKE=0; shift ;;
    --prebake) PREBAKE=1; shift ;;
    --survey-only) SURVEY_ONLY=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

if [ ! -d "$GAME_DIR" ]; then echo "错误: 游戏文件夹不存在: $GAME_DIR" >&2; exit 1; fi

# ---- Python（仓库工具需要 3.12+，必须 arm64）----
PY=""
for c in "$REPO/../venv/bin/python" "$REPO/venv/bin/python" "$HOME/venv/bin/python"; do
  if [ -x "$c" ]; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; raise SystemExit(0 if sys.version_info>=(3,12) else 1)' 2>/dev/null; then
    PY="$(command -v python3)"
  fi
fi
if [ -z "$PY" ]; then
  echo "错误: 找不到 Python 3.12+。先建 venv 并安装依赖:" >&2
  echo "  python3.14 -m venv ~/venv && ~/venv/bin/python -m pip install lz4 'capstone>=5,<6' fonttools zbic" >&2
  exit 1
fi

fail=0
note() { echo "  ✗ $1"; fail=1; }
echo "== 预检 =="

# 手动复制进来的 Metal 工具链不在 xcrun 的查找表里：xcrun -f metal 能找到，-f metallib 找不到（build 的 Mac shaders 阶段会失败）。
# 把工具链 bin 放进 PATH，xcrun 的最后一级查找即可命中。
for tc in /Library/Developer/Toolchains/Metal.xctoolchain/usr/metal/current/bin \
          /Applications/Xcode.app/Contents/Developer/Toolchains/Metal.xctoolchain/usr/metal/current/bin; do
  [ -x "$tc/metallib" ] && { PATH="$tc:$PATH"; export PATH; echo "  ✓ Metal 工具链 PATH: $tc"; break; }
done

# Xcode 与 Metal
DEV="$(xcode-select -p 2>/dev/null || true)"
case "$DEV" in
  */Xcode.app/Contents/Developer) echo "  ✓ Xcode: $DEV" ;;
  *) note "当前开发者目录不是 Xcode.app ($DEV): sudo xcode-select -s /Applications/Xcode.app" ;;
esac
if command -v xcrun >/dev/null 2>&1; then
  want="$(awk -F'\t' '$1=="metal_macosx"{print $2}' "$REPO/dm/gfx/tools/dmsh_chain.lock" 2>/dev/null)"
  got="$(xcrun -sdk macosx metal --version 2>&1 | head -1)"
  if [ -z "$got" ] || echo "$got" | grep -qi 'missing\|error'; then
    note "Metal 工具链不可用: xcodebuild -downloadComponent MetalToolchain"
  elif [ -n "$want" ] && ! echo "$got" | grep -qF "$want"; then
    note "Metal 版本不符: 需要 '$want'，实际 '$got'（装 Xcode 27.2；--allow-other-metal 有画面错误风险）"
  else
    echo "  ✓ Metal: $got"
  fi
fi

# 工具
for t in zstd make glslangValidator xcodebuild; do
  command -v "$t" >/dev/null 2>&1 && echo "  ✓ $t: $(command -v "$t")" || note "缺少工具 $t（brew install zstd glslang）"
done

# Python 依赖
if ! "$PY" -c 'import lz4.block, capstone, fontTools, zbic' 2>/dev/null; then
  note "Python 依赖缺失 ($PY): $PY -m pip install lz4 'capstone>=5,<6' fonttools zbic"
else
  cv="$("$PY" -c 'import capstone;print(capstone.__version__)')"
  case "$cv" in 5.*) echo "  ✓ Python: $PY (capstone $cv)" ;; *) note "capstone 必须是 5.x，当前 $cv" ;; esac
fi

# 磁盘（解包 + app 按游戏体积的 2 倍估，另留 15 GB）
if command -v du >/dev/null 2>&1; then
  size_gb=$(( $(du -sk "$GAME_DIR" 2>/dev/null | awk '{print $1+0}') / 1024 / 1024 ))
  need_gb=$(( size_gb * 2 + 15 ))
  avail_gb=$(( $(df -k "$GAME_DIR" | awk 'NR==2{print $4+0}') / 1024 / 1024 ))
  echo "  · 游戏 ${size_gb} GB，需要约 ${need_gb} GB，可用 ${avail_gb} GB"
  [ "$avail_gb" -ge "$need_gb" ] || note "磁盘不足：需要约 ${need_gb} GB，可用 ${avail_gb} GB"
fi

[ "$fail" -eq 0 ] || { echo "预检未通过，先修上面 ✗ 项。" >&2; exit 1; }

# SwiftUI 的 @State 宏由 swift-plugin-server 展开：在受限（沙箱）环境里它会被拒绝执行，
# pack_app 编译启动器时报 cannot assign to property: 'self' is immutable。探针失败时给 swiftc 垫一个 -disable-sandbox。
probe_dir="$(mktemp -d)"; shim_keep=""; probe_src="$probe_dir/probe.swift"
printf 'import SwiftUI\nstruct Probe: View {\n    @State private var n = 0\n    var body: some View { Button("x") { n += 1 } }\n}\n' > "$probe_src"
if ! swiftc -sdk "$(xcrun --show-sdk-path --sdk macosx)" -target arm64-apple-macos26.0 -swift-version 5 \
      -parse-as-library -module-cache-path "$probe_dir/mc" -c "$probe_src" -o "$probe_dir/probe.o" >/dev/null 2>&1; then
  mkdir -p "$probe_dir/shim"
  printf '#!/bin/sh\nreal=$(/usr/bin/xcrun --find swiftc) || exit 1\nexec "$real" -disable-sandbox "$@"\n' > "$probe_dir/shim/swiftc"
  printf '#!/bin/sh\nif [ "$1" = "--find" ] && [ "$2" = "swiftc" ]; then echo %s; exit 0; fi\nexec /usr/bin/xcrun "$@"\n' "$probe_dir/shim/swiftc" > "$probe_dir/shim/xcrun"
  chmod +x "$probe_dir/shim/swiftc" "$probe_dir/shim/xcrun"; PATH="$probe_dir/shim:$PATH"; export PATH
  shim_keep="$probe_dir"; echo "  ✓ swiftc 垫片: 当前环境不能展开 SwiftUI 宏，已加 -disable-sandbox"
fi
[ -n "$shim_keep" ] || rm -rf "$probe_dir"

# ---- 构建 ----
if [ -z "$OUT" ]; then OUT="$(cd "$GAME_DIR" && pwd)/$(basename "$GAME_DIR" | sed 's/：/ - /g; s/\//-/g').app"; fi
mkdir -p "$GAME_DIR/_port_logs"
LOG="$GAME_DIR/_port_logs/build_$(date +%Y%m%d_%H%M%S).log"

cmd=("$PY" "$REPO/scripts/build_ipa_from_nsp.py" "$GAME_DIR" --platform "$PLATFORM" --progress lines)
[ -n "$KEYS" ] && cmd+=(-k "$KEYS")
[ -n "$APP_NAME" ] && cmd+=(--app-name "$APP_NAME")
[ -n "$LANG_CODE" ] && cmd+=(-l "$LANG_CODE")
[ "$SEEN" -eq 1 ] && cmd+=(--seen-shaders)
[ "$PREBAKE" -eq 0 ] && [ "$PLATFORM" = "mac-app" ] && cmd+=(--no-prebake)
[ "$SURVEY_ONLY" -eq 1 ] && cmd+=(--survey-only)
[ "$PLATFORM" = "mac-app" ] && cmd+=(-o "$OUT")
[ ${#EXTRA[@]} -gt 0 ] && cmd+=("${EXTRA[@]}")

echo "== 构建 =="
echo "  命令: ${cmd[*]}"
echo "  日志: $LOG"
( cd "$REPO" && "${cmd[@]}" ) 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}

if [ "$status" -ne 0 ]; then
  echo
  echo "== 构建失败 (exit $status) =="
  tail -n 30 "$LOG"
  echo
  echo "常见原因:"
  grep -qE 'Metal toolchain|the Metal compiler|metal version' "$LOG" && echo "  · Metal 工具链/版本: xcodebuild -downloadComponent MetalToolchain（需 Xcode 27.2）"
  grep -qE 'missing modules|tools not found' "$LOG"        && echo "  · 依赖缺失: 按上文提示补装"
  grep -qE 'SetHeapSize OOM|MSF' "$LOG"                    && echo "  · 内存布局: 见仓库 docs/reference/memory.md 与 docs/agents/symptoms.md"
  grep -qE 'shader' "$LOG"                                 && echo "  · 着色器: 读 $REPO/dm/games/<id> 的日志与 docs/reference/shaders.md"
  echo "  完整排障: $REPO/docs/agents/symptoms.md"
  exit "$status"
fi

# ---- 结果 ----
echo
echo "== 完成 =="
if [ "$PLATFORM" = "mac-app" ]; then
  if [ -d "$OUT" ]; then
    echo "  app: $OUT"
    codesign --verify --strict "$OUT" 2>&1 && echo "  签名: OK (ad-hoc)" || echo "  签名: 校验未通过，请检查 pack_app 输出"
    ids="$(ls -1 "$GAME_DIR" | grep -oE '[0-9A-Fa-f]{16}' | sort -u | head -1)"
    [ -n "$ids" ] && echo "  运行日志: $HOME/Library/Logs/nxnative/$ids.log"
    echo "  冒烟测试: DM_LAUNCHER=0 \"$OUT/Contents/MacOS/nxnative\""
  else
    echo "  警告: 未在 $OUT 找到 app，检查日志 $LOG"
  fi
else
  echo "  Mac 开发构建完成（脚本末尾打印了运行命令）"
fi
echo "  构建日志: $LOG"
[ -n "$shim_keep" ] && rm -rf "$shim_keep"
