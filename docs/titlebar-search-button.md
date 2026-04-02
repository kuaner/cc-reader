# 标题栏搜索按钮居中方案

## 问题

搜索按钮之前使用 SwiftUI `.toolbar(placement: .principal)` 放置，但在 `NavigationSplitView` 中 `.principal` 只基于 **detail 列**居中，而不是整个窗口。当 sidebar 展开/收起时，按钮位置会偏移。

## 方案

放弃 `.toolbar(.principal)`，改用 `.overlay(alignment: .top)` 覆盖在整个 `NavigationSplitView` 上：

```swift
NavigationSplitView { ... }
.overlay(alignment: .top) {
    Button { ... }
        .frame(maxWidth: .infinity)   // 占满窗口宽度 → 按钮居中于窗口
        .frame(height: 28)            // 匹配 unified 标题栏中的可用区域
        .padding(.top, 6)             // 留出上边距
        .ignoresSafeArea(.all, edges: .top)  // 进入标题栏区域
}
```

### 关键点

1. **`frame(maxWidth: .infinity)`** — 让按钮的容器宽度等于整个窗口宽度，实现真正的窗口居中
2. **`.ignoresSafeArea(.all, edges: .top)`** — `fullSizeContentView` 下 safe area 会把内容推到标题栏下方，必须忽略才能让 overlay 进入标题栏
3. **`.padding(.top, 6)`** — 微调垂直位置，与红绿灯按钮视觉对齐

### 前提条件

- `WindowConfigView` 中设置了 `window.styleMask.insert(.fullSizeContentView)`
- `CCReaderApp` 中设置了 `.windowToolbarStyle(.unified(showsTitle: false))`

### 尝试过但放弃的方案

| 方案 | 问题 |
|------|------|
| `.toolbar(placement: .principal)` | 只基于 detail 列居中，不是窗口 |
| AppKit `NSHostingView` 添加到 `themeFrame` | 定位可能错位，和 SwiftUI 生命周期管理复杂 |
