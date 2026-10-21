# Harbor 液态玻璃

2026-09-08 · 0.15.0

## 参考与原生实现

用户指定的 [rdev/liquid-glass-react](https://github.com/rdev/liquid-glass-react) 使用独立背景折射、边缘高光、磨砂和饱和度，并通过鼠标方向形成弹性位移和形变。已阅读 README、src/index.tsx 与 MIT 许可。Harbor 借鉴这些视觉和交互原则，独立编写 SwiftUI 实现，没有复制其 React、SVG 或 WebGL 源码。

- [源代码](https://github.com/rdev/liquid-glass-react/blob/master/src/index.tsx)
- [上游 MIT 许可](https://github.com/rdev/liquid-glass-react/blob/master/LICENSE)，MAX ROVENSKY，2025
- [Apple：Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Apple：GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)

macOS 26 采用公开 SwiftUI glassEffect / GlassEffectContainer，折射、背板采样和合成交给系统。顶部邻近控件集中合成；效果直接包裹控件内容，避免独立玻璃背景在集群中覆盖按钮文字。macOS 14/15 回退为 regularMaterial、主题色染色与边缘高光。没有加入 React 运行时、装饰专用 WebView、离屏截图循环或自定义 GPU 纹理。

## 使用位置

顶部模式按钮、新建终端、目录切换和加号、选项菜单、设置按钮；当前导航/服务器/本机、文件与终端标签、右侧终端选中行；悬浮名称提示、拖动预览与目的地卡片。原生菜单继续由系统绘制。

大面积终端、代码、Markdown、视频与文件目录背景保留 VS Code Dark 2026 / Light 2026 配色。工作区边界、命中区域、键盘焦点与选中标记保留。悬浮提示仍是不激活且鼠标可穿透的 NSPanel，拖放提示也不接收点击。

按钮在悬停范围内按鼠标方向拉伸，最大约 5%，位移不超过 1.5 pt；按下略收缩，离开回到原尺寸。边缘高光跟随指针，冷蓝染色呼应主题。动画只由悬停、按下或离开触发，静止时没有新增长期运行的定时器。保留已有各图标的语义动画。

## 设置与可访问性

“设置 → 液态玻璃”默认开启、立即生效。关闭效果、系统降低透明度或提高对比度时显示实色；减少动态效果时取消玻璃按钮的位移、形变和提示淡入。减少动态效果仍保留静态高光反馈。修改设置只影响装饰层，不重建 SSH/PTY 或编辑器。

## 验证范围

本次验证记录见 ../VALIDATION.md；前一版拖放底层与在线检查见 VALIDATION-v0.14.0.md。macOS 26 的原生材质已在当前 Mac 构建和检查，14/15 的降级分支保留兼容编译，未在旧系统设备上实测。背景静止时的内存/CPU 采样不能代表持续拖拽或窗口合成的全部 GPU 成本。
