# 文档

[English](README.md) · **简体中文**

安装与功能概览见[中文 README](../README.zh-CN.md)或[英文 README](../README.md)。部分详细指南目前仅提供英文。

## 功能指南

| 主题 | 指南 |
| --- | --- |
| 操作、工作流与自动规则 | [操作与自动化](actions-automation.md) |
| 页面跳转与外部运行链接 | [URL API](url-scheme.md) |
| 命令行安装 | [Nightly CLI](testing/cli-nightly-distribution.md#install-from-settings) |
| 本地 AI Agent 集成 | [CLI 使用指南](cli/agent-usage.md) |
| 截图、文字识别、滚动截图与录屏 | [截图](plugins/screenshot.md) |
| 剪贴板备份与恢复 | [加密备份](plugins/clipboard-backup.md) |
| 审阅后移除应用 | [应用卸载](plugins/app-uninstaller.md) |
| 窗口导航与排列 | [窗口切换](plugins/window-switcher.md) · [窗口布局](plugins/window-layouts.md) |
| 键盘、鼠标与手势映射 | [输入映射](plugins/input-remapping.md) |
| 系统设置与配置方案 | [Mac 设置](plugins/mac-settings.md) |
| 菜单栏自定义 | [隐藏菜单栏图标](plugins/menu-bar-hidden.md) · [自定义图标](plugins/menu-bar-icons.md) |
| 音频控制 | [应用音量](plugins/app-volume.md) · [显示器音量](plugins/display-volume.md) |
| 监控 | [设备电量](plugins/device-battery.md) · [Duo 状态](plugins/duo-status.md) · [AI 用量](plugins/ai-usage.md) |
| Siri | [使用与限制](plugins/siri.md) |

## 开发

- [贡献指南](../CONTRIBUTING.zh-CN.md) / [English](../CONTRIBUTING.md)：环境、构建、测试与贡献流程。
- [插件开发规范](plugins/development-guidelines.md)：协议、widget、设计一致性、性能与验收要求。
- [本地原生插件](plugins/local-native-plugins.md)：开发与调试插件。
- [面板组件](plugins/panel-items.md)：声明自定义面板中的组件与控件。
- [插件目录](plugins/plugin-catalog.md)：插件发现与分发。
- [界面更新与后台任务](plugins/presentation-performance.md)：可见性、状态订阅与刷新周期。
- [全局面板](plugins/global-panel-presentation.md)与[浮动面板外观](plugins/palette-appearance.md)：焦点、关闭行为与共用样式。
- [面板布局验证](testing/panel-layout-editing.md)与[操作和自动化验证](testing/actions-automation-e2e.md)：相关原生交互检查。

## 发布

- [构建与发布流程](github-actions.md)：CI、签名、分发与渠道隔离。
- [CLI 托管安装](plugins/managed-cli-distribution.md)与[CLI 发布要求](plugins/cli-release.md)：安装归属、恢复与签名验证。

详细设计见[规格文档](superpowers/specs/)与[实施计划](superpowers/plans/)。它们保留设计过程，当前行为应以功能指南为准。
