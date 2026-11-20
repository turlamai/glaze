# 系统 Now Playing（宿主自有）

Glaze 从**宿主进程**把产品播放状态发布到操作系统的 Now Playing 表面，
而不是依赖 web 引擎的 MediaSession 桥。产品在所有平台调用同一组 API；
该能力是可选的，没有后端时降级为惰性 stub。

为什么宿主自有：WebKitGTK 的 MPRIS 桥在无头 CI 上从不 own 总线名，在真实
桌面也不可靠（WebKit bug 279362）；macOS 私有 MediaRemote 接口跨版本漂移。
宿主自有表面是确定性的、可经总线测试的，且只使用公共平台 API。

## API

```racket
(require glaze/now-playing) ; glaze/services 亦重导出

(now-playing-supported?)                 ; -> boolean?
(now-playing-set! (hash 'title "单集"
                        'artist "节目"
                        'album "订阅源"
                        'duration 1830.0
                        'position 42.0
                        'playing #t
                        'identifier "site.jrtx.podlens"
                        'artwork-url ""))
(now-playing-set-command-handler!        ; 系统传输命令
 (lambda (cmd arg)                       ; cmd: play pause stop toggle
   ...))                                 ;      next previous seek-by seek-to
(now-playing-clear!)                     ; 取消发布
(now-playing-info)                       ; 宿主状态（或 #f）
(now-playing-os-info)                    ; 回读 OS 表面（或 #f）
```

输入在 dispatcher 一次性归一：未知键丢弃、数字转 inexact、字符串给默认、
`playing` 转布尔。后端永远看不到未校验的产品输入。

`now-playing-os-info` 是验收证据而非控制路径：它回读真实 OS 表面
（macOS `MPNowPlayingInfoCenter.nowPlayingInfo`；Linux 对自有 MPRIS 名调
`org.freedesktop.DBus.Properties.Get`），让验证跑能证明发布成功，而不是
相信调用返回。

## 平台后端

| 平台 | 后端 | 表面 |
|---|---|---|
| macOS | `glaze/now-playing/now-playing-macos` | 公共 `MediaPlayer.framework`：`MPNowPlayingInfoCenter` 发布、`MPRemoteCommandCenter` 命令、`nowPlayingInfo` 回读 |
| Linux | `glaze/now-playing/now-playing-linux` | 会话总线上经 GIO/GDBus 宿主自有 MPRIS2：`org.mpris.MediaPlayer2.<净化 identifier>`、root + player 两接口、`PropertiesChanged`/`Seeked` 信号、真总线回读 |
| Windows | `glaze/now-playing/now-playing-stub` | 惰性：WebView2 的 web MediaSession → SMTC 桥仍是该平台已验证路径 |

缺库或缺会话总线时降级为 `now-playing-supported?` → `#f`；启动绝不因该
能力崩溃。Linux 命令分发跑在 GLib 主上下文；dispatcher 经
`now-playing-set-command-handler!` 安装 handler，后端把它们接到 MPRIS
方法（`Play`、`Pause`、`Stop`、`PlayPause`、`Next`、`Previous`、`Seek`、
`SetPosition`）。

## 验证

`glaze-test/now-playing-test.rkt` 在三平台 CI 全跑：契约与归一处处跑；
macOS 发布 + 回读；Linux 总线名所有权、属性回读与 `dbus-send` 命令往返；
Windows stub 惰性。产品验收矩阵应断言 OS 表面（`now-playing-os-info` 或
平台探针），而不是仅断言发布调用返回。

## 边界

- web MediaSession 桥保留：页内元数据与 Windows SMTC 仍走它；宿主发布在
  那些路径上是增量而非替换。
- 不使用、不链接任何 macOS 私有 API（MediaRemote）。
- 该能力不新增路由、不新增 token 表面、不做持久化。