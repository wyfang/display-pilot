# Display Pilot

一款 macOS 菜单栏应用，用一次点击切换整套多显示器配置。

[下载最新版本](https://github.com/wyfang/display-pilot/releases/latest) · [English](./README.en.md)

## 功能

- 保存两套可命名的显示器预设
- 为每块显示器记录开关、亮度、对比度、分辨率与旋转方向
- 从菜单栏或 `⌘1`、`⌘2` 快速切换
- 记住暂时离线的显示器，并在重新连接后恢复配置
- 禁止关闭最后一块活动屏幕，减少黑屏风险
- 可选开机自启动

## 使用

### 要求

- macOS 13 或更高版本
- 调整亮度与对比度时，需要运行并启用 [BetterDisplay](https://github.com/waydabber/BetterDisplay) 集成功能
- 从源码构建需要 Xcode Command Line Tools

### 源码构建

```bash
git clone https://github.com/wyfang/display-pilot.git
cd display-pilot
./build.sh
```

应用生成在 `dist/Display Pilot.app`，默认构建当前 CPU 架构，最低部署版本固定为 macOS 13。使用 `DISPLAYPILOT_ARCH=arm64` 或 `DISPLAYPILOT_ARCH=x86_64` 可指定架构。

运行 `./Tests/run.sh` 执行隔离回归测试；运行 `./scripts/generate-icon.sh` 重新生成应用图标。

应用使用本地临时签名且未经 Apple 公证，首次启动可能需要右键选择“打开”。

## 说明

### 工作方式

Display Pilot 先连接预设需要的屏幕，恢复指定的旋转和分辨率，再关闭不需要的屏幕。等待连接变化稳定并重新恢复显示模式后，最后应用亮度与对比度。显示器优先使用系统 UUID 识别，切换前重新核验当前设备；结束后再次核对连接状态、指定的显示模式，以及 BetterDisplay 返回的亮度与对比度。

亮度为 0 的显示器只应用连接、亮度和对比度，始终跳过分辨率与旋转，旧预设中已勾选“应用分辨率与旋转”也不例外，避免旋转权限或模式变化阻止息屏。原开关、分辨率与旋转设置仍保留，调高亮度后可继续按该开关严格执行，也可单独选择分辨率“保持当前”或旋转“跟随当前”。

### 限制

- 显示器开关使用 macOS 私有接口 `CGSConfigureDisplayEnabled`，不适合发布到 Mac App Store，也可能受系统更新影响
- 修改旋转方向需要 BetterDisplay Pro 及显示器支持；同时选择旋转“跟随当前”和分辨率“保持当前”，以及亮度为 0 的息屏操作，不调用旋转接口
- BetterDisplay 未运行、集成被关闭或读回结果不符时，会提示未完成，而不会把预设标记为成功
- 软件无法重新连接物理断开的显示器；无法确认身份的设备不会执行开关操作
- 升级保留旧预设数据；无法唯一确认的旧设备条目需要重新配置。旧预设未记录旋转且与当前方向不同时，需明确选择 90° 或 270°，应用不会猜测方向
- 线材、扩展坞、镜像、HDR 或系统变化可能使已保存模式失效

## 版权说明

原创代码依据 [Apache License 2.0](./LICENSE) 发布。个人品牌和素材不在许可范围内。详见 [许可范围](./LICENSE_SCOPE.md)。
