---
name: 一键 switch 游戏移植
description: 将 Nintendo Switch 游戏（NSP / XCI / NSZ / XCZ / NUP 或 dump 文件夹 + prod.keys）通过本机 nxnative 仓库移植为可双击运行的 macOS 原生 .app，或排查/续跑一次移植构建。当用户说「移植某游戏到 Mac」「把这个 Switch 游戏打包成 app」「一键移植」「switch 游戏转 mac」时使用。
---

# 一键 switch 游戏移植

把 Switch 游戏变成 macOS 原生应用。不是模拟器：游戏自身代码直接运行在 Apple 芯片上，图形经 NVN/Vulkan/OpenGL → Metal 重建，Horizon 内核与 SDK 服务由仓库自带的 host 应答。

本 skill 是一套**可复用流程 + 一个薄封装脚本**，所有游戏走同一条路径；差异只来自游戏文件夹内容与是否有 profile。

## 0. 适用与不适用

**适用**
- macOS（Apple 芯片），已有 `nxnative` 仓库副本。
- 输入是玩家自有的游戏文件：NSP / XCI / NSZ / XCZ / NUP，或 dump 文件夹（`base/`、`updates/<版本>/`、`dlc/`）。
- 目标是 macOS `.app`（`--platform mac-app`）；`--platform mac` 仅用于开发调试。

**不适用**
- iOS IPA / Xcode 工程（那需要 iOS 平台组件与签名，走 `--platform ios`，不在本 skill 范围）。
- 模拟器方案、云游戏、任何绕过正版文件的请求。
- Windows / Intel Mac。

## 1. 约定（路径与变量）

| 变量 | 含义 | 默认 |
|---|---|---|
| `REPO` | nxnative 仓库根目录（本 skill 安装在其 `.trae/skills/` 下） | `~/nxnative` |
| `PY` | 带依赖的 Python（3.12+，arm64） | `~/venv/bin/python` |
| `GAME_DIR` | 游戏文件夹（放 NSP/XCI/NUP，或 dump 结构） | 由用户给出 |
| `KEYS` | `prod.keys` 路径（NSP/XCI 需要；dump/NUP 不需要） | 由用户给出 |
| `OUT` | 输出 `.app` 路径 | 建议与 `GAME_DIR` 同一 APFS 卷 |

约束（来自仓库规则，必须遵守）：
- 游戏文件、密钥、所有解包产物**只放在游戏文件夹内**；不复制进仓库，不放到 home 根目录。
- 构建中间产物固定在 `<GAME_DIR>/<title ID>_build/`（除非 `--work-dir`）。
- 不打印密钥内容；一切输出英文日志为仓库默认，交付说明可用中文。

## 2. 阶段 A：环境预检（缺一不可）

```bash
# 1) Xcode 必须选中（只有 Command Line Tools 时 Metal 与 iOS SDK 都不存在）
xcode-select -p            # 必须是 /Applications/Xcode.app/Contents/Developer

# 2) Metal 编译器版本必须与仓库锁一致
grep metal_macosx "$REPO/dm/gfx/tools/dmsh_chain.lock"    # 例如 32023.922
xcrun -sdk macosx metal --version                          # 必须一致
"$REPO/venv/bin/python" "$REPO/dm/gfx/tools/own_compilers.py" --check-metal   # 输出为空 = 通过

# 若报 “missing Metal Toolchain”：
xcodebuild -downloadComponent MetalToolchain

# 工具链是手动复制进 /Library/Developer/Toolchains 时，xcrun 只登记了 metal、没登记 metallib：
# 后面 Mac shaders 阶段会以 xcrun -f metallib 退出码 72 失败。把工具链 bin 加进 PATH 即可（脚本已自动做）
export PATH="/Library/Developer/Toolchains/Metal.xctoolchain/usr/metal/current/bin:$PATH"

# 3) 工具与 Python 依赖
command -v zstd make glslangValidator xcodebuild
"$PY" -c "import lz4.block, capstone, fontTools, zbic; print(capstone.__version__)"   # capstone 必须 5.x
# Python 需 3.12+（3.14 自带 compression.zstd，无需 backports.zstd）

# 4) 磁盘：≥ 2 × 游戏体积 + 10 GB
df -h "$GAME_DIR"
```

**版本不一致不绕过**：不要用 `--allow-other-metal` 蒙混，Metal 编译器不符会产出错误画面（仓库警告）。要么装 Xcode 27.2，要么让用户明确接受风险。

**Python 必须 arm64**（`sysctl -n sysctl.proc_translated` 为 1 时脚本会拒绝 Rosetta 解释器）。

## 3. 阶段 B：识别游戏与 profile

```bash
# title ID：文件名里的 16 位十六进制，或构建脚本自动识别；多游戏文件夹用 --title-id 指定
ls "$GAME_DIR"
"$PY" "$REPO/dm/games/game.py" list        # 已有 profile 的 title ID 列表
```

三种情况：

| 情况 | 判断 | 做法 |
|---|---|---|
| profile 存在且版本在 `build` 行 | `grep -P '^build\t' "$REPO/dm/games/<id>/game.tsv"` | 直接构建，全部按版本修补生效 |
| profile 存在但版本不同 | 同上，无对应 `build` 行 | **派生配置**：脚本在 `<GAME_DIR>/<id>_build/profile/<id>/` 生成，沿用 profile 全部键，按该版本自己的着色器表构建。会缺该 build 的字节级 `CUTS`；主机层修复与指纹匹配补丁（如 `MATCH_FRAME_STEP`）仍生效 |
| 无 profile | `game.py list` 里没有 | 先 `--survey-only` 产出 `<GAME_DIR>/<id>_survey/survey.md`；再按 `$REPO/docs/agents/01-extract.md` → `02-survey.md` → `03-bringup.md` 走查；之后用自动生成的临时 profile（`profile_guess.py`）构建；跑通后把 profile 与笔记落到 `$REPO/dm/games/<id>/`（见 §8） |

## 4. 阶段 C：构建

一键脚本（推荐）：

```bash
"$REPO/.trae/skills/一键 switch 游戏移植/scripts/port_game.sh" \
  "$GAME_DIR" -k "$KEYS" -o "$HOME/Games/<游戏名>.app"
```

等价的原始命令（脚本只是组装它）：

```bash
cd "$REPO"
"$PY" scripts/build_ipa_from_nsp.py "$GAME_DIR" -k "$KEYS" \
  --platform mac-app \
  --app-name "<显示名>" \
  -o "$HOME/Games/<游戏名>.app" \
  --progress lines
```

要点：
- 构建**很长**，全流程最慢的是 Mac 着色器全量编译，其次是管线预烤。用后台运行 + 读日志推进度，不要中断；中断后重跑会复用已完成步骤。
- 重跑时看 `Mac shaders · compiling: … N not cached`：N 很小说明缓存生效，只补没做完的。16 GB 机器同时开浏览器时可用 `DMSH_PROCS=4` 限制并发，避免 worker 因内存不足被系统杀掉（缓存仍然有效，重跑接着来）。
- 阶段顺序：NSP 校验/解包 → 模块重写（`patch_nso.py`）→ 着色器拆分 → Mac 着色器库（`dmsh_build.py`）→ Mac host（`make -C dm/host`）→ 管线离线归档（`pso_offline.py`）→ 预烤管线（`--prebake`，默认开）→ `pack_app.py` 打包 + ad-hoc 签名。
- 大文件在**同一 APFS 卷**上用 `cp -c` 克隆进 app，不额外占空间；跨卷则真实复制。
- 只是想要一个能跑起来看完的构建：`--no-prebake` 更快，代价是首次进入场景有编译卡顿。已有 `shader_seen.tsv` 的游戏可用 `--seen-shaders` 只编译玩到的着色器（无该表的 profile 会直接报错，此时只能全量）。
- 输出默认 `<GAME_DIR>/<游戏名>.app`；`-o` 指定别处时必须指向同一卷才省空间。
- 想边跑边调试：`--platform mac` 只产出 Mac host 与 Mac 着色器，脚本末行打印直接运行命令。

## 5. 阶段 D：验证（交付前必须全过）

```bash
APP="$HOME/Games/<游戏名>.app"
codesign --verify --strict --verbose=2 "$APP"
ls "$APP/Contents/Resources/romfs.img" "$APP/Contents/Resources/msl" \
   "$APP/Contents/Resources/pso" "$APP/Contents/Resources/dm"

# 无 UI 冒烟：跳过设置窗口直接起游戏
DM_LAUNCHER=0 "$APP/Contents/MacOS/nxnative" &
sleep 60
LOG="$HOME/Library/Logs/nxnative/<title ID>.log"
grep -n '^\[RED\] ' "$LOG"; grep -n 'build: commit' "$LOG"; grep -n 'frame step' "$LOG"
grep -n 'pipeline archive bundled with the app' "$LOG"
```

通过标准：
1. 签名校验通过，四项资源齐全（NVN 游戏有 `pso/`；Vulkan/GL 游戏对应 `msl/vk` / `msl/gl`）。
2. 日志无未处理的 `[RED] ` 行；有则按 §7 定位。
3. 日志出现 `build: commit … shader chain … profile …`，以及帧推进证据（present / `frame step` 行），说明已进入标题画面或场景。
4. 有预烤的构建出现 `pipeline archive bundled with the app` 命中行。
5. `~/Library/Application Support/nxnative/<title ID>/save/` 已生成。
6. 最后用正常双击（不设 `DM_LAUNCHER=0`）确认设置窗口（帧率/分辨率/语言/手柄布局）可出、点 Play 能进游戏；语言可在窗口里切换，无需重新打包。

## 6. 阶段 E：交付

- `.app` 直接放用户指定目录（默认与游戏文件同卷），双击即玩；不依赖构建目录或外部磁盘。
- 存档：`~/Library/Application Support/nxnative/<title ID>/`；日志：`~/Library/Logs/nxnative/<title ID>.log`（上一轮为 `.prev.log`）。
- 环境开关写在 `~/Library/Application Support/nxnative/<title ID>/env.txt`，例如 `DM_FPS_TARGET=30`（省电）、`DM_RENDER_SCALE=0.75`、`DM_LAUNCHER=0`。
- 本机构建无 quarantine 属性，通常可直接打开；若被 Gatekeeper 拦，去「系统设置 › 隐私与安全性 › 仍要打开」。app 为 ad-hoc 签名、无 hardened runtime、不公证。
- 增量重建：同一条命令再跑一次即可，未变化的步骤会复用（改 profile/着色器链才会重编译）。

## 7. 排障对照表（日志关键字 → 动作）

先查 `$REPO/docs/agents/symptoms.md`（按日志原文搜索），再进入对应 reference 篇目。

| 关键字 / 现象 | 含义 | 动作 |
|---|---|---|
| `the Metal compiler does not run` / `missing Metal Toolchain` | 未装 Metal 工具链 | `xcodebuild -downloadComponent MetalToolchain` |
| `unable to find utility "metallib"`（xcrun 退出码 72） | 工具链手动复制，xcrun 未登记 metallib | `export PATH="<Metal.xctoolchain>/usr/metal/current/bin:$PATH"` |
| `cannot assign to property: 'self' is immutable`（Launcher.swift） | 受限环境拒绝执行 swift-plugin-server，`@State` 宏没展开 | 用脚本的 swiftc 垫片（加 `-disable-sandbox`），或在普通终端里构建 |
| `Failed fetching catalog for assetType (com.apple.MobileAsset.MetalToolchain)` | 资产目录下载失败：网络/DNS 把 Apple 资产域名劫持或代理节点不可达 | 换代理节点或 DNS 后重试；仍失败时按 Apple DTS 的办法：`sudo defaults delete com.apple.MobileAsset EnableLiveAssetServerV2-com.apple.MobileAsset.MetalToolchain` 与 `sudo defaults delete com.apple.MobileAsset PallasUrlOverrideV2-com.apple.MobileAsset.MetalToolchain`，或改用 Xcode → Settings → Components 安装 Metal Toolchain |
| `the current Python … is missing modules` | 依赖不全 | 用 `$PY` 补装 lz4 / capstone 5.x / fonttools / zbic |
| `tools not found: …` | 缺 zstd / glslangValidator / make | `brew install zstd glslang` |
| `the selected developer folder is the Command Line Tools` | 未选 Xcode | `sudo xcode-select -s /Applications/Xcode.app` |
| `SetHeapSize OOM` | 堆区放不下 | 让 `HEAP_CHECK` 生效重建；必要时按 `docs/reference/memory.md` 调 `mem_*` 键 |
| `MSF` + 帧率骤降 / 被传回起点 | 资源堆耗尽（issue #70 类） | 该版本 profile 的 SDK 节点区削减规则未命中；需按 build ID 迁移补丁，见 `docs/agents/game-patches.md` |
| `shader regressions` / 着色器失败 | 翻译链回归 | 读 `logs/shader_regressions.log`，对照 `docs/reference/shaders.md`；不要盲目加 `--allow-shader-regressions` |
| 3D 场景全黑 | 条件渲染 / 纹理上传键 | 对照 `docs/reference/rendering.md`；NVN 流式纹理游戏需 `tex_flush_upload` / `tex_dirty_upload` |
| 画面品红 / 材质错乱 | ASTC/BC 纹理未上传或通道序 | 同上，先查症状索引 |
| 构建早停且提示版本不符 | 派生配置或文件损坏 | 检查 `build` 行、NSP 完整性（`--allow-damaged` 仅用于已知损坏副本） |
| 首次启动长时间无窗口 | 大 app 首次加载 / 系统校验 | 等待；必要时查 `_dyld_start` 相关说明 |

## 8. 记录（移植完成后，按仓库规则）

- 该游戏的事实写进 `$REPO/dm/games/<id>/README.md`（新增条目放在对应小节，标注 current / resolved）。
- 新游戏还需要：`game.tsv` + 着色器表 + `README.md`，并在 `$REPO/dm/games/README.md` 的表格里加一行。
- 通用机制（对其它游戏也成立的 host/工具改动）写进 `$REPO/docs/reference/<subsystem>.md`，然后跑 `"$PY" "$REPO/dm/tools/docs_symptoms.py"`。
- 任何 profile 键或补丁的改动，跑 `"$PY" "$REPO/dm/tools/docs_patches.py"`。

## 9. 已验证范例

| 游戏 | 输入 | profile | 结果 |
|---|---|---|---|
| 塞尔达传说：王国之泪 | `game/`（APP 1.0.0 + UPD 1.2.1，NSP） | `0100F2C0115B6000`（profile 验证版本 1.4.3 → 派生） | `塞尔达传说 王国之泪.app`（21.2 GB）：签名通过；冒烟无 `[RED]`（仅一条音频设备回调提示），帧推进到 600 帧，命中自带管线归档 |
| 塞尔达传说：旷野之息 | 单 XCI（本体 + 更新 + 2 DLC） | `01007EF00011E000`（profile 验证版本 1.9.0 → 派生） | `塞尔达传说 旷野之息.app`（18.5 GB）：签名通过；冒烟 0 条 `[RED]`，帧推进到 900 帧（30 fps），命中自带管线归档 |

两例的命令模板与 §4 完全一致，仅路径不同——这就是复用方式。
