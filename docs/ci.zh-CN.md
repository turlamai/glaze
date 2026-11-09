# 在 CI 中交付 Glaze 应用

本页拥有**应用侧**的 CI 契约：用 Glaze 构建的产品在发布前应该证明什么。
Glaze 自身的流水线在 `.github/workflows/ci.yml`；应用不应复制该文件或其内部 job。

## 证据规则

某个平台的 gate 只能由该平台上的一次真实运行来满足。单元测试、开发机上的截图，
或一次成功的 `--help`，都不能替代打开真实窗口或启动打包产物。跳过、取消和未运行
的 job 不算通过。

## 最低门槛

| 门槛 | 命令 | 失败条件 |
| --- | --- | --- |
| 环境 | `raco glaze doctor --json` | `usable` 为 false 或退出码非 0：包归属、collection 解析或 WebView 可用性有问题 |
| Schema 契约 | `raco glaze schema check --json` | 相对已提交的 `glaze-schema.json` 出现协议、路由、命令、命名类型、错误或顺序破坏 |
| 原生验收 | `raco glaze verify` | 真实系统 WebView 未加载、URL 不符或截图失败 |
| 打包启动 | `raco glaze measure startup --seconds 3` | 打包产物在存活窗口内退出 |
| 体积预算 | `raco glaze measure size --budget budgets.json` | 任一产物超过其首个匹配 glob 的上限 |
| 安装器形态 | `raco glaze build --installer ...` 加平台自身校验 | 工具链被静默跳过、MSI 升级标识变化或包内容缺失 |
| 更新 | 应用自己的 N→N+1 场景 | 签名/哈希被错误拒绝，或未验证安装与回滚 |

在应用项目根目录、安装好 Glaze 与应用依赖后运行：

```bash
raco glaze doctor --json
raco glaze schema check --json
raco glaze verify
raco glaze build --name myapp --version 1.2.3 --publisher "Example Inc" \
  --identifier com.example.myapp --installer --sign -
raco glaze measure startup --seconds 3
raco glaze measure size --budget budgets.json
```

`doctor`、`schema check` 和 `measure` 失败时退出非 0；`verify` 返回项目验证脚本的
状态。生成的 `verify.rkt` 检查标题、URL 与 PNG 截图；请按应用的首启路由与持久化
断言扩展它（见[产品验收](product-acceptance.md)）。

体积预算是提交进仓库的 JSON；首个匹配的 glob 生效，所以最具体的产物写在最前面：

```json
{"rules": [{"glob": "*.dmg", "max-bytes": 400000000},
           {"glob": "*", "max-bytes": 500000000}]}
```

## Runner 要求

| 平台 | 要求 | 无人值守注意事项 |
| --- | --- | --- |
| macOS | 已登录的图形会话；用于 `codesign` 的 Xcode 命令行工具；公证需要 `notarytool` keychain profile | 托管 macOS runner 能打开 WKWebView 窗口；纯 SSH 主机不能 |
| Windows | WebView2 Runtime（托管 runner 已预装）；MSI 需要 WiX（`dotnet tool install --global wix --version 5.0.2`）；签名发布需要 `signtool` 与证书 | 未签名或 ad-hoc 构建不得作为发布产物 |
| Linux | GTK 3、WebKitGTK 4.1 开发包、`xvfb`、`dpkg`、`rpm`、AppImage 工具 | 窗口命令放在 `xvfb-run -a` 下；无 GPU 的 runner 设置 `WEBKIT_DISABLE_DMABUF_RENDERER=1` |

ARM64：Apple Silicon、Linux ARM64 与 Windows ARM64 都使用原生 Racket 构建。
Glaze 同时提供 `win-x64` 与 `win-arm64` `WebView2Loader.dll` 并按进程架构选择；
x64 构建也可以在 ARM64 主机上以模拟方式运行。托管 Intel macOS runner 只做构建
（没有 WindowServer 会话）；真实窗口的 Intel 证据需要桌面或自托管 runner。

无人值守 job 设置 `GLAZE_NO_STARTUP_DIALOG=1`，让 WebView 启动失败直接报错，
而不是卡在系统对话框上。该变量只抑制对话框，不抑制失败。

## 示例 job

以下只是起点，不是发布流水线：签名、公证和安装器发布需要仓库 secrets，并应放在
仅在发布时运行的 job 里。

```yaml
name: app-ci
on: [push, pull_request]
jobs:
  verify:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04, windows-latest, macOS-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v7
      - uses: Bogdanp/setup-racket@v1.15
        with:
          version: '9.3'
      - name: Install application
        shell: bash
        run: raco pkg install --auto --no-docs --link .
      - name: Compile and test
        shell: bash
        run: |
          raco make main.rkt
          # raco test test/   # 有应用测试套件时再启用
      - run: raco glaze schema check --json
      - run: raco glaze doctor --json
      - name: Native acceptance
        env:
          WEBKIT_DISABLE_DMABUF_RENDERER: '1'
          GLAZE_NO_STARTUP_DIALOG: '1'
        shell: bash
        run: |
          if [ "$RUNNER_OS" = "Linux" ]; then
            xvfb-run -a raco glaze verify
          else
            raco glaze verify
          fi
```

真实仓库应按 commit SHA 锁定 action，与 Glaze 自己的 workflow 一致。构建、安装器
和签名步骤放在发布分支，并把 secrets 限定在该 job。

## 不要用作 gate 的东西

单元测试、`doctor` 或截图本身都不是 gate：它们分别只证明逻辑、环境或一帧画面。
[产品验收](product-acceptance.md) 定义证据层级；本页负责产生证据的命令。

## 需要记录的证据

每个平台记录：

- 仓库 SHA、实际安装的 Glaze 版本（以及 `keel` 版本）、Racket 版本；
- 操作系统与架构；
- 产物名称与 SHA-256；
- 场景与确切命令；
- 运行 URL 或日志。

`glaze-schema.json` 与 `verify.rkt` 要像应用代码一样评审。为了让红色检查变绿而更新
schema baseline，会掩盖契约破坏；这必须是经过评审的显式变更。
