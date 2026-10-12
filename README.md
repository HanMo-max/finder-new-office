# FinderNewOffice

在 macOS 访达（Finder）窗口的右键菜单中添加「新建」，通过二级菜单快速创建空白 Word 文档、Excel 表格和 PPT 文档。

A lightweight macOS Finder Sync extension that creates blank Word, Excel, and PowerPoint files from Finder’s context menu. Written in Objective-C, with no third-party runtime dependencies.

> 当前实现的入口是**访达窗口**，不是桌面壁纸的右键菜单。要在桌面目录创建文件，请在访达中打开「桌面」，然后右键窗口空白处。

## 功能与菜单

```text
访达窗口空白处右键
└── 新建
    ├── 新建 Word 文档   → 新建 Word 文档.docx
    ├── 新建 Excel 表格  → 新建 Excel 表格.xlsx
    └── 新建 PPT 文档    → 新建 PPT 演示文稿.pptx
```

- 点击后直接在目标文件夹生成文件，不启动 Office、WPS 或额外的访达窗口。
- 同名文件存在时添加序号，例如 `新建 Word 文档 2.docx`。写入时也拒绝覆盖已有文件；如果发生并发重名，会报告失败。
- `.docx` 包含一段空正文；`.xlsx` 包含一个名为 `Sheet1` 的空工作表；`.pptx` 包含一页空白的 16:9 幻灯片，以及版式、母版和主题。
- 宿主应用没有窗口或 Dock 图标，主要用于承载 Finder Sync 扩展。
- 这三个入口是**鼠标菜单操作**，没有绑定键盘快捷键。

## 支持范围

- macOS 14.0 及以上；构建脚本按当前 Mac 的 CPU 架构编译。
- 本地源码构建，使用 ad-hoc 签名。无需 Xcode 工程或付费 Apple 开发者账号。
- 必须先安装 Apple Command Line Tools：`xcode-select --install`。
- 菜单是否出现、扩展能否启用以及目标文件夹是否允许写入，受 macOS 和 Finder 的权限控制。
- 构建时为当前用户的 `$HOME/Desktop/` 生成桌面写入权限。源码中不包含任何固定用户名或个人绝对路径。其他目录依赖系统授予扩展的文件访问权限；不能保证在所有目录中写入。

## 构建、检查与安装

```bash
git clone https://github.com/HanMo-max/finder-new-office.git
cd finder-new-office

bash scripts/build.sh
bash scripts/verify.sh
bash scripts/install.sh
```

三个脚本的职责分别是：

| 脚本 | 行为 |
| --- | --- |
| `build.sh` | 清理项目的 `build/`，编译宿主和扩展，生成当前用户的桌面权限，执行 ad-hoc 签名并检查签名 |
| `verify.sh` | 在临时目录生成三种文档，检查 ZIP、XML、OOXML 内部关系和类型识别，并检查已有文件保护；退出时清理临时目录 |
| `install.sh` | 安装到 `~/Applications/FinderNewOffice.app`，注册并启用扩展，然后重新启动 Finder |

安装脚本只替换 bundle identifier 为 `local.xiaohan.FinderNewOffice` 的同名应用；遇到不同标识符的应用会停止。安装会重新启动 Finder，运行前请完成正在进行的文件操作。

如果菜单没有出现，到「系统设置 → 通用 → 登录项与扩展」中的 Finder 扩展设置启用「新建」。不同 macOS 版本的设置位置可能不同。然后重新打开访达窗口，在文件夹空白处右键，查看菜单下方。

签名中的桌面路径与构建用户相关，因此其他用户应在自己的 Mac 上重新构建。项目当前没有提供经过 Apple 公证的安装包。

## 代码结构与调用链

```text
src/
├── app/
│   ├── main.m                     无界面宿主应用入口
│   ├── Info.plist                 宿主名称、标识符和最低系统版本
│   └── FinderNewOffice.entitlements  宿主沙箱权限
├── extension/
│   ├── NewDocSync.m               右键菜单、文件名、OOXML 和 ZIP 写入
│   ├── Info.plist                 Finder Sync 扩展声明
│   └── FinderNewOffice.entitlements  扩展的通用沙箱权限
└── probe/
    └── main.m                     直接调用文档写入器的验证入口
scripts/
├── build.sh
├── install.sh
├── verify.sh
└── verify_package.py              ZIP/XML/内部关系检查，Python 标准库
```

宿主入口 `src/app/main.m` 启动一个 accessory 类型的 `NSApplication`。扩展由 macOS 通过 `com.apple.FinderSync` 加载，主类为 `NewDocSync`。

```text
Finder 请求右键菜单
    → menuForMenuKind:
    → 新建 → createWord: / createExcel: / createPPT:
    → createKind:base:
    → targetedURL 获取目标目录
    → uniqueName 选择可用文件名
    → writeDocx: / writeXlsx: / writePptx:
    → zipEntries:toURL:error:
    → 当前目录中的 .docx / .xlsx / .pptx 文件
```

扩展监控的目录集合为 `/`，菜单回调处理窗口容器和侧边栏类型的上下文菜单，不处理选中文件类型的菜单。目标目录不可用时报告失败，不回退到其他目录。

文档不是重命名的空文件，而是由 XML 部件及其关系组成的 Office Open XML 包。`zipEntries:` 在内存中生成存储模式（不压缩）的 ZIP，包含本地文件头、中央目录、结束记录和 CRC32；不调用外部 `zip`、`ditto` 或办公软件。包内的文件名均为 ASCII，文件内容为 UTF-8 XML。

构建时生成的 `build/FinderNewOffice-extension.entitlements` 含当前用户桌面路径，仅用于本地签名，不进入 Git。安装时复用该权限文件。

相关 Apple 文档：[Finder Sync 扩展](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)、[targetedURL](https://developer.apple.com/documentation/findersync/fifindersynccontroller/targetedurl%28%29?language=objc)、[拒绝覆盖已有文件的写入选项](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/withoutoverwriting?language=objc)。

## 验证的边界

`verify.sh` 验证写入器、ZIP CRC、XML 可解析性、必需部件、内容类型、内部关系目标以及重名保护。`textutil` 的类型识别只是基础检查，不能证明所有办公软件都能打开文件。

上述检查不启动真实 Finder 扩展，也不验证菜单显示、沙箱写入权限或 Office/WPS 的实际打开效果。完整使用验证还需要安装后，在访达中点击三个菜单，并用实际办公软件打开生成的文件。未声明跨设备或所有 Office/WPS 版本均已验证。

## 已知限制

- 当前实现不支持桌面壁纸右键菜单；通过访达打开「桌面」目录使用。
- 不控制菜单插入位置，无法承诺放在「新建文件夹」正下方。
- 文件访问权限可能导致某些目录创建失败；系统隐私设置也可能影响桌面访问。
- Finder Sync 扩展之间可能互相影响菜单显示，菜单显示与目录写入属于不同问题。
- 使用最小 OOXML 部件，完整格式规范验证及办公软件兼容性测试仍有待补充。
- 失败提示使用 macOS 的旧通知接口；通知是否显示受系统设置影响。
- 从旧版 NewDocHere 迁移时，新版使用新的应用与扩展标识符，不会卸载或关闭旧版。若两者同时启用，可能出现重复菜单，请手动关闭旧版扩展。

## 卸载

先在系统设置中停用「新建」Finder 扩展，再将 `~/Applications/FinderNewOffice.app` 移到废纸篓并重新打开 Finder。已经创建的文档不会被删除。
