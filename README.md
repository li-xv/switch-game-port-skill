# 一键 switch 游戏移植（nxnative → macOS .app）

把 Nintendo Switch 游戏移植成 macOS 原生、可双击运行的 `.app` 的可复用流程与薄封装脚本。配套的 agent skill 是 [`SKILL.md`](./SKILL.md)，脚本是 [`scripts/port_game.sh`](./scripts/port_game.sh)。

不是模拟器：游戏自身代码直接运行在 Apple 芯片上，图形经 NVN / Vulkan / OpenGL → Metal 重建，Horizon 内核与 SDK 服务由 nxnative 仓库自带的 host 应答。

## 要求

- Apple 芯片 Mac，macOS 26.6+
- Xcode 27.2 与 Metal 工具链（版本必须与仓库 `dm/gfx/tools/dmsh_chain.lock` 一致）
- nxnative 仓库副本（本 skill 放在其 `.trae/skills/` 下）
- Python 3.12+（arm64）虚拟环境，已装 `lz4`、`capstone 5.x`、`fonttools`、`zbic`
- `brew install zstd glslang`
- 磁盘：约 2 × 游戏体积 + 15 GB

## 安装

```bash
# 把本仓库放进 nxnative 仓库的 .trae/skills/ 下
cp -R switch-game-port-skill "<nxnative 仓库>/.trae/skills/一键 switch 游戏移植"
chmod +x "<nxnative 仓库>/.trae/skills/一键 switch 游戏移植/scripts/port_game.sh"
```

脚本按自身位置定位 nxnative 仓库根目录，因此不需要额外配置 `REPO`。

## 用法

```bash
"<nxnative 仓库>/.trae/skills/一键 switch 游戏移植/scripts/port_game.sh" \
  "<游戏文件夹>" -k "<prod.keys>" -o "$HOME/Games/<游戏名>.app"
```

可选：`--app-name`、`--platform mac-app|mac`、`-l zh-Hans`、`--seen-shaders`、`--no-prebake`、`--survey-only`，`--` 之后的参数原样传给 `scripts/build_ipa_from_nsp.py`。

等价的原始命令：

```bash
cd "<nxnative 仓库>"
~/venv/bin/python scripts/build_ipa_from_nsp.py "<游戏文件夹>" -k "<prod.keys>" \
  --platform mac-app --app-name "<显示名>" -o "$HOME/Games/<游戏名>.app" --progress lines
```

## 流程要点

1. 预检：Xcode / Metal 版本 / 工具 / Python 依赖 / 磁盘。
2. 识别 title ID 与 profile：命中已注册版本则直接构建；版本不同则用派生配置；无 profile 先 `--survey-only` 走查。
3. 构建：解包 → 模块重写 → 着色器拆分 → Mac 着色器库 → Mac host → 管线归档 → 预烤 → 打包签名。最慢的是 Mac 着色器编译，中断后重跑会复用缓存。
4. 验证：`codesign --verify --strict`、资源齐全、`DM_LAUNCHER=0` 冒烟看日志。
5. 交付：`.app` 双击即玩；存档在 `~/Library/Application Support/nxnative/<title ID>/`，日志在 `~/Library/Logs/nxnative/<title ID>.log`。

完整步骤、排障对照表与已验证范例见 [`SKILL.md`](./SKILL.md)。

## 已验证

| 游戏 | 输入 | profile | 结果 |
|---|---|---|---|
| 塞尔达传说：王国之泪 1.2.1 | APP 1.0.0 + UPD 1.2.1（NSP） | `0100F2C0115B6000`（派生） | 21.2 GB，签名通过，冒烟帧推进 600 帧 |
| 塞尔达传说：旷野之息 1.6.0 | 单 XCI（本体 + 更新 + 2 DLC） | `01007EF00011E000`（派生） | 18.5 GB，签名通过，冒烟帧推进 900 帧 |

## 边界

- 只处理你自有的游戏文件；本仓库不含任何游戏数据、密钥或解密产物。
- 不修改 nxnative 仓库源码；构建中间产物留在游戏文件夹的 `<title ID>_build/`。
- 仅 macOS（Apple 芯片）；不覆盖 iOS IPA、模拟器或云游戏方案。
