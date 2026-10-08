# 产品事实与设计假设

- 事实来源为当前私有仓库，不将Prosio当作需要公开检索的上市产品。
- project.yml：macOS原生Swift应用，LSUIElement=true，当前App Sandbox=false。
- Apps/macOS/Prosio/UI/Editor/CapturePinnedWindow.swift：已有 .floating + canJoinAllSpaces/fullScreenAuxiliary 实现，可参考窗口行为；这不是便签已完成实现的证明。
- Apps/macOS/Prosio/UI/MenuBar/MenuBarShell.swift：已有系统字体、中性材质与waveform身份标志；当前五个功能标签，便签入口建议增加在共用底部。
- 现有真实菜单预览复制到 assets/existing-menu-light.png，视觉依据见brand-spec.md。
- 用户已确认AppKit/WKWebView/Milkdown/本地.md技术方案。Milkdown的基础事实与MIT许可已在上一轮通过官方 https://github.com/Milkdown/milkdown 与 https://milkdown.dev/docs/guide/why-milkdown 核实。
- 本轮尺寸、快捷键、单活动文件、保存间隔、收起能力均是待审核设计建议，不能当作已批准规格。
- HTML演示只模拟界面和状态，不访问原生系统、不写用户文件、不宣称完整Markdown编辑器已实现。
