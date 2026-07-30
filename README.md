# 迪莫桌宠

<img src="macOS/Resources/dimo-watercolor.png" alt="迪莫头像" width="180" align="right">

一只安静待在 macOS 桌面角落的迪莫。点击迪莫会展开 Todo 清单，再点击其他地方就会自动收起。

当前版本：**1.0**

<br clear="right">

## 功能

- 可拖动的透明桌宠窗口
- 近期任务按日期排序，今日任务优先
- 任务可选日期以及上午、下午、晚上
- 圆圈点击完成或取消完成
- 新增任务区默认折叠
- 列表支持滚动但不显示滚动条
- 本地保存任务和桌宠位置

## 下载与安装

Apple Silicon Mac（M1/M2/M3/M4 等）下载：

[`dist/迪莫桌宠-1.0-macOS-arm64.zip`](dist/%E8%BF%AA%E8%8E%AB%E6%A1%8C%E5%AE%A0-1.0-macOS-arm64.zip)

解压后把“迪莫桌宠.app”拖进“应用程序”文件夹即可。本项目当前不提供 Intel 版本。

应用使用临时签名。如果 macOS 首次启动时阻止打开，可在 Finder 中右键应用并选择“打开”。

## 数据保存

任务数据通过 Bundle ID `com.codex.dimopet` 保存在当前 macOS 用户的偏好设置中。只要后续版本继续使用同一个 Bundle ID，直接覆盖安装后数据仍会保留。删除应用本身不会主动删除 Todo 数据。

## 从源码构建

需要 macOS 13 或更高版本，以及 Xcode Command Line Tools：

```bash
./scripts/build-macos.sh
```

构建结果位于 `build/迪莫桌宠.app`，压缩安装包位于 `dist/`。

## 项目结构

- `macOS/Sources/main.swift`：SwiftUI 与 AppKit 源码
- `macOS/Resources/`：迪莫图片和应用图标
- `macOS/Info.plist`：应用信息与正式版本号
- `VERSION`：仓库版本号
- `CHANGELOG.md`：版本更新记录
