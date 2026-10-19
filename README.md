# soft-updater

通用化的 GitHub 发布版自动更新器，Windows/x64，PowerShell 5.1 可直接运行。
把 `C:\soft\omp\update-omp.ps1` 里的下载/校验/替换逻辑抽成引擎，软件清单改为配置驱动。

## 文件

| 文件 | 作用 |
| --- | --- |
| `update-all.ps1` | 引擎：读清单 → 查最新版 → 比版本 → 走镜像下载 → 校验 SHA-256 → 备份并替换 → 冒烟测试 |
| `apps.json` | 登记表：仓库、资产名、安装目录、版本探测方式、镜像列表、`self` 自备份清单 |
| `state.json` | 每个软件的 `installed` / `latest` / `checkedAt` / `updatedAt` / `lastError` / `lastMirror` |
| `update.log` | 运行日志，超过 2 MB 自动轮转为 `update.log.1` |
| `backup/<id>/<时间戳>/` | 被覆盖文件的备份，每个软件保留最近 2 份 |
| `backup/self/<时间戳>/` | 脚本与文档自身的快照，保留最近 5 份 |
| `register-task.ps1` | 注册/删除每日计划任务 |

## 用法

```powershell
# 立即更新全部
powershell -ExecutionPolicy Bypass -File C:\soft\soft-updater\update-all.ps1

# 只检查（0=已最新，1=有更新，2=出错）
... update-all.ps1 -Check

# 定时模式：当天已检查过的软件跳过
... update-all.ps1 -Auto

# 只看清单和已记录状态，不联网
... update-all.ps1 -List

# 只处理指定软件（逗号分隔）
... update-all.ps1 -App chsrc,noctty

# 强制重装/修复当前版本
... update-all.ps1 -App Notepad3 -Reinstall

# 强制重新测速选镜像
... update-all.ps1 -Benchmark
```

## 登记新软件

在 `apps.json` 的 `apps` 里加一项。三种安装模式：

**`file`** — 资产本身就是要装的文件：

```json
{
  "id": "chsrc",
  "repo": "RubyMetric/chsrc",
  "asset": "chsrc-x64-windows.exe",
  "mode": "file",
  "installDir": "C:\\soft\\chsrc",
  "target": "chsrc.exe",
  "version": { "exe": "chsrc.exe", "args": ["--version"], "regex": "v(\\d+(?:\\.\\d+)*)" }
}
```

**`zip`** — 解包后按条目覆盖到目录：

```json
{
  "id": "noctty",
  "repo": "amanthanvi/noctty",
  "assetPattern": "^noctty-[0-9.]+-windows-x64-portable\\.zip$",
  "mode": "zip",
  "stripTopLevel": true,
  "installDir": "C:\\soft\\noctty",
  "version": { "exe": "noctty.exe", "args": ["--version"], "regex": "noctty\\s+(\\d+(?:\\.\\d+)*)" }
}
```

**`sfx`** — 资产是自解压程序（PortableGit 的 7z SFX），直接运行它：

```json
{
  "id": "git",
  "repo": "git-for-windows/git",
  "assetPattern": "^PortableGit-[0-9.]+-64-bit\\.7z\\.exe$",
  "mode": "sfx",
  "installDir": "C:\\soft\\git",
  "sfxArgs": ["-y", "-o{installDir}"],
  "requireNotRunning": ["git", "git-bash", "git-cmd", "bash", "sh"],
  "tagRegex": "v(\\d+\\.\\d+\\.\\d+)\\.windows\\.(\\d+)",
  "version": { "exe": "cmd\\git.exe", "args": ["--version"], "regex": "(\\d+\\.\\d+\\.\\d+)(?:\\.windows\\.(\\d+))?" }
}
```

字段说明：

| 字段 | 说明 |
| --- | --- |
| `asset` | 精确资产名；版本号会变时改用 `assetPattern` 正则 |
| `mode` | `file` / `zip` / `sfx` |
| `target` | `file` 模式的目标文件名（相对 `installDir`） |
| `include` / `exclude` | `zip` 模式按通配符挑选/排除条目 |
| `stripTopLevel` | `zip` 里所有条目都在一个顶层目录时剥掉该层（pandoc、bun、noctty、pi-bolt 需要） |
| `extract` | 精细映射：`[{"from":"dist/x.exe","to":"bin/x.exe"}]`，优先于 `include` |
| `sfxArgs` | `sfx` 模式传给自解压程序的参数，`{installDir}` 会被替换（默认 `-y -o<installDir>`） |
| `requireNotRunning` | 这些进程（可执行文件位于 `installDir` 下）在跑就跳过本次更新，下次再试；用于 `sfx` 这类多文件安装，以及自带 exe 无法改名的便携版（Netcatty） |
| `tagRegex` | tag 不是纯版本号时（`v2.56.0.windows.2`）提取要比较的部分；多个捕获组用 `.` 连接 |
| `version.exe/args/regex` | 运行 `installDir\exe args`，用 `regex` 取版本号；探测走重定向句柄，GUI 子系统程序（noctty）也能读到 stdout |
| `version.file` | 不跑进程，直接读 exe/dll 的 ProductVersion（Notepad3、Netcatty 用这个） |

## 更新逻辑

1. **版本对比**：按点分段数值比较，缺位补 0（`1.4` == `1.4.0`），`installed >= latest` 时不动文件。
2. **API 查询**：直连 `api.github.com`，失败后依次用镜像改写地址（gh-proxy 类镜像同时代理 API）。可用环境变量 `GITHUB_TOKEN` 提高限额。
3. **镜像下载**：先复用该软件上次成功的镜像（记录在 `state.json`）；失败则对全部镜像各测 5 秒真实字节，按吞吐排名，≥1 MB/s 即停止扫描，再按排名逐个尝试。下载中 curl 的 `--speed-limit/--speed-time` 会掐掉卡死的镜像，慢但仍在动的镜像保留（阈值取实测速度的一半）。
4. **校验**：必须拿到 release 的 `digest`（`sha256:...`），否则拒绝安装；下载后比对 SHA-256，不符即删除重来。
5. **安装**：解包到临时目录，逐个文件比对 SHA-256，**内容相同就跳过**（只写真正变化的文件），变化的文件先复制到 `backup/<id>/<时间戳>/` 再原地覆盖；单个文件被占用（正在运行的 exe）时只对那一个文件改名让位，替换后立即删除让位副本（noctty 实测：522 个条目只写 20 个）。`sfx` 模式没有逐文件备份；`requireNotRunning` 命中（进程的可执行文件就在 `installDir` 下）时本次记 `skipped (running)`，不杀进程，下次运行再试——Netcatty 的便携 exe 连改名都不允许，只能等它关闭。
6. **冒烟测试**：重新读版本，与 release 版本不一致就报错并保留备份。
7. **自备份**：每次运行（`-List` 除外）先把 `self.files` 里的脚本和文档快照到 `backup/self/<时间戳>/`，与上一份逐文件比哈希，完全相同就不新建快照。

## 每日自动更新

```powershell
powershell -ExecutionPolicy Bypass -File C:\soft\soft-updater\register-task.ps1            # 每天 02:00
powershell -ExecutionPolicy Bypass -File C:\soft\soft-updater\register-task.ps1 -Time 12:00
powershell -ExecutionPolicy Bypass -File C:\soft\soft-updater\register-task.ps1 -Unregister
```

任务以当前用户、`LIMITED` 权限、隐藏窗口运行 `update-all.ps1 -Auto -Notify`；`-Auto` 用 `state.json` 里的 `checkedAt` 做每日节流，`-Notify` 只在有更新或失败时弹气泡。

02:00 关机或睡眠时当天这次会被跳过（`StartWhenAvailable`/`WakeToRun` 默认关闭，schtasks 没有对应开关）。要补跑或唤醒执行：

```powershell
$t = Get-ScheduledTask -TaskName soft-updater
$t.Settings.StartWhenAvailable = $true   # 错过后开机补跑
$t.Settings.WakeToRun = $true            # 睡眠时唤醒
Set-ScheduledTask -InputObject $t
```

## 安全软件

首次运行 `update-all.ps1` 时，火绒把它判为 `ADV:Ransom/Genalocker.A` 并隔离（安装器批量改写目录 + 批量改名触发了勒索启发式）。现在的实现已改为「只覆盖变化的文件、单文件改名兜底、让位副本立即删除」，实测不再触发。**`C:\soft\soft-updater` 已加入火绒信任区**；被隔离的旧脚本可从火绒隔离区恢复并加白。

## 当前登记

| id | 仓库 | 模式 | 安装目录 |
| --- | --- | --- | --- |
| omp | can1357/oh-my-pi | file | `C:\soft\omp` |
| chsrc | RubyMetric/chsrc | file | `C:\soft\chsrc` |
| pixi | prefix-dev/pixi | file | `C:\soft\pixi` |
| bun | oven-sh/bun | zip | `C:\soft\bun` |
| pandoc | jgm/pandoc | zip | `C:\soft\pandoc` |
| noctty | amanthanvi/noctty | zip | `C:\soft\noctty` |
| netcatty | binaricat/Netcatty | file | `C:\soft\netcatty` |
| pi-bolt | opensec-git/Pi-Bolt | zip | `C:\soft\pi-bolt` |
| git | git-for-windows/git | sfx | `C:\soft\git` |
| Notepad3 | rizonesoft/Notepad3 | zip | `C:\soft\Notepad3` |
| self | （本地脚本与文档） | snapshot | `backup\self` |

telepresence 已移出清单（`C:\soft\telepresence` 本体保留，不再自动更新）。
VS Code、Everything、FlClash 等用各自内置更新器更稳，没放进清单。

## 自备份范围

`self.files` 当前包含：`update-all.ps1`、`register-task.ps1`、`apps.json`、`README.md`，以及被本工具取代的旧脚本 `C:\soft\omp\update-omp.ps1`、`C:\soft\omp\omp-update-修改说明.md`、`C:\soft\netcatty\update-netcatty.ps1`。旧脚本仍在原处可用，只是不再由计划任务调用。

### 如果需要备份自己的话
```json
{
  "self": {
    "keep": 5,
    "files": [
      "update-all.ps1",
      "register-task.ps1",
      "apps.json",
      "README.md"
    ]
  }
}
```