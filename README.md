# Display Pilot

一款 macOS 菜单栏应用，用一次点击切换整套多显示器配置。

[下载最新版本](https://github.com/wyfang/display-pilot/releases/latest) · [English](./README.en.md)

## 功能

- 保存两套可命名的显示器预设
- 为每块显示器记录开关、亮度、对比度与分辨率
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

Display Pilot 先连接预设需要的屏幕，等待显示模式稳定，再以单次 Core Graphics 事务切换分辨率，随后应用亮度与对比度，最后关闭不需要的屏幕。显示器优先使用系统 UUID 识别，切换前重新核验当前设备，避免使用失效的系统编号。应用结束后会再次核对屏幕开关、分辨率，以及 BetterDisplay 返回的亮度与对比度。

### 限制

- 显示器开关使用 macOS 私有接口 `CGSConfigureDisplayEnabled`，不适合发布到 Mac App Store，也可能受系统更新影响
- BetterDisplay 未运行、集成被关闭或读回结果不符时，会提示未完成，而不会把预设标记为成功
- 软件无法重新连接物理断开的显示器；无法确认身份的设备不会执行开关操作
- 升级保留旧预设数据；无法唯一确认的旧设备条目需要在编辑预设中重新配置
- 线材、扩展坞、镜像、HDR 或系统变化可能使已保存模式失效

## 版权说明

原创代码依据 [Apache License 2.0](./LICENSE) 发布。个人品牌和素材不在许可范围内。详见 [许可范围](./LICENSE_SCOPE.md)。
