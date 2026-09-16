# MacTools Icon Gallery

状态栏图标图库使用轻量 catalog + 按需下载素材。主应用只读取 `catalog.json`，用户选择某个素材后才下载对应帧，并从本地 `RemoteAssets` 播放。

## Catalog v1

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-05-20T00:00:00Z",
  "baseURL": "https://mactools.ggbond.app/icon-gallery/",
  "categories": [
    { "id": "featured", "title": "精选" }
  ],
  "assets": [
    {
      "id": "runcat",
      "title": "RunCat",
      "categoryID": "featured",
      "version": "1",
      "renderingMode": "template",
      "previewPath": "assets/runcat/preview.png",
      "archivePath": "assets/runcat/asset.zip",
      "archiveFramePathPattern": "frame-%03d.png",
      "frameCount": 5,
      "frameDuration": 0.1
    }
  ]
}
```

`archivePath` 推荐用于线上资源，减少多帧动画的请求次数。压缩包内只需要放帧文件，路径用 `archiveFramePathPattern` 描述。

`renderingMode` 必须显式声明：

- `template`：用于黑色图形 + 透明背景的单色素材。AppKit 根据菜单栏背景和按钮状态自动着色，所有动画帧都必须满足同一模板要求。
- `original`：用于彩色、灰度渐变或需要保留原始颜色的素材。

不要为模板素材批量生成白色副本，也不要在运行时逐像素反色。新增或更新 `template` 素材时，应检查全部帧，而不只是预览图；测试会拒绝包含彩色像素或不透明背景的模板帧。旧 catalog 未声明该字段时，客户端为兼容性按 `original` 处理。

静态素材使用 `frameCount: 1` 和单个 `framePaths` 文件；动画素材使用 `frameCount > 1`。图库卡片会根据这个字段自动在动画右下角显示“动态”标签，静态素材不显示标签。

已提交的第三方静态 SVG、固定上游 revision、许可证和 catalog ID 映射记录在 `docs/icon-gallery/sources/manifest.json`。生成后的 PNG 使用透明画布和黑色模板图形，不应直接修改而丢失上游来源。

First-party artwork recovered from repository history is not a third-party source and stays out of `sources/manifest.json`; record its origin here instead. `mactools v1` (`static-mactools-legacy-t`) reproduces the original MacTools menu-bar mark from commit `ce39bc66`, rasterized from that commit's app-icon artwork as black template artwork on a transparent 96×96 canvas.

也可以不用 zip，直接声明帧路径：

```json
{
  "id": "runcat",
  "title": "RunCat",
  "categoryID": "featured",
  "version": "1",
  "previewPath": "assets/runcat/preview.png",
  "framePathPattern": "assets/runcat/frames/frame-%03d.png",
  "frameCount": 5,
  "frameDuration": 0.1
}
```

## Runtime Behavior

- 正式环境默认读取 `https://mactools.ggbond.app/icon-gallery/catalog.json`。
- Debug 环境可用 `MACTOOLS_ICON_CATALOG_URL` 指定 `file://` 或 `https://` catalog。
- `make run` 会自动生成 `build/LocalIconGallery/catalog.dev.json` 并注入 `MACTOOLS_ICON_CATALOG_URL`。
- 远程素材下载到 `~/Library/Application Support/MacTools/MenuBarIcons/RemoteAssets/`，Debug 为 `MacTools Dev`。
- 当前选中的在线素材直接从 `RemoteAssets` 读帧，渲染后进入内存缓存；动画播放时不会访问网络。
- `template` 素材在进入内存缓存后只设置一次 `NSImage.isTemplate`，由 AppKit 在状态栏绘制时适配颜色，不执行逐帧像素转换。
- 选择新的在线素材后，会清理旧的 `RemoteAssets`，只保留当前选中素材。

## Local Debug Gallery

本地 Debug 会复制仓库内已提交的 `docs/icon-gallery`，并把 catalog 的 `baseURL` 改成本地 `file://` 地址：

```bash
make generate-icon-gallery
```

如果需要重写到其它静态目录：

```bash
./scripts/icons/generate-local-icon-gallery.py \
  --gallery-dir docs/icon-gallery \
  --output-dir build/LocalIconGallery
```

当前首批静态素材来自 Apache-2.0 的 `Kyome22/menubar_runcat` 和 MIT 的 `tabler/tabler-icons`。选择新来源时优先使用流行、持续维护、许可证允许再分发且具有统一 SVG 规格的项目；不要从来源不明确的动画或商业素材中抽取静态帧。

## Safety Limits

- 正式环境只允许 `https` 资源，Debug 的 `file://` 资源仅用于本地测试。
- 单帧最大 1 MB，zip 最大 25 MB。
- 单个素材最多 120 帧。
- 解码后单帧像素面积不超过 `512 * 512`。
- 素材完整下载、解压、校验成功后才切换当前图标。
