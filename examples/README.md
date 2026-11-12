# Glaze Examples

**English** · [中文](#中文)

| Example | One line | Capabilities shown |
|---|---|---|
| [`showcase/`](showcase/) | **Every capability in one window (look here first)** | Macro routes in all shapes (type checks / 400 / :path / 500), SSE event stream + backend error flow-back (on-error), system features (clipboard / notification / reveal / window control), agent verification (title/url/capture + screenshot), API token (401 demo), update check, tray, single instance |
| [`taskboard/`](taskboard/) | **Product-grade example (run this first)** | Typed routes + store persistence + SSE snapshot push, generated client, lazy startup, `verify.rkt` real-window acceptance, domain/store/HTTP three-layer tests, schema baseline |
| [`hello/`](hello/) | 8-line minimal app | `run-app` one-liner entry, native window, static page |
| [`counter/`](counter/) | JS↔Racket bridge showcase | `define-api-routes`, SSE broadcast driving UI, generated `api.js` client, composable modules (`provide api/bus`) |
| [`webview-demo.rkt`](webview-demo.rkt) | Cross-platform WebView lifecycle | Native window, load/navigate/close/on-close/verification APIs printed live, watchdog |
| [`agent-verify.rkt`](agent-verify.rkt) | Unattended verification | Agent workflow: polled assertions + screenshot + exit code |
| [`tray-demo.rkt`](tray-demo.rkt) | Cross-platform tray | `make-tray` / menus / tooltip live updates |

Start new work from the [full tutorial](../docs/getting-started.md); the
examples here demonstrate individual capabilities, while the tutorial covers
`init`, typed APIs, schema checks, real-window verification, and building.

## Quick start

```bash
racket examples/showcase/main.rkt     # everything in one window (single-instance lock)
racket examples/counter/main.rkt      # bridge + events
racket examples/hello/main.rkt        # minimal app
```

Glaze examples always run in a native desktop WebView and never fall back to
the system browser. When a runtime dependency such as WebView2 or WebKitGTK is
missing, startup fails with the platform-specific installation/repair guidance.

Every example can be packaged with `raco glaze build`.

# 中文

| 示例 | 一句话 | 展示的能力 |
|---|---|---|
| [`showcase/`](showcase/) | **一屏看尽全部能力（推荐先看）** | 宏路由全形态（类型校验/400/:path/500）、SSE 事件流 + 后端错误回流（on-error）、系统功能（剪贴板/通知/Finder/窗口控制）、Agent 验证（title/url/capture + 截图回传）、API token（401 演示）、更新检查、托盘、单实例 |
| [`taskboard/`](taskboard/) | **产品级完整示例（推荐先跑）** | 类型化路由 + store 持久化 + SSE 快照推送、生成客户端、懒启动、`verify.rkt` 真窗口验收、域/store/HTTP 三层测试、schema 基线 |
| [`hello/`](hello/) | 8 行最小应用 | run-app 一键入口、原生窗口、静态页面 |
| [`counter/`](counter/) | JS↔Racket 桥接主打 | define-api-routes、SSE 广播驱动 UI、api.js 生成客户端、模块可组合（provide api/bus） |
| [`webview-demo.rkt`](webview-demo.rkt) | 跨平台 WebView 生命周期 | 原生窗口、加载/导航/关闭/on-close/验证 API 实时打印、看门狗 |
| [`agent-verify.rkt`](agent-verify.rkt) | 无人值守验证 | agent 工作流：轮询断言 + 截图 + 退出码 |
| [`tray-demo.rkt`](tray-demo.rkt) | 跨平台托盘 | make-tray/菜单/tooltip 动态更新 |

新应用从[完整入门教程](../docs/getting-started.zh-CN.md)开始；本页示例仅展示独立功能，统一教程涵盖 `init`、类型化 API、schema 检查、真窗口验证与构建。

## 快速开始

```bash
racket examples/showcase/main.rkt     # 综合演示（单实例锁定）
racket examples/counter/main.rkt      # 桥接 + 事件
racket examples/hello/main.rkt        # 最小应用
```

Glaze 示例只走原生桌面 WebView，不会退回系统浏览器。若 WebView2 / WebKitGTK 等运行时依赖缺失，启动会直接失败并打印对应平台的安装/修复指引。

所有示例均可 `raco glaze build` 打包为独立应用。
