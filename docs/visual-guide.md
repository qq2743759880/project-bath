# README Hero 重建

这份图像用于README，尺寸1280×640。项目的使用只需要加载Skill；以下Node工具仅用于编辑图像，不是Skill运行依赖。

在仓库根目录执行：

```sh
npm --prefix assets/visual-source ci --ignore-scripts
npm --prefix assets/visual-source run check
npm --prefix assets/visual-source run render
npm --prefix assets/visual-source run guides
```

锁定renderer为 `@snap-x/cli` 0.2.1，重建helper声明Node.js >=22.15（Windows导入hook要求）；本次验证使用Node24.18。CLI及其core依赖版本均来自同一锁文件。产物写到 `assets/hero.png`。格式没有placement zones，guides的nothing-to-check是正常结果。

- [Hero](../assets/hero.png)
- [设计源](../assets/visual-source/designs/hero.mjs)、[品牌helper](../assets/visual-source/designs/_brand.mjs)
- [计划](../assets/visual-source/snap-plan.md)、[用途说明](../assets/visual-source/share-copy.txt)
- [工具声明](../assets/visual-source/package.json)、[锁文件](../assets/visual-source/package-lock.json)、[执行wrapper](../assets/visual-source/snap.mjs)、[Windows导入兼容shim](../assets/visual-source/windows-esm.mjs)、[辅助代码MIT许可](../assets/visual-source/LICENSE)

无原logo；使用text wordmark。颜色/Inter字体为这次发布提案。没有模拟UI、客户logo、性能指标。字体初次下载需要网络，重建工具沿用锁定版本与font cache。
