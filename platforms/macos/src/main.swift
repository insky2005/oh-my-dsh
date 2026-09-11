//
//  oh-my-dsh — Native macOS Shell for DeepSeek Harness
//
//  A pure wrapper around the `dsh web` browser UI. It does NOT modify any
//  DeepSeek Harness source code: it locates the installed `dsh` CLI, starts
//  the web server when needed, and renders the UI inside a native WKWebView
//  window. If a `dsh web` server is already running on the default port it is
//  reused instead of spawning a second one.
//
//  Build: see build-app.sh in the repository root.
//

import AppKit
import WebKit
import Foundation

// MARK: - Logging

final class AppLog {
    static let shared = AppLog()
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "dsh.app.log")

    private init() {
        let dir = NSHomeDirectory() + "/Library/Logs/oh-my-dsh"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/app.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp = fmt
    }

    private let timestamp: ISO8601DateFormatter

    func log(_ msg: String) {
        queue.async { [handle] in
            let line = "\(self.timestamp.string(from: Date())) \(msg)\n"
            if let data = line.data(using: .utf8) { handle?.write(data) }
        }
    }
}

// MARK: - Localization (zh / en; follows the system by default)

enum L10n {
    /// The real system language, captured once at launch (memory-cached, so
    /// switching back to "System" is instant and always lands on the actual
    /// system language — never a hard-coded fallback).
    private static var capturedSystem: String?

    /// True when the user picked "Follow System" (or never chose) — i.e. no
    /// explicit shell-language choice exists.
    static var hasExplicitChoice: Bool {
        if let env = ProcessInfo.processInfo.environment["DSH_LANG"], !env.isEmpty { return true }
        if let saved = ShellConfig.shared.string(forKey: "appLanguage"), !saved.isEmpty { return true }
        return false
    }

    /// "zh" or "en". Priority: DSH_LANG env > UserDefaults "appLanguage" >
    /// captured system language.
    static var lang: String {
        let env = ProcessInfo.processInfo.environment["DSH_LANG"] ?? ""
        if !env.isEmpty { return env.hasPrefix("zh") ? "zh" : "en" }
        if let saved = ShellConfig.shared.string(forKey: "appLanguage") {
            if saved.hasPrefix("zh") { return "zh" }
            if saved.hasPrefix("en") { return "en" }
        }
        return capturedSystem ?? "en"
    }

    /// Set an explicit choice; pass nil to follow the system again. The
    /// captured system language stays cached, so "follow system" is instant.
    static func set(_ l: String?) {
        if let l = l {
            ShellConfig.shared.set(l.hasPrefix("en") ? "en" : "zh", forKey: "appLanguage")
        } else {
            ShellConfig.shared.removeObject(forKey: "appLanguage")
        }
    }
    static var isZh: Bool { lang == "zh" }

    /// Snapshot the real system language at launch. Must run before we
    /// override AppleLanguages (that override would otherwise mask the system
    /// value). Temporarily peels our own app-domain AppleLanguages override so
    /// `Locale.preferredLanguages` reports the true system language.
    static func captureSystemLang() {
        guard capturedSystem == nil else { return }
        let saved = UserDefaults.standard.array(forKey: "AppleLanguages")
        if saved != nil { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        let first = Locale.preferredLanguages.first ?? ""
        if saved != nil { UserDefaults.standard.set(saved!, forKey: "AppleLanguages") }
        capturedSystem = first.lowercased().hasPrefix("zh") ? "zh" : "en"
    }

    private static let table: [String: (zh: String, en: String)] = [
        // menu
        "menu.about": ("关于", "About"),
        "menu.hide": ("隐藏", "Hide"),
        "menu.quit": ("退出", "Quit"),
        "menu.settings": ("设置", "Settings"),
        "menu.dshSettings": ("dsh 设置", "dsh Settings"),
        "menu.file": ("文件", "File"),
        "menu.save": ("保存", "Save"),
        "menu.edit": ("编辑", "Edit"),
        "menu.view": ("视图", "View"),
        "menu.appearance": ("外观", "Appearance"),
        "menu.togglePreview": ("显示/隐藏 预览面板", "Toggle Preview Panel"),
        // activity bar
        "bar.preview": ("文件", "Files"),
        "bar.terminal": ("终端", "Terminal"),
        "edit.undo": ("撤销", "Undo"),
        "edit.redo": ("重做", "Redo"),
        "edit.cut": ("剪切", "Cut"),
        "edit.copy": ("复制", "Copy"),
        "edit.paste": ("粘贴", "Paste"),
        "edit.selectAll": ("全选", "Select All"),
        "menu.language": ("语言", "Language"),
        "menu.followSystem": ("系统", "System"),
        "menu.checkUpgrade": ("检查并升级 dsh…", "Check & Upgrade dsh…"),
        "menu.autoUpgrade": ("自动升级 dsh", "Auto-upgrade dsh"),
        "menu.setRegistry": ("设置 dsh registry…", "Set dsh Registry…"),
        "menu.resetRegistry": ("恢复默认 registry", "Reset Registry"),
        "menu.openLogs": ("打开日志文件夹", "Open Logs Folder"),
        // status
        "status.starting": ("正在启动 oh-my-dsh 服务…", "Starting oh-my-dsh service…"),
        "status.startFailed": ("无法启动 oh-my-dsh\n\n%@", "Failed to start oh-my-dsh\n\n%@"),
        "status.checking": ("正在检查 dsh 更新…", "Checking for dsh updates…"),
        "status.upgrading": ("正在升级 dsh（%@ → %@）…", "Upgrading dsh (%@ → %@)…"),
        "status.downloading": ("正在下载 dsh %@…", "Downloading dsh %@…"),
        "status.applying": ("正在安装 dsh %@…", "Installing dsh %@…"),
        "status.pageLoadFailed": ("页面加载失败：%@", "Page load failed: %@"),
        // buttons
        "btn.retry": ("重试", "Retry"),
        "btn.ok": ("好", "OK"),
        "btn.save": ("保存", "Save"),
        "btn.cancel": ("取消", "Cancel"),
        "btn.download": ("下载", "Download"),
        "btn.installNow": ("立即升级", "Install & Restart"),
        "btn.later": ("稍后", "Later"),
        "btn.yes": ("是", "Yes"),
        "btn.no": ("否", "No"),
        // preview panel
        "preview.openInDefaultApp": ("在默认应用中打开", "Open in Default App"),
        "preview.openInDefaultAppHint": ("用系统默认应用打开当前文件", "Open the current file with its default app"),
        "preview.revealInFinder": ("在 Finder 中显示", "Show in Finder"),
        "preview.revealInFinderHint": ("在 Finder 中显示当前文件", "Reveal the current file in Finder"),
        "preview.closePanel": ("关闭", "Close"),
        "preview.closeTab": ("关闭页签", "Close Tab"),
        "preview.empty": ("点击对话中的文件链接，在此预览文件或文件夹", "Click a file link in the conversation to preview it here"),
        "preview.missing": ("文件不存在或无法访问：\n%@", "File not found or inaccessible:\n%@"),
        "preview.unreadable": ("无法读取文件：%@", "Cannot read file: %@"),
        "preview.tooLarge": ("文件过大，仅预览前 %d MiB，完整内容请用默认应用打开", "File too large; previewing the first %d MiB. Open with the default app for the full content."),
        "preview.name": ("名称", "Name"),
        "preview.size": ("大小", "Size"),
        "preview.modified": ("修改时间", "Modified"),
        "preview.kind": ("类型", "Kind"),
        "preview.kindUnknown": ("未知类型", "Unknown Type"),
        "preview.created": ("创建时间", "Created"),
        "preview.path": ("路径", "Path"),
        "preview.parent": ("上一级", "Parent"),
        "preview.binary": ("二进制文件，无法预览文本内容", "Binary file — text preview unavailable"),
        "preview.openProject": ("项目目录", "Project Folder"),
        "preview.openProjectHint": ("在面板中打开当前项目目录", "Open the current project folder in the panel"),
        "preview.pickFolderMessage": ("无法自动定位项目目录，请选择要浏览的文件夹", "Could not locate the project folder automatically — choose a folder to browse"),
        "preview.pickFolderOpen": ("打开", "Open"),
        "preview.saveHint": ("保存当前文件", "Save the current file"),
        "preview.saveFailed": ("保存失败：%@", "Save failed: %@"),
        // terminal panel
        "menu.toggleTerminal": ("显示/隐藏 终端面板", "Toggle Terminal Panel"),
        "terminal.title": ("终端", "Terminal"),
        "terminal.new": ("新建终端", "New Terminal"),
        "terminal.newHint": ("新建一个终端会话", "Start a new terminal session"),
        "terminal.closeTab": ("关闭终端", "Close Terminal"),
        "terminal.empty": ("点击 + 新建一个终端", "Click + to start a new terminal"),
        "terminal.sessionEnded": ("会话已结束（exit %d）", "Session ended (exit %d)"),
        "terminal.restart": ("重启", "Restart"),
        // wiki panel (Repo Wiki)
        "menu.toggleWiki": ("显示/隐藏 知识库面板", "Toggle Wiki Panel"),
        "bar.wiki": ("知识库", "Wiki"),        "wiki.title": ("知识库", "Wiki"),
        "wiki.generateHint": ("生成或更新知识库", "Generate or update the wiki"),
        "wiki.empty": ("仓库尚无知识库\n点击右上角 + 生成", "No wiki yet\nClick + to generate"),
        "wiki.generating": ("正在生成知识库…", "Generating wiki…"),
        "wiki.generatingElapsed": ("生成中… %d 秒", "Generating… %ds"),
        "wiki.generatingOther": ("正在为「%@」生成知识库…", "Generating wiki for %@…"),
        "wiki.failed": ("生成失败（详见日志）", "Generation failed (see log)"),
        "wiki.needServer": ("服务未就绪", "Service not ready"),
        "wiki.info": ("%d 页 · 过期 %d · 手动 %d", "%d pages · %d stale · %d manual"),
        "wiki.searchPlaceholder": ("搜索页面标题…", "Search page titles…"),
        "wiki.backlinks": ("反向链接", "Backlinks"),
        "wiki.settingsAuto": ("自动更新知识库", "Auto-update Wiki"),
        "wiki.settingsRegister": ("写入 AGENTS.md 注册块", "Register in AGENTS.md"),
        "wiki.settingsRoot": ("知识库根目录", "Wiki Root"),
        "wiki.settingsRootInRepo": ("仓库内 .dsh/wiki", "In-repo .dsh/wiki"),
        "wiki.settingsRootHome": ("DSH_HOME 私有", "DSH_HOME private"),
        // wiki auto-update prompts
        "wiki.autoPromptTitle": ("开启自动更新知识库？", "Enable auto-updating the wiki?"),
        "wiki.autoPromptInfo": ("代码变更后（≥3 页可能过期且 index 超过 1 小时）会自动增量更新知识库，每小时最多一次，消耗少量 token。也可随时在「设置」菜单中调整。",
                                "After code changes (≥3 possibly stale pages and an index older than 1h) the wiki updates itself incrementally, at most hourly, at a small token cost. Adjust anytime in the Settings menu."),
        "wiki.autoPromptEnable": ("开启", "Enable"),
        "wiki.autoPromptLater": ("暂不", "Not now"),
        "wiki.updatePromptTitle": ("更新知识库？", "Update the wiki?"),
        "wiki.updatePromptInfo": ("检测到 %d 个页面可能过期。是否现在增量更新知识库？",
                                  "Detected %d possibly stale pages. Update the wiki now?"),
        "wiki.updateNow": ("更新", "Update"),
        "wiki.updateLater": ("稍后", "Later"),
        // alerts
        "alert.cannotUpgrade": ("无法升级", "Cannot Upgrade"),
        "alert.noRuntime": ("未找到内置 dsh 运行时（runtime/dsh + runtime/npm）。",
                            "Bundled dsh runtime not found (runtime/dsh + runtime/npm)."),
        "alert.dshUpgrade": ("dsh 升级", "dsh Upgrade"),
        "alert.upgradeFailed": ("升级失败", "Upgrade Failed"),
        "alert.upToDate": ("dsh 已是最新版本：%@", "dsh is up to date: %@"),
        "alert.upgraded": ("dsh 已升级：%@ → %@", "dsh upgraded: %@ → %@"),
        // stepwise / staged upgrade prompts
        "alert.upgradeAvailable": ("发现 dsh 新版本：%@（下一步）", "dsh update available: %@ (next step)"),
        "alert.upgradeAvailableInfo": ("当前版本：%@\n可升级到：%@\n\n下载后仍会二次确认，才真正替换运行版本。",
                                       "Current: %@\nNext step: %@\n\nAfter downloading you confirm again before it replaces the running dsh."),
        "alert.downloadDone": ("dsh %@ 已下载完成", "dsh %@ is ready"),
        "alert.downloadDoneInfo": ("已下载到本地缓存，尚未改动运行中的 dsh。\n是否立即升级并重启服务？",
                                   "Downloaded to the local cache; the running dsh is unchanged.\nInstall and restart now?"),
        "alert.downloadFailed": ("下载失败", "Download Failed"),
        "alert.downloadCancelled": ("已取消下载", "Download Cancelled"),
        "alert.upgradeInProgress": ("已有升级流程正在进行，请稍候", "An upgrade is already in progress — please wait"),
        "alert.rolledBack": ("升级失败，已自动回滚到 %@。\n\n%@", "Upgrade failed; rolled back to %@.\n\n%@"),
        "err.prefetchFailed": ("下载 dsh 失败（%@）", "Failed to download dsh (%@)"),
        "alert.noVersionInfo": ("无法获取 dsh 版本信息（registry：%@）",
                                "Cannot fetch dsh version info (registry: %@)"),
        "alert.setRegistryTitle": ("设置 dsh registry", "Set dsh Registry"),
        "alert.setRegistryInfo": ("用于检查与升级 dsh 的 npm registry。\n当前：%@",
                                  "npm registry used to check & upgrade dsh.\nCurrent: %@"),
        // about
        "about.version": ("版本 %@（%@）", "Version %@ (%@)"),
        "about.credits": ("原生壳封装 dsh web，不改动任何 DeepSeek Harness 源码。\n\n"
                          + "dsh 版本：%@（%@）\nNode: %@ (%@)\ndsh registry：%@",
                          "A native shell around dsh web; no DeepSeek Harness source is modified.\n\n"
                          + "dsh: %@ (%@)\nNode: %@ (%@)\ndsh registry: %@"),
        // settings window
        "settings.openMenu": ("设置…", "Settings…"),
        "settings.title": ("设置", "Settings"),
        "settings.language": ("语言", "Language"),
        "settings.followSystem": ("跟随系统", "Follow System"),
        "settings.registry": ("Registry", "Registry"),
        "settings.registryHint": ("当前生效：%@", "Effective: %@"),
        "settings.registryEnvOverride": ("检测到 DSH_REGISTRY 环境变量，当前生效：%@（此处保存的值仍会被保留）",
                                         "DSH_REGISTRY env detected — effective: %@ (a saved value below is kept)"),
        "settings.upgrade": ("升级", "Upgrade"),
        "settings.dshVersion": ("dsh 版本：%@", "dsh version: %@"),
        "settings.appearance": ("主题", "Appearance"),
        "settings.appearanceLight": ("浅色", "Light"),
        "settings.appearanceDark": ("深色", "Dark"),
        "settings.appearanceSystem": ("系统", "System"),
        "settings.shortcuts": ("快捷键", "Shortcuts"),
        // first-run onboarding
        "onboarding.title": ("欢迎使用 oh-my-dsh", "Welcome to oh-my-dsh"),
        "onboarding.points": ("• 内置 Node 与 dsh 运行时，开箱即用，无需安装\n"
                              + "• 首次启动自动复用或拉起 dsh web（127.0.0.1:3080）\n"
                              + "• 右侧活动栏：预览 / 终端 / 知识库面板\n"
                              + "• 设置菜单可切换语言、registry、升级策略与主题",
                              "• Bundled Node + dsh runtime — nothing to install\n"
                              + "• On launch, reuses or starts dsh web (127.0.0.1:3080)\n"
                              + "• Right activity bar: Preview / Terminal / Wiki panels\n"
                              + "• Settings menu switches language, registry, upgrade policy and theme"),
        "onboarding.getStarted": ("开始使用", "Get Started"),
        "onboarding.learnMore": ("了解更多", "Learn More"),
        // runtime facts (About)
        "fact.bundled": ("内置（Contents/Resources/runtime）", "bundled (Contents/Resources/runtime)"),
        "fact.system": ("系统安装", "system"),
        "fact.unknown": ("未知", "unknown"),
        // server errors (shown in the status overlay / error alert)
        "err.noNode": ("找不到 node（可设置 DSH_NODE 环境变量指向 node 可执行文件）",
                       "Node not found (set DSH_NODE to the node executable)"),
        "err.noDSH": ("找不到 dsh CLI（可设置 DSH_CLI 环境变量指向 @deepseek-ai/dsh 的 lib/bin.js）",
                      "dsh CLI not found (set DSH_CLI to @deepseek-ai/dsh's lib/bin.js)"),
        "err.spawnFailed": ("启动 dsh web 失败：%@", "Failed to start dsh web: %@"),
        "err.exited": ("dsh web 进程意外退出。日志末尾：\n%@", "dsh web exited unexpectedly. Log tail:\n%@"),
        "err.timeout": ("等待 dsh web 启动超时（90 秒）。日志：%@",
                        "Timed out waiting for dsh web (90s). Log: %@"),
        "err.upgradeFailed": ("dsh 升级失败（exit %d）：\n%@", "dsh upgrade failed (exit %d):\n%@"),
        "err.noVersionAfterUpgrade": ("升级后无法读取 dsh 版本", "Cannot read dsh version after upgrade"),
        // IssueRunner task panel
        "bar.tasks": ("任务", "Tasks"),
        "menu.toggleTasks": ("显示/隐藏 任务面板", "Toggle Tasks Panel"),
        // browser panel
        "menu.toggleBrowser": ("显示/隐藏 浏览器面板", "Toggle Browser Panel"),
        "bar.channel": ("通道", "Channel"),
        "menu.toggleChannel": ("显示/隐藏 通道面板", "Toggle Channel Panel"),
        // review panel — read-only change audit (name fixed: 审查 / Review)
        "bar.review": ("审查", "Review"),
        "menu.toggleReview": ("显示/隐藏 审查面板", "Toggle Review Panel"),
        "review.title": ("审查", "Review"),
        "review.refresh": ("重新读取", "Reload"),
        "review.expandAll": ("全部展开", "Expand All"),
        "review.collapseAll": ("全部收起", "Collapse All"),
        "review.suspectOnly": ("只看可疑命令", "Suspect only"),
        "review.loading": ("读取会话日志…", "Reading session logs…"),
        "review.reading": ("读取中…", "reading…"),
        "review.empty": ("该会话没有记录到文件变更", "No file changes recorded in this session"),
        "review.noSessions": ("当前工作区没有会话日志", "No session logs for this workspace"),
        "review.noWorkspace": ("未定位到工作区", "No workspace resolved"),
        "review.loadFailed": ("读取失败（详见应用日志）", "Read failed (see the app log)"),
        "review.summarySessions": ("会话", "sessions"),
        "review.summaryTurns": ("对话", "turns"),
        "review.filesShort": ("文件", "files"),
        "review.turn": ("对话", "Turn"),
        "review.turnUnknown": ("未标注轮次", "Unnumbered"),
        "review.subagent": ("子代理", "subagent"),
        "review.nested": ("嵌套", "nested"),
        "review.nestedCall": ("嵌套调用", "nested call"),
        "review.suspect": ("可能写文件", "may write"),
        "review.suspectShort": ("shell 可疑", "suspect shell"),
        "review.shell": ("shell", "shell"),
        "review.other": ("其它", "other"),
        "review.error": ("失败", "failed"),
        "review.cat.diff": ("已应用", "applied"),
        "review.cat.args": ("参数还原", "from args"),
        "review.cat.content": ("全文写入", "full content"),
        "review.cat.create": ("新建", "created"),
        "review.failedHeader": ("失败的调用（未改动）", "Failed calls (not applied)"),
        "review.bashHeader": ("shell 命令（无前后内容记录）", "Shell commands (no before/after record)"),
        "review.unstructuredNote": ("shell 直改不经结构化记录，需人工核对", "shell writes bypass structured records — verify manually"),
        "review.moreLines": ("…还有 %d 行", "…%d more lines"),
        "channel.title": ("通道", "Channel"),
        "channel.add": ("新增通道", "Add Channel"),
        "channel.refresh": ("刷新", "Refresh"),
        "channel.global": ("全局通道", "Global Channels"),
        "channel.refs": ("本项目引用", "Project Refs"),
        "channel.workspace": ("工作区:", "Workspace:"),
        "channel.noWorkspace": ("当前工作区未知（未绑定项目）", "Current workspace unknown"),
        "channel.addTitle": ("新增通道", "Add Channel"),
        "channel.addInfo": ("命名并选择平台。连接参数（登录态/凭据）在接入时配置。", "Name the channel and pick a platform. Connection parameters (login/credentials) are configured on connect."),
        "channel.namePlaceholder": ("通道名称", "Channel name"),
        "channel.login": ("扫码登录", "Scan to Login"),
        "channel.loggingIn": ("正在登录通道：", "Logging in channel: "),
        "channel.loginDone": ("登录成功（token 已保存）", "Logged in (token saved)"),
        "channel.loginFailed": ("登录失败或已取消", "Login failed or cancelled"),
        "channel.noLoginRunner": ("无法启动登录（核心不可用）", "Cannot start login (core unavailable)"),
        "channel.onboardingTitle": ("接入一个通道", "Connect a Channel"),
        "channel.onboardingHint": ("选择一个平台开始配置。未配置时，来自客户端的消息无法路由。", "Pick a platform to start. Until configured, incoming messages cannot be routed."),
        "channel.card.weixin": ("微信 ClawBot", "WeChat ClawBot"),
        "channel.card.weixinDesc": ("通过微信个人号收发消息（官方 iLink 协议）", "Send & receive via WeChat (official iLink)"),
        "channel.card.dingtalk": ("钉钉", "DingTalk"),
        "channel.card.dingtalkDesc": ("钉钉机器人 Stream 连接（扫码创建应用）", "DingTalk bot via Stream (QR app registration)"),
        "channel.card.feishu": ("飞书", "Feishu"),
        "channel.card.feishuDesc": ("飞书机器人事件订阅（待实现）", "Feishu bot events (planned)"),
        "channel.card.open": ("开始配置", "Configure"),
        "channel.wizard.promptTitle": ("打开微信，准备扫码", "Open WeChat, ready to scan"),
        "channel.wizard.promptInfo": ("下一步将打开登录二维码。请用手机微信扫码并确认，以绑定此通道。", "Next opens the login QR. Scan it with WeChat to bind this channel."),
        "channel.wizard.continue": ("继续", "Continue"),
        "channel.wizard.scanning": ("等待扫码…（二维码已在新标签页打开）", "Waiting for scan… (QR opened in a new tab)"),
        "channel.wizard.done": ("绑定成功 ✅", "Bound successfully ✅"),
        "channel.wizard.promptTitle.dingtalk": ("打开钉钉，准备扫码", "Open DingTalk, ready to scan"),
        "channel.wizard.promptInfo.dingtalk": ("下一步将打开登录二维码。请用手机钉钉扫码，以创建钉钉应用并绑定此通道。", "Next opens the login QR. Scan it with DingTalk to create the app and bind this channel."),
        "channel.state.unconfigured": ("未配置", "Not configured"),
        "channel.state.connected": ("已连接", "Connected"),
        "channel.state.connecting": ("连接中", "Connecting"),
        "channel.state.reconnecting": ("重连中", "Reconnecting"),
        "channel.state.authExpired": ("鉴权失效，请重新登录", "Auth expired, re-login required"),
        "channel.state.disconnected": ("未连接", "Disconnected"),
        "channel.unbind": ("解绑", "Unbind"),
        "channel.unbind.confirmTitle": ("解绑该通道？", "Unbind this channel?"),
        "channel.unbind.confirmBody": ("将清空该通道的连接配置与本地数据，且停止其运行中的监听进程。", "This will clear the channel's connection config and local data, and stop its running listener."),
        "channel.bind.bound": ("已绑定管理员", "Owner bound"),
        "channel.bind.hint": ("绑定口令：%@（请在钉钉发送 /bind %@）", "Bind code: %@ (send /bind %@ in DingTalk)"),
        "channel.wizard.openLink": ("在浏览器中打开（无需扫码）", "Open in browser (no scan needed)"),
        "channel.wizard.robotNameHint": ("扫码或打开链接，创建 DeepSeek Harness 钉钉机器人", "Scan the QR or open the link to create the DeepSeek Harness DingTalk robot"),
        "channel.wizard.bindCode": ("请在钉钉发送 /bind %@ 完成管理员绑定", "Send /bind %@ in DingTalk to bind the owner"),
        "channel.wizard.bindCodePending": ("绑定口令稍后显示在通道卡片", "The bind code will appear on the channel card"),
        "channel.wizard.bindCodePrompt": ("在钉钉私聊发送此口令，完成管理员绑定", "Send this in a DingTalk direct message to bind the owner"),
        "channel.wizard.copyBind": ("复制", "Copy"),
        "channel.wizard.recoverInfo": ("该通道应用已创建，请在钉钉发送下方口令完成管理员绑定", "This channel's app is created; send the code below in DingTalk to bind the owner"),
        "channel.wizard.relogin": ("重新登录", "Re-login"),
        "channel.wizard.weixinConfigured": ("该通道已配置，可重新扫码登录以刷新凭据。", "This channel is configured; re-scan to refresh credentials."),
        "channel.wizard.back": ("返回", "Back"),
        "channel.globalConfig": ("全局配置", "Global Config"),
        "channel.projectAvailable": ("当前项目可用通道", "Available Channels"),
        "channel.noAvailable": ("暂无可用通道（先完成全局配置）", "No available channels (configure globally first)"),
        "channel.enabled": ("已开启", "On"),
        "channel.disabled": ("已关闭", "Off"),
        "channel.sessions": ("会话", "Sessions"),
        "channel.noSessions": ("暂无会话", "No sessions yet"),
        "channel.noMessages": ("暂无消息", "No messages yet"),
        "channel.notEnabledInProject": ("当前项目已禁用", "Disabled in this project"),
        "channel.done": ("完成", "Done"),
        "bar.browser": ("浏览器", "Browser"),
        "browser.title": ("浏览器", "Browser"),
        "browser.openInSystem": ("在系统浏览器中打开", "Open in System Browser"),
        "browser.devTools": ("在浏览器中打开 DevTools", "Open DevTools in Browser"),
        "browser.copyURL": ("复制 URL", "Copy URL"),
                "browser.back": ("后退", "Back"),
        "browser.forward": ("前进", "Forward"),
        "browser.reload": ("刷新", "Reload"),
        "browser.addressPlaceholder": ("输入网址…", "Enter URL…"),
        "browser.go": ("前往", "Go"),
        "browser.newTabHint": ("新建标签页", "New Tab"),
        "browser.closeTab": ("关闭标签页", "Close Tab"),
        "browser.empty": ("点击 + 新建标签页", "Click + to start a new tab"),
                                        "tasks.title": ("任务", "Tasks"),
        "tasks.configHint": ("配置 GitHub Token", "Configure GitHub Token"),
        "tasks.refreshHint": ("刷新 Issues", "Refresh Issues"),
        "tasks.runAllHint": ("全部处理（串行）", "Process All (serial)"),
        "tasks.noRepo": ("当前工作区不是 GitHub 仓库", "Current workspace is not a GitHub repo"),
        "tasks.loading": ("加载 Issues…", "Loading issues…"),
        "tasks.loadFailed": ("加载 Issues 失败（网络/限流/Token？）", "Failed to load issues (network/rate-limit/token?)"),
        "tasks.running": ("正在处理 #%d…", "Processing #%d…"),
        "tasks.creatingPr": ("正在创建 #%d 的 PR…", "Creating PR for #%d…"),
        "tasks.sessionLabel": ("任务会话", "task session"),
        "tasks.errBranch": ("切换/创建分支失败（分支已存在或被占用？）", "Failed to create/checkout branch (exists or busy?)"),
        "tasks.errSession": ("创建 dsh 会话失败", "Failed to create dsh session"),
        "tasks.errPrompt": ("向会话发送任务失败", "Failed to prompt the session"),
        "tasks.errTimeout": ("任务超时（30 分钟）", "Task timed out (30 minutes)"),
        "tasks.errNoPush": ("分支未推送到远端（代理未 push？）", "Branch was not pushed (agent didn't push?)"),
        "tasks.errPR": ("创建 PR 失败", "Failed to create PR"),
        "tasks.failTitle": ("任务失败", "Task Failed"),
        "tasks.prTitle": ("fix(#%d)", "fix(#%d)"),
        "tasks.prBody": ("自动修复 GitHub issue #%d（由 oh-my-dsh 任务面板处理）", "Automated fix for GitHub issue #%d (processed by oh-my-dsh task panel)"),
        "tasks.configTitle": ("GitHub Token", "GitHub Token"),
        "tasks.configInfo": ("GitHub token（按当前仓库保存：Keychain + ~/.dsh/tokens/<owner>-<repo> 文件双写，App 与外部工具共用）。仅用于拉取 issues、创建 PR、评论关闭 issue；公开仓库可留空。", "GitHub token (saved per repo: written to both Keychain and ~/.dsh/tokens/<owner>-<repo>, shared with external tools). Used only to fetch issues, create PRs, comment & close issues; public repos may leave empty."),
        "tasks.tokenPlaceholder": ("ghp_xxx（可选）", "ghp_xxx (optional)"),
        "tasks.detailTitle": ("Issue #%d", "Issue #%d"),
        "tasks.detailLabels": ("标签：%@", "Labels: %@"),
        "tasks.detailBranch": ("分支：%@", "Branch: %@"),
        "tasks.detailPR": ("PR：%@", "PR: %@"),
        "tasks.detailState": ("状态：%@", "State: %@"),
        "tasks.state.pending": ("待处理", "Pending"),
        "tasks.state.running": ("处理中", "Running"),
        "tasks.state.done": ("已完成", "Done"),
        "tasks.state.failed": ("失败", "Failed"),
        "tasks.state.cancelled": ("已取消", "Cancelled"),
        "tasks.state.closed": ("已关闭", "Closed"),
        "tasks.detailProcess": ("处理", "Process"),
        "tasks.detailOpenPR": ("打开 PR", "Open PR"),
        "tasks.detailRetry": ("重试", "Retry"),
        "tasks.detailCancelTask": ("取消任务", "Cancel Task"),
        "tasks.detailClose": ("关闭", "Close"),
        "tasks.detailCommentClose": ("评论并关闭 Issue", "Comment & Close Issue"),
        "tasks.detailOpenIssue": ("打开 Issue", "Open Issue"),
        "tasks.commentCloseTitle": ("评论并关闭 Issue #%d", "Comment & Close Issue #%d"),
        "tasks.commentCloseInfo": ("将发布一条评论并关闭该 issue（需 GitHub token）。可编辑下方评论内容：", "Posts a comment and closes the issue (needs a GitHub token). You can edit the comment below:"),
        "tasks.commentCloseDone": ("已评论并关闭 issue #%d", "Commented & closed issue #%d"),
        "tasks.commentCloseFailed": ("评论/关闭失败（检查 token 与网络）", "Comment/close failed (check token & network)"),
        "tasks.commentTemplate": ("已由 oh-my-dsh 任务面板处理完成，对应 PR：#%@", "Processed by the oh-my-dsh task panel; PR: %@"),
    ]

    /// Localize a key, optionally filling %@ / %d placeholders.
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let entry = table[key] ?? (key, key)
        let t = isZh ? entry.zh : entry.en
        return String(format: t, arguments: args)
    }
}

// MARK: - HTTP / version / registry helpers

enum HTTP {
    static func get(_ urlString: String, timeout: TimeInterval = 10) -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        task.cancel()
        return result
    }
}

enum VersionKit {
    /// -1 if a < b, 0 if equal, 1 if a > b. Handles "x.y.z" and "x.y.z-rc.N".
    static func compare(_ a: String, _ b: String) -> Int {
        func numeric(_ s: String) -> [Int] {
            let core = s.split(separator: "-").first.map(String.init) ?? s
            return core.split(separator: ".").compactMap { Int($0) }
        }
        let pa = numeric(a), pb = numeric(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        let preA = a.contains("-"), preB = b.contains("-")
        if preA != preB { return preA ? -1 : 1 }
        if preA {
            let ra = a.split(separator: "-")[1], rb = b.split(separator: "-")[1]
            let na = Int(ra) ?? 0, nb = Int(rb) ?? 0
            if na != nb { return na < nb ? -1 : 1 }
            if ra != rb { return ra < rb ? -1 : 1 }
        }
        return 0
    }
}

/// npm registry used to check & upgrade the bundled dsh.
/// Priority: DSH_REGISTRY env > saved UserDefaults "dshRegistry" > China mirror.
enum RegistryConfig {
    static var current: String {
        let env = ProcessInfo.processInfo.environment["DSH_REGISTRY"] ?? ""
        if !env.isEmpty { return normalize(env) }
        if let saved = ShellConfig.shared.string(forKey: "dshRegistry"), !saved.isEmpty {
            return normalize(saved)
        }
        return "https://registry.npmmirror.com"
    }
    static func set(_ url: String) { ShellConfig.shared.set(url, forKey: "dshRegistry") }
    static func reset() { ShellConfig.shared.removeObject(forKey: "dshRegistry") }
    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }
}

/// App-wide appearance (theme). Follows the system by default; persisted in
/// UserDefaults "appTheme" ("system" | "light" | "dark"). Applied at launch
/// and immediately when changed (NSApp.appearance drives every window and the
/// WKWebView re-renders with the new appearance automatically).
enum AppTheme {
    static var current: String {
        ShellConfig.shared.string(forKey: "appTheme") ?? "system"
    }
    static func set(_ mode: String) {
        ShellConfig.shared.set(mode, forKey: "appTheme")
        apply()
    }
    static func apply() {
        switch current {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        AppLog.shared.log("appearance applied: \(current)")
    }
}

/// Cooperative cancellation token for a running staged download. A caller
/// keeps a reference and asks to stop; the running npm process is terminated.
final class UpgradeCancelToken {
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func requestStop() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}

/// Upgrades the bundled dsh tree with the bundled node + npm.
///
/// dsh upgrades are STEPWISE (one release candidate — stable or rc — at a
/// time) and STAGED so the heavy download never touches the live tree:
///   - prefetch() warms the shared npm cache with the pinned version in a
///     throwaway staging dir (the "download" phase; cancellable, cheap to drop);
///   - apply() installs the pinned version in place from the warm cache,
///     backing up the live tree first and restoring it automatically on failure.
final class DSHUpdater {
    let nodePath: String
    let dshDir: String
    let npmCli: String

    init?(nodePath: String, dshBin: String) {
        // Upgrades only apply to the bundled, self-contained runtime —
        // never touch a system-installed dsh.
        guard let range = dshBin.range(of: "/Contents/Resources/runtime/") else { return nil }
        self.nodePath = nodePath
        let runtime = String(dshBin[..<range.lowerBound]) + "/Contents/Resources/runtime"
        self.dshDir = runtime + "/dsh"
        self.npmCli = runtime + "/npm/bin/npm-cli.js"
        guard FileManager.default.isExecutableFile(atPath: nodePath),
              FileManager.default.fileExists(atPath: npmCli) else { return nil }
    }

    // MARK: versions

    var currentVersion: String? {
        let pkg = dshDir + "/node_modules/@deepseek-ai/dsh/package.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pkg)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = json["version"] as? String else { return nil }
        return v
    }

    private func registryJSON(registry: String) -> [String: Any]? {
        guard let data = HTTP.get(registry + "/@deepseek-ai/dsh", timeout: 15),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    func latestVersion(registry: String) -> String? {
        guard let json = registryJSON(registry: registry),
              let tags = json["dist-tags"] as? [String: Any],
              let latest = tags["latest"] as? String else { return nil }
        return latest
    }

    /// Every published version string (unsorted). Stepwise target selection
    /// (stable/rc candidates, never jumping to latest) runs in the shared core.
    func publishedVersions(registry: String) -> [String] {
        guard let json = registryJSON(registry: registry),
              let versions = json["versions"] as? [String: Any] else { return [] }
        return Array(versions.keys)
    }

    // MARK: npm process plumbing

    private var sharedCacheDir: String {
        NSHomeDirectory() + "/Library/Caches/oh-my-dsh/npm-cache"
    }
    private var stagingDir: String {
        NSHomeDirectory() + "/Library/Caches/oh-my-dsh/staging"
    }
    private var backupsRoot: String {
        NSHomeDirectory() + "/Library/Caches/oh-my-dsh/upgrade-backups"
    }

    /// npm env: pass OS env through, but prepend the bundled node's dir to PATH
    /// (npm lifecycle scripts look up `node` on PATH) and route the npm cache
    /// to the shared cache dir so prefetch and apply share warmed downloads.
    private func npmEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let nodeBinDir = (nodePath as NSString).deletingLastPathComponent
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = nodeBinDir + ":" + existing
        } else {
            env["PATH"] = nodeBinDir
        }
        env["npm_config_cache"] = sharedCacheDir
        env["npm_config_update_notifier"] = "false"
        return env
    }

    /// Runs `node <npmCli> <args…>` in `cwd`, streaming merged output. Returns
    /// the exit code (-1 on spawn failure). Terminates the process as soon as
    /// `cancel` is requested, so a download can be interrupted.
    @discardableResult
    private func runNpm(_ args: [String], cwd: String, cancel: UpgradeCancelToken? = nil,
                        onOutput: ((String) -> Void)? = nil) -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = args
        proc.environment = npmEnv()
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out

        let finished = DispatchGroup()
        finished.enter()
        out.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                finished.leave()
            } else if cancel?.cancelled == true {
                fh.readabilityHandler = nil
                finished.leave()
            } else if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                onOutput?(s)
            }
        }

        // Cancellation watcher: terminate the process shortly after requested.
        DispatchQueue.global().async {
            while proc.isRunning {
                if cancel?.cancelled == true { proc.terminate(); break }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        do { try proc.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return -1
        }
        proc.waitUntilExit()
        finished.wait()
        return Int(proc.terminationStatus)
    }

    // MARK: staged download (prefetch) & in-place apply

    /// Download phase: warm the shared npm cache with the pinned `version` by
    /// installing it into a throwaway staging dir. The live dsh tree is never
    /// touched, so this is cancellable and safe to abandon (only the cache
    /// matters; the staging dir is removed when done).
    @discardableResult
    func prefetch(registry: String, version: String, cancel: UpgradeCancelToken? = nil,
                  onOutput: ((String) -> Void)? = nil) throws -> Bool {
        let fm = FileManager.default
        let staging = stagingDir
        _ = try? fm.removeItem(atPath: staging)
        do { try fm.createDirectory(atPath: staging, withIntermediateDirectories: true) } catch {
            throw NSError(domain: "DSHUpgrade", code: 3, userInfo: [
                NSLocalizedDescriptionKey: L10n.tr("err.prefetchFailed", error.localizedDescription)])
        }
        defer { _ = try? fm.removeItem(atPath: staging) }
        var log = ""
        let args = [npmCli, "install", "--loglevel=error", "--no-audit", "--no-fund",
                    "--registry", registry, "@deepseek-ai/dsh@" + version]
        let code = runNpm(args, cwd: staging, cancel: cancel, onOutput: { log.append($0) })
        if cancel?.cancelled == true { return false }
        guard code == 0 else {
            throw NSError(domain: "DSHUpgrade", code: 3, userInfo: [
                NSLocalizedDescriptionKey: L10n.tr("err.prefetchFailed", String(log.suffix(500)))])
        }
        return true
    }

    private func pruneBackups(keeping: Int) {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(atPath: backupsRoot)) ?? [])
            .filter { var d: ObjCBool = false
                fm.fileExists(atPath: backupsRoot + "/" + $0, isDirectory: &d)
                return d.boolValue }
            .sorted { $0 < $1 }
        if dirs.count > keeping {
            for name in dirs[0 ..< (dirs.count - keeping)] {
                try? fm.removeItem(atPath: backupsRoot + "/" + name)
            }
        }
    }

    /// Snapshot the whole live dsh tree before an in-place install so a failed
    /// upgrade can roll back. Keeps only the most recent backup.
    private func backup() -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: backupsRoot, withIntermediateDirectories: true)
        pruneBackups(keeping: 1)
        let name = (currentVersion ?? "current") + "-" + String(Int(Date().timeIntervalSince1970))
        let dest = backupsRoot + "/" + name
        do { try fm.copyItem(atPath: dshDir, toPath: dest) } catch { return nil }
        return dest
    }

    /// Restore a backup over the (possibly partially written) live tree.
    private func restore(fromBackup backupPath: String) -> Bool {
        let fm = FileManager.default
        let displaced = dshDir + ".upgrade-old"
        _ = try? fm.removeItem(atPath: displaced)
        do { try fm.moveItem(atPath: dshDir, toPath: displaced) } catch { return false }
        do {
            try fm.moveItem(atPath: backupPath, toPath: dshDir)
            _ = try? fm.removeItem(atPath: displaced)
            return true
        } catch {
            _ = try? fm.moveItem(atPath: displaced, toPath: dshDir)
            return false
        }
    }

    /// Apply phase: back up the live tree, install the pinned `version` in
    /// place from the (pre-warmed) cache, verify the installed version, and
    /// roll back to the backup on any failure. Returns the installed version.
    @discardableResult
    func apply(registry: String, version: String) throws -> String {
        let backupPath = backup()
        var log = ""
        let args = [npmCli, "install", "--loglevel=error", "--no-audit", "--no-fund",
                    "--prefer-offline", "--registry", registry, "@deepseek-ai/dsh@" + version]
        let code = runNpm(args, cwd: dshDir, onOutput: { log.append($0) })
        if code != 0 {
            if let b = backupPath { _ = restore(fromBackup: b) }
            throw NSError(domain: "DSHUpgrade", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L10n.tr("err.upgradeFailed", code, String(log.suffix(1500)))])
        }
        guard let v = currentVersion, VersionKit.compare(v, version) == 0 else {
            if let b = backupPath { _ = restore(fromBackup: b) }
            throw NSError(domain: "DSHUpgrade", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L10n.tr("err.noVersionAfterUpgrade")])
        }
        if let b = backupPath { _ = try? FileManager.default.removeItem(atPath: b) }
        return v
    }
}

/// Bridge to the shared core (`core/bin/ohmy-core.js`, embedded in the app
/// runtime at Contents/Resources/runtime/core). The macOS shell calls core
/// for logic that must stay identical across platforms (version compare,
/// upgrade checks, port probing, session RPC) instead of reimplementing it
/// in Swift. Keeps DSH_NODE / DSH_CLI overrides (resolveNode already honors
/// them); falls back silently when core is unavailable.
enum CoreBridge {
    /// Path to the bundled core CLI, or nil.
    static var coreCLIPath: String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let p = res.appendingPathComponent("runtime/core/bin/ohmy-core.js").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Run `<node> <core-cli> args…`, returning trimmed stdout or nil.
    /// `preferBundledNode` picks the embedded runtime first: the session-log
    /// audit needs Zstandard decoding, which only Node >= 22.15 provides — a
    /// user-installed Node 18/20 would otherwise fail the Review panel.
    static func run(_ args: [String], timeout: TimeInterval = 15, preferBundledNode: Bool = false) -> String? {
        guard let cli = coreCLIPath else { return nil }
        let manager = ServerManager()
        guard let node = (preferBundledNode ? manager.bundledNode() : nil) ?? manager.resolveNode() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = [cli] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Version compare via core: 1 if a > b, 0 equal, -1 a < b (or nil).
    static func compareVersions(_ a: String, _ b: String) -> Int? {
        guard let out = run(["upgrade", "compare", a, b]), let n = Int(out) else { return nil }
        return n
    }

    /// Latest dsh version from the registry via core (or nil).
    static func latestVersion(registry: String) -> String? {
        run(["upgrade", "latest", registry])
    }

    /// Stepwise upgrade target via core: the next release candidate (stable/rc)
    /// strictly newer than `current`. Returns nil when core is unavailable or
    /// prints an empty result (nothing newer — an empty string then means "no
    /// update"; the caller can treat a returned "" as none).
    static func nextStepTarget(current: String, versions: [String]) -> String? {
        guard !versions.isEmpty else { return nil }
        return run(["upgrade", "next", current] + versions)
    }
}

// MARK: - dsh web server management

final class ServerManager {

    private(set) var port = 3080
    private(set) var spawned = false
    private(set) var process: Process?

    /// The entry URL dsh web advertises ("http://127.0.0.1:<port>/?token=…").
    /// dsh 0.1.2+ fences /api behind a browser cookie minted from that token, so
    /// the shell hands it to the channel runner (native clients have no cookie).
    private(set) var entryURL: URL?

    /// The launch token from the entry URL, nil when dsh advertises none.
    var webToken: String? {
        guard let url = entryURL,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "token" })?.value,
              !value.isEmpty else { return nil }
        return value
    }

    /// Resolved runtime facts, surfaced in the About panel.
    private(set) var dshVersion = L10n.tr("fact.unknown")
    private(set) var nodeVersion = L10n.tr("fact.unknown")
    private(set) var nodePath = L10n.tr("fact.unknown")
    private(set) var runtimeSource = L10n.tr("fact.unknown")

    /// The web UI root page always injects `window.__DSH_BOOT__` on dsh <= 0.1.1.
    func isDSHServing(port: Int, timeout: TimeInterval = 2) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/"),
              let data = httpGet(url, timeout: timeout),
              let body = String(data: data, encoding: .utf8) else { return false }
        return body.contains("__DSH_BOOT__")
    }

    /// True when something on `port` is a dsh web that refuses a bare request
    /// because it wants its launch token (dsh >= 0.1.2). Such an instance CANNOT be
    /// adopted — the token is random per process and only in that process's stdout —
    /// but it is worth distinguishing from "nothing is listening" in the log.
    ///
    /// Not adopting it costs little: the shell spawns its own instance and, with the
    /// same DSH_HOME, both share the same workspaces/sessions/settings. Running two
    /// dsh web on ONE home at the same time is still best avoided (they persist to
    /// the same files), so the log says which one we started.
    func isDSHAuthenticated(port: Int, timeout: TimeInterval = 2) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        let (status, data) = httpGetWithStatus(url, timeout: timeout)
        guard status == 401, let data = data,
              let body = String(data: data, encoding: .utf8) else { return false }
        return body.contains("authentication required")
    }

    /// Parse the self-advertised entry URL a spawned dsh web prints to its log,
    /// e.g. "dsh web: http://127.0.0.1:<port>/?token=…". Returns nil until the
    /// line appears. Handles token and tokenless forms (whatever dsh advertises,
    /// we load exactly that URL so token-auth'd versions work).
    private func servedEntryURL(logPath: String, port: Int) -> URL? {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return nil }
        let needle = "http://127.0.0.1:\(port)"
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard let range = s.range(of: needle) else { continue }
            var tail = String(s[range.lowerBound...])
            if let sp = tail.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == ")" }) {
                tail = String(tail[..<sp])
            }
            if let u = URL(string: tail), (u.scheme == "http" || u.scheme == "https") {
                return u
            }
        }
        return nil
    }

    private func httpGet(_ url: URL, timeout: TimeInterval) -> Data? {
        httpGetWithStatus(url, timeout: timeout).data
    }

    private func httpGetWithStatus(_ url: URL, timeout: TimeInterval) -> (status: Int, data: Data?) {
        let semaphore = DispatchSemaphore(value: 0)
        var status = -1
        var result: Data?
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            result = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        task.cancel()
        return (status, result)
    }

    private func isPortFree(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(UInt16(port))
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc != 0
    }

    private func freePort() -> Int {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 3080 }
        defer { close(fd) }
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return Int(CFSwapInt16BigToHost(bound.sin_port))
    }

    private func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// Bundled self-contained node binary (Contents/Resources/runtime/node).
    /// Universal builds embed runtime/node-arm64 + runtime/node-x86_64 and a
    /// plain `node` (host arch) for compatibility; pick by uname -m.
    func bundledNode() -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let runtime = res.appendingPathComponent("runtime")
        var machine = utsname()
        if uname(&machine) == 0 {
            let arch = withUnsafeBytes(of: &machine.machine) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                var s = ""
                for b in bytes where b != 0 { s.append(Character(UnicodeScalar(b))) }
                return s
            }
            let perArch = runtime.appendingPathComponent("node-\(arch)").path
            if FileManager.default.isExecutableFile(atPath: perArch) { return perArch }
        }
        let plain = runtime.appendingPathComponent("node").path
        return FileManager.default.isExecutableFile(atPath: plain) ? plain : nil
    }

    /// Bundled self-contained dsh entry (Contents/Resources/runtime/dsh/…).
    private func bundledDSHBin() -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        return res.appendingPathComponent("runtime/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js").path
    }

    /// First usable `node` installed on the OS (PATH → nvm current → nvm
    /// default → nvm newest → Homebrew). GUI-launched processes have a minimal
    /// PATH, so we search known locations explicitly. The nvm branch prefers
    /// `~/.nvm/current` (set by the last `nvm use`, including the automatic
    /// `nvm use default` a fresh shell runs) over `~/.nvm/alias/default`.
    /// OS nodes below the version floor (dsh needs Node ≥ 22) are skipped —
    /// the bundled runtime is the fallback for missing or too-old nodes.
    func resolveSystemNode() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        /// Executable + version gate: dsh rc.6 needs Node ≥ 22 (ESM exports
        /// zstd in node:zlib, Promise.withResolvers, stripTypeScriptTypes in
        /// node:module — all present in 22, missing in 20). Too-old OS nodes
        /// are skipped so the bundled runtime is used instead of letting dsh
        /// web half-boot and crash. DSH_NODE_MIN overrides the floor.
        func usable(_ cand: String) -> String? {
            guard fm.isExecutableFile(atPath: cand) else { return nil }
            if let v = nodeVersionString(nodePath: cand)?.replacingOccurrences(of: "v", with: "", options: [.anchored]),
               compareNodeVersions(v, minSystemNodeVersion) < 0 {
                AppLog.shared.log("skipping too-old system node \(cand) (\(v) < \(minSystemNodeVersion))")
                return nil
            }
            return cand
        }
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                if let hit = usable(String(dir) + "/node") { return hit }
            }
        }
        let home = NSHomeDirectory()
        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot), !versions.isEmpty {

            // 1. nvm current symlink (~/.nvm/current → versions/node/<v>): set
            //    by every `nvm use` (including the automatic `nvm use default`
            //    a fresh shell runs), so it reflects the most recently
            //    activated version — the closest to the user's actual choice.
            if let curRaw = try? fm.destinationOfSymbolicLink(atPath: home + "/.nvm/current"), !curRaw.isEmpty {
                let cur = curRaw.hasPrefix("/") ? curRaw : (home + "/.nvm/" + curRaw)
                if let hit = usable(cur + "/bin/node") { return hit }
            }

            // 2. nvm default alias (~/.nvm/alias/default), e.g. "20" or
            //    "v20.19.6": what a fresh shell activates.
            if let alias = try? String(contentsOfFile: home + "/.nvm/alias/default", encoding: .utf8) {
                let v = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    // Exact full-version hit (v20.19.6 / 20.19.6).
                    let exact = nvmRoot + "/" + (v.hasPrefix("v") ? v : "v" + v) + "/bin/node"
                    if let hit = usable(exact) { return hit }
                    // Major-only alias ("20") → newest installed within that major.
                    let prefix = v.hasPrefix("v") ? v : "v" + v
                    for c in versions.filter({ $0.hasPrefix(prefix) })
                        .sorted(by: { mtime(nvmRoot + "/" + $0) > mtime(nvmRoot + "/" + $1) }) {
                        if let hit = usable(nvmRoot + "/" + c + "/bin/node") { return hit }
                    }
                }
            }

            // 3. Most recently installed version (previous behavior).
            for v in versions.sorted(by: { mtime(nvmRoot + "/" + $0) > mtime(nvmRoot + "/" + $1) }) {
                if let hit = usable(nvmRoot + "/" + v + "/bin/node") { return hit }
            }
        }
        for p in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] {
            if let hit = usable(p) { return hit }
        }
        return nil
    }

    /// Minimum OS node version accepted for dsh web: DSH_NODE_MIN env override,
    /// else 22.0.0 — empirically what dsh rc.6 needs (zstd ESM exports in
    /// node:zlib, Promise.withResolvers, node:module.stripTypeScriptTypes; all
    /// present in Node ≥ 22, missing in 20). The bundled runtime (v24 LTS) is
    /// the fallback below this.
    private var minSystemNodeVersion: String {
        let env = ProcessInfo.processInfo.environment
        if let m = env["DSH_NODE_MIN"], !m.isEmpty {
            return m.replacingOccurrences(of: "v", with: "", options: [.anchored])
        }
        return "22.0.0"
    }

    /// Lightweight x.y.z compare (-1/0/1). Deliberately NOT routed through
    /// CoreBridge (which calls resolveNode — would recurse).
    private func compareNodeVersions(_ a: String, _ b: String) -> Int {
        func nums(_ s: String) -> [Int] {
            let core = s.replacingOccurrences(of: "v", with: "", options: [.anchored]).split(separator: "-")[0]
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = nums(a), pb = nums(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Preferred `node`: explicit DSH_NODE override, else the first OS-installed
    /// node, else the bundled runtime. ServerManager.start() retries with the
    /// bundled runtime when an OS node fails to boot dsh web — the bundled
    /// node only guarantees that dsh web starts.
    func resolveNode() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let p = env["DSH_NODE"], fm.isExecutableFile(atPath: p) { return p }
        if let p = resolveSystemNode() { return p }
        return bundledNode()
    }

    /// Best-effort PATH from a login shell, so dsh web's bash sees the user's
    /// tools (nvm bins, ~/.local/bin, …). Finder-launched apps inherit a
    /// minimal PATH from launchd; a login shell reproduces what the user would
    /// get in a terminal. Read once and cached; nil on failure/timeout (the
    /// caller then keeps the inherited PATH). Nothing bundled is injected.
    private static var cachedLoginShellPath: String?
    private func loginShellPath() -> String? {
        if let cached = ServerManager.cachedLoginShellPath { return cached }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-ilc", "print -r -- \"$PATH\""]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        var result: String?
        do {
            try proc.run()
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                result = String(data: data, encoding: .utf8)?
                    .split(separator: "\n").last.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                sem.signal()
            }
            if sem.wait(timeout: .now() + 8) == .timedOut {
                proc.terminate()
                proc.waitUntilExit()
                AppLog.shared.log("login shell PATH read timed out; keeping inherited PATH")
                return nil
            }
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard let result, !result.isEmpty else { return nil }
        ServerManager.cachedLoginShellPath = result
        AppLog.shared.log("dsh web PATH from login shell: \(result.count) chars")
        return result
    }

    /// Locate `dsh`'s entry script (lib/bin.js): bundled runtime first, then
    /// npx cache, global installs, or PATH — newest wins.
    func resolveDSHBin() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let p = env["DSH_CLI"], fm.fileExists(atPath: p) { return p }
        if let p = bundledDSHBin(), fm.fileExists(atPath: p) { return p }
        let home = NSHomeDirectory()
        var candidates: [String] = []

        let npxRoot = home + "/.npm/_npx"
        if let hashes = try? fm.contentsOfDirectory(atPath: npxRoot) {
            for h in hashes {
                let p = npxRoot + "/" + h + "/node_modules/@deepseek-ai/dsh/lib/bin.js"
                if fm.fileExists(atPath: p) { candidates.append(p) }
            }
        }
        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            for v in versions {
                let p = nvmRoot + "/" + v + "/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
                if fm.fileExists(atPath: p) { candidates.append(p) }
            }
        }
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                let shim = String(dir) + "/dsh"
                if fm.isExecutableFile(atPath: shim) {
                    let target = (try? fm.destinationOfSymbolicLink(atPath: shim)) ?? shim
                    let full = target.hasPrefix("/") ? target : (String(dir) + "/" + target)
                    let std = URL(fileURLWithPath: full).standardizedFileURL.path
                    if fm.fileExists(atPath: std) { candidates.append(std) }
                }
            }
        }
        return candidates.sorted(by: { mtime($0) > mtime($1) }).first
    }

    /// Re-read the resolved runtime facts (used by the About panel; call
    /// again after an upgrade, or after the server settles on a node so the
    /// panel reflects the node dsh web actually runs on).
    func refreshFacts(node actual: String? = nil) {
        if let node = actual ?? resolveNode(), let bin = resolveDSHBin() {
            runtimeSource = (bin == bundledDSHBin()) ? L10n.tr("fact.bundled") : L10n.tr("fact.system")
            dshVersion = readPackageVersion(bin: bin) ?? L10n.tr("fact.unknown")
            nodeVersion = nodeVersionString(nodePath: node) ?? L10n.tr("fact.unknown")
            nodePath = node
            AppLog.shared.log("runtime facts: source=\(runtimeSource) dsh=\(dshVersion) node=\(nodeVersion) path=\(node)")
        } else {
            runtimeSource = L10n.tr("fact.unknown")
            dshVersion = L10n.tr("fact.unknown")
            nodeVersion = L10n.tr("fact.unknown")
            nodePath = L10n.tr("fact.unknown")
        }
    }

    /// Read the `version` field from the package.json next to a bin.js.
    private func readPackageVersion(bin: String) -> String? {
        let pkg = URL(fileURLWithPath: bin)
            .deletingLastPathComponent() // lib
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent("package.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pkg)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = json["version"] as? String else { return nil }
        return v
    }

    /// Run `<node> --version` and return its output (e.g. "v22.23.2").
    private func nodeVersionString(nodePath: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ensure a DSH web server is reachable. Reuses an existing one on the
    /// default port, otherwise spawns `dsh web` and waits for it.
    func start() throws -> URL {
        let env = ProcessInfo.processInfo.environment

        // Resolve runtime facts first — the About panel shows them even when
        // the app reuses an already-running server instead of spawning one.
        refreshFacts()

        // 1. Reuse an already-running dsh web (e.g. started by the harness CLI).
        //    DSH_NATIVE_FORCE_SPAWN=1 skips reuse (testing / dedicated instance).
        if env["DSH_NATIVE_FORCE_SPAWN"] != "1" && isDSHServing(port: 3080) {
            spawned = false
            AppLog.shared.log("reusing existing dsh web on 127.0.0.1:3080")
            entryURL = URL(string: "http://127.0.0.1:3080")
            return entryURL!
        }
        // dsh >= 0.1.2 mints a random per-process launch token and answers 401 to a
        // bare GET, so an externally started instance cannot be adopted (its token
        // never leaves its own stdout). Spawn our own instead: same DSH_HOME ⇒ same
        // workspaces/sessions/settings (docs/dsh-version-impact.md, R2).
        if env["DSH_NATIVE_FORCE_SPAWN"] != "1" && isDSHAuthenticated(port: 3080) {
            AppLog.shared.log("existing dsh web on 3080 wants its launch token (dsh 0.1.2+); not adopting — starting our own instance (same DSH_HOME ⇒ same data)")
        }

        // 2. Pick the port (env override for testing, otherwise 3080, else a free port).
        var port = 3080
        if let p = env["DSH_NATIVE_PORT"], let n = Int(p) { port = n }
        if !isPortFree(port) { port = freePort() }
        self.port = port

        // 3. Resolve the dsh entry and the preferred node. The bundled runtime
        //    is only a safety net: any OS-installed node is tried first, and
        //    DSH_NODE (explicit override) always wins.
        guard let bin = resolveDSHBin() else {
            throw NSError(domain: "DSHShell", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.tr("err.noDSH")])
        }
        let explicitNode = env["DSH_NODE"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        let bundled = bundledNode()
        let system = resolveSystemNode()
        let firstNode = explicitNode ?? system ?? bundled
        guard let firstNode else {
            throw NSError(domain: "DSHShell", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("err.noNode")])
        }
        AppLog.shared.log("using node=\(firstNode) dsh=\(bin) port=\(port) system=\(system ?? "-") bundled=\(bundled ?? "-")")

        // 4. Spawn `node <bin> web --no-open --port <port>`. The shell renders
        //    the UI in its own window, so dsh web must not also hand the URL to
        //    the default browser (dsh web opens it unless --no-open is passed).
        //    If the chosen OS node fails to boot dsh web (exits early or never
        //    serves in time), retry once with the bundled runtime. DSH_NODE is
        //    explicit — no fallback.
        let logPath = NSHomeDirectory() + "/Library/Logs/oh-my-dsh/server.log"
        var attempt: String? = firstNode
        while let node = attempt {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: node)
            proc.arguments = [bin, "web", "--no-open", "--port", String(port)]

            var penv = env
            // Merge the login-shell PATH (read once) so dsh web's bash sees
            // the user's tools — nvm bins, ~/.local/bin, etc. Finder-launched
            // apps inherit a minimal launchd PATH. Nothing bundled is injected
            // here, and on failure the inherited PATH is kept unchanged.
            if let login = loginShellPath(), !login.isEmpty { penv["PATH"] = login }
            if penv["DSH_HOME"] == nil { penv["DSH_HOME"] = NSHomeDirectory() + "/.dsh" }
            proc.environment = penv
            proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

            FileManager.default.createFile(atPath: logPath, contents: nil)
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                proc.standardOutput = fh
                proc.standardError = fh
            }

            do { try proc.run() } catch {
                throw NSError(domain: "DSHShell", code: 3, userInfo: [NSLocalizedDescriptionKey: L10n.tr("err.spawnFailed", error.localizedDescription)])
            }
            process = proc
            spawned = true

            // 5. Poll until the UI is served. dsh web (since 0.1.2-rc.1) prints the
            //    address it is serving on, including its per-instance token, e.g.
            //    "dsh web: http://127.0.0.1:<port>/?token=...". We load exactly that
            //    advertised URL so token-auth'd dsh works; for versions that don't
            //    print one we fall back to the legacy __DSH_BOOT__ probe.
            var servedURL: URL?
            var failed = false
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline && !failed {
                if let advertised = servedEntryURL(logPath: logPath, port: port) {
                    // Settle: require the process to still be alive a moment later
                    // (a too-old node can briefly serve then crash while loading the
                    // plugin tree).
                    Thread.sleep(forTimeInterval: 1.0)
                    if proc.isRunning {
                        servedURL = advertised
                        break
                    }
                    failed = true
                } else if isDSHServing(port: port, timeout: 1) {
                    Thread.sleep(forTimeInterval: 1.0)
                    if proc.isRunning && isDSHServing(port: port, timeout: 1) {
                        servedURL = URL(string: "http://127.0.0.1:\(port)")!
                        break
                    }
                    failed = true
                }
                if !proc.isRunning { failed = true }
                if !failed { Thread.sleep(forTimeInterval: 0.5) }
            }
            if let servedURL = servedURL, proc.isRunning {
                refreshFacts(node: node)
                entryURL = servedURL
                AppLog.shared.log("dsh web is up on \(servedURL.absoluteString) (node=\(node))")
                return servedURL
            }
            failed = true

            if failed, node != explicitNode, let bundled, node != bundled {
                // OS node failed to boot dsh web; the bundled runtime is the
                // guarantee that the app starts.
                proc.terminate()
                AppLog.shared.log("node \(node) failed to start dsh web; retrying with bundled \(bundled)")
                attempt = bundled
                continue
            }

            proc.terminate()
            spawned = false
            process = nil
            if failed {
                let tail = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
                let last = tail.split(separator: "\n").suffix(5).joined(separator: "\n")
                throw NSError(domain: "DSHShell", code: 4, userInfo: [NSLocalizedDescriptionKey: L10n.tr("err.exited", last)])
            }
            throw NSError(domain: "DSHShell", code: 5, userInfo: [NSLocalizedDescriptionKey: L10n.tr("err.timeout", logPath)])
        }
        throw NSError(domain: "DSHShell", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("err.noNode")])
    }

    /// Stop the server we spawned. Never touches a server we did not spawn.
    /// Waits briefly for a graceful exit, then escalates to SIGKILL.
    func stop() {
        guard spawned, let proc = process else { return }
        AppLog.shared.log("stopping spawned dsh web (pid \(proc.processIdentifier))")
        proc.terminate()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && proc.isRunning {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            AppLog.shared.log("dsh web did not exit in time; SIGKILL sent")
        } else {
            AppLog.shared.log("dsh web exited cleanly")
        }
        spawned = false
    }
}

// MARK: - Shared host RPC (project directory)

/// The shell's shared notion of the active project directory. It follows the
/// session the user is currently viewing in dsh web (see the dshSession
/// message handler): switching to a session under another workspace re-roots
/// the preview tree, the terminal's start directory and the wiki root.
enum ProjectDirectory {
    static var current: String?
    static func set(_ path: String) {
        let std = (path as NSString).standardizingPath
        if current != std {
            current = std
            AppLog.shared.log("project directory set: \(std)")
        }
    }
}

/// Resolve the active dsh session's working directory via the host RPC
/// (same protocol the web client uses: HTTP POST /api/session.list with a
/// `client-request` envelope). Used by the preview panel's project tree, the
/// terminal panel's session start directory and the wiki root.
enum DSHSessionRPC {
    /// dsh 0.1.2+ persists workspaces (path + member sessions) under
    /// $DSH_HOME/storages/workspace.json. Read it to recover a session's project
    /// directory without the live API. That layout is PRIVATE to dsh, so the read
    /// goes through DshWorkspaceStore (domain name/version gate + diagnostic log)
    /// instead of parsing the file a third time. With a sessionId, returns the path
    /// of a workspace containing it; otherwise the most recently updated existing one.
    static func persistedWorkspacePath(sessionId: String?) -> String? {
        let items = DshWorkspaceStore.persistedItems(log: { AppLog.shared.log($0) })
        let fm = FileManager.default
        func existingPath(_ item: [String: Any]) -> String? {
            guard let path = item["path"] as? String, !path.isEmpty,
                  fm.fileExists(atPath: path) else { return nil }
            return path
        }
        func updatedAt(_ item: [String: Any]) -> String { (item["updatedAt"] as? String) ?? "" }
        if let sid = sessionId, !sid.isEmpty {
            let hit = items
                .filter { ($0["sessionIds"] as? [String])?.contains(sid) == true }
                .compactMap { item -> ([String: Any], String)? in
                    guard let path = existingPath(item) else { return nil }
                    return (item, path)
                }
                .max { updatedAt($0.0) < updatedAt($1.0) }
            if let path = hit?.1 { return path }
        }
        return items
            .compactMap { item -> ([String: Any], String)? in
                guard let path = existingPath(item) else { return nil }
                return (item, path)
            }
            .max { updatedAt($0.0) < updatedAt($1.0) }?.1
    }

    /// Query the session list and pick the most relevant session's working
    /// directory — running sessions first, then the most recently updated
    /// non-blank one. Blocks on a background caller; nil when unresolved.
    /// Works on both dsh API generations (see DshWebRPC): on dsh >= 0.1.2 the live
    /// call needs the launch-token cookie, and a nil result still falls back to the
    /// persisted workspace store.
    static func fetchActiveSessionCwd(port: Int, timeout: TimeInterval = 6) -> String? {
        var result: String?
        if let value = DshWebRPC.call(DshWebRPC.sessionList, [:], port: port, timeout: timeout),
           let items = value["items"] as? [[String: Any]] {
            // Ignore throwaway sessions whose working dir lives under the system
            // temp folder (e.g. leftover `chan-e2e-*` dirs from channel E2E tests)
            // so the terminal never defaults into them. If every candidate is
            // temp-only, return nothing and let the caller fall back to home.
            let tmpPrefix = FileManager.default.temporaryDirectory.standardizedFileURL.path
            let real = items.compactMap { session -> [String: Any]? in
                guard (session["blank"] as? Bool) != true,
                      let cwd = session["cwd"] as? String,
                      !(cwd as NSString).standardizingPath.hasPrefix(tmpPrefix) else { return nil }
                return session
            }
            let running = real.filter { ($0["running"] as? Bool) == true }
            let pool = running.isEmpty ? real : running
            result = pool
                .sorted { ($0["updatedAt"] as? Double ?? 0) > ($1["updatedAt"] as? Double ?? 0) }
                .first?["cwd"] as? String
        }
        // No token / older-method-less server: fall back to the persisted store.
        if result == nil { result = persistedWorkspacePath(sessionId: nil) }
        return result
    }

    /// The working directory of one specific session (session list lookup by
    /// id) — used to follow the session the user just opened in dsh web.
    static func fetchSessionCwd(port: Int, sessionId: String, timeout: TimeInterval = 6) -> String? {
        var result: String?
        if let value = DshWebRPC.call(DshWebRPC.sessionList, [:], port: port, timeout: timeout),
           let items = value["items"] as? [[String: Any]] {
            result = items.first { ($0["sessionId"] as? String) == sessionId }?["cwd"] as? String
        }
        // Fall back to the persisted workspace store, mapping the session id to
        // its containing workspace.
        if result == nil { result = persistedWorkspacePath(sessionId: sessionId) }
        return result
    }

    /// Resolve on a background queue, then call the completion on the main
    /// queue (nil when unresolved). Prefers the shared `ProjectDirectory`
    /// (kept in sync with the session the user is viewing); falls back to a
    /// live `session.list` query and caches its result.
    static func resolveProjectDirectory(port: Int, timeout: TimeInterval = 6,
                                        completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let current = ProjectDirectory.current,
               FileManager.default.fileExists(atPath: current) {
                DispatchQueue.main.async { completion(current) }
                return
            }
            let cwd = fetchActiveSessionCwd(port: port, timeout: timeout)
            DispatchQueue.main.async {
                if let cwd = cwd { ProjectDirectory.set(cwd) }
                completion(cwd)
            }
        }
    }
}

// MARK: - App delegate

/// 关闭页签时 CEF（窗口化模式）会关闭宿主主窗口 → AppKit 误判
/// "last window closed" 而退出。此标记在 CEF 关闭浏览器期间有效，
/// applicationShouldTerminate 据此取消退出并恢复主窗口。
var g_cefClosingWindow = false

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                         WKScriptMessageHandler, NSSplitViewDelegate, NSWindowDelegate {

    private let server = ServerManager()
    private var didSpawnServer = false
    private var autoUpgradeMenuItem: NSMenuItem!
    /// "Check & Upgrade dsh…" menu item (⌘U) — greyed out while an upgrade is
    /// busy so the user cannot start a manual check concurrently.
    private var checkUpgradeMenuItem: NSMenuItem!
    // Stepwise / staged upgrade state: at most one check→download→apply flow
    // runs at a time; upgradeCancelToken lets the user abort an in-flight
    // download before the final (confirmed) in-place install.
    private var upgradeInFlight = false {
        didSet { refreshCheckUpgradeEnabled() }
    }
    /// True while an AUTO round is actively running its background detection /
    /// download. Keeps "Check & Upgrade dsh" greyed out so it cannot be
    /// clicked mid auto-upgrade. (Manual rounds grey it via upgradeInFlight.)
    private var autoUpgradeRunning = false {
        didSet { refreshCheckUpgradeEnabled() }
    }
    private var upgradeCancelToken: UpgradeCancelToken?
    /// Auto-upgrade "remind me later" timer (scheduled when the user defers an
    /// auto offer; fires scheduleAutoUpgradeIfNeeded again after ~2h).
    private var autoUpgradeReminderTimer: Timer?
    /// Keep "Check & Upgrade dsh" enabled only when nothing upgrade-related is
    /// running (auto round or an in-flight download/apply).
    private func refreshCheckUpgradeEnabled() {
        checkUpgradeMenuItem?.isEnabled = !(autoUpgradeRunning || upgradeInFlight)
    }
    /// Where a check→download→apply round was started (drives how "Later" and
    /// the throttle behave).
    enum UpgradeOrigin { case manual, auto }
    /// Test hook: when DSH_AUTO_UPGRADE_NOW=1, the auto-upgrade runs on every
    /// launch (throttle ignored) and never writes a next-run timestamp, so the
    /// flow can be exercised repeatedly without clearing UserDefaults.
    private var forceAutoUpgradeNow: Bool {
        ProcessInfo.processInfo.environment["DSH_AUTO_UPGRADE_NOW"] == "1"
    }
    private var previewToggleMenuItem: NSMenuItem?
    private var terminalToggleMenuItem: NSMenuItem?
    private var wikiToggleMenuItem: NSMenuItem?
    private var tasksToggleMenuItem: NSMenuItem?
    /// The three View → Appearance menu items (system/light/dark), so their
    /// checkmarks stay in sync with AppTheme.current.
    private var appearanceMenuItems: [NSMenuItem] = []
    private var browserToggleMenuItem: NSMenuItem?
    private var channelToggleMenuItem: NSMenuItem?
    private var reviewToggleMenuItem: NSMenuItem?
    /// Activity-bar entries (leftmost icon strip).
    private var previewBarButton: ActivityBarButton!
    private var closeTabMenuItem: NSMenuItem?
    private var terminalBarButton: ActivityBarButton!
    private var wikiBarButton: ActivityBarButton!
    private var tasksBarButton: ActivityBarButton!
    private var browserBarButton: ActivityBarButton!
    private var channelBarButton: ActivityBarButton!
    private var reviewBarButton: ActivityBarButton!

    private var window: NSWindow!
    private var webView: WKWebView!
    private var splitView: NSSplitView!
    private var previewPanel: FilePanelController!
    private var terminalPanel: TerminalPanelController!
    private var wikiPanel: WikiPanelController!
    private var tasksPanel: IssueRunnerPanelController!
    private var browserPanel: BrowserPanelController!
    private var channelPanel: ChannelPanelController!
    private var reviewPanel: ReviewPanelController!
    /// Browser panel localhost REST API (Agent / user curl). Runs from launch.
    private var browserAPIServer: BrowserAPIServer!
    private var browserAPIBridge: BrowserAPIBridge!
    /// CEF 消息泵定时器（external_message_pump 模式需要周期性驱动）。
    private var cefPumpTimer: Timer?

    /// Which panel occupies the right-side slot (none = hidden). The preview,
    /// terminal, wiki, tasks and browser panels share one slot; the activity
    /// bar toggles between them, and they are mutually exclusive.
    enum RightPanel { case none, preview, terminal, wiki, tasks, browser, channel, review }
    private var rightPanel: RightPanel = .none
    /// Re-entrancy guard for window widening (see ensureWebViewWidth).
    private var isWideningWindow = false
    /// True while the right panel is being laid out programmatically (panel
    /// switch / width application). The divider resize callback must NOT save
    /// the width then — only a genuine user drag updates the saved width,
    /// otherwise a programmatic re-layout would clobber it with the default.
    private var isProgrammaticPanelLayout = false
    /// Minimum web-view width. dsh web auto-collapses its left sidebar below
    /// its LG breakpoint (1024pt); keeping the web view at 1100pt leaves a
    /// comfortable margin so the sidebar never folds away.
    private let minWebViewWidth: CGFloat = 1100
    /// **Minimum** allowed width of the right panel slot. 560 is a comfortable
    /// reading floor; a panel's own minimum (300/260) is never higher, but we
    /// still take the max so a panel can raise the floor if it ever needs to.
    private static let rightPanelMinWidth: CGFloat =
        max(560,
            max(FilePanelController.minWidth,
                max(TerminalPanelController.minWidth,
                    max(WikiPanelController.minWidth,
                        max(IssueRunnerPanelController.minWidth,
                            max(BrowserPanelController.minWidth,
                                max(ChannelPanelController.minWidth, ReviewPanelController.minWidth)))))))
    /// *Initial* panel width when the user has never chosen one. The user's
    /// saved/dragged width always wins (clamped to the minimum above); this is
    /// only the first-run width. Deliberately NOT window-relative: a "half the
    /// window" default made the width chase the window, flip-flopping on toggle.
    private static let rightPanelDefaultWidth: CGFloat = 560
    /// Width of the activity bar (leftmost/rightmost icon strip).
    private let activityBarWidth: CGFloat = 48

    // Status overlay (shown while the server boots / on errors)
    private var statusView: NSView!
    private var statusLabel: NSTextField!
    private var statusSpinner: NSProgressIndicator!
    private var retryButton: NSButton!

    // MARK: Lifecycle

    /// QA 调试开关：--ui-debug 参数（open --args 场景）或 DSH_UI_DEBUG 环境变量。
    /// 启用后打开浏览器面板并在面板渲染后 dump 视图层级 + 截图。
    private var uiDebug: Bool {
        ProcessInfo.processInfo.environment["DSH_UI_DEBUG"] == "1" ||
        CommandLine.arguments.contains("--ui-debug")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.shared.log("launch: didFinishLaunching begin (NSApp=\(NSStringFromClass(type(of: NSApp))))")
        // 单实例约束：两个 App 副本共用同一 CEF 用户数据目录（~/.dsh/browser），
        // 同时启动会让 Chromium 争抢同一 profile、互相异常终止（表现为
        // "Chromium didn't shut down correctly."）。若已有其他实例在跑，聚焦它并
        // 立即退出本实例（本检查在最前，此时尚未拉起 dsh web / CEF / channel，
        // 直接 exit 无副作用、也不会碰共享 profile）。开发版（isDevBuild）已用独立
        // CEF profile，可与正式版并存，故跳过单实例退出。
        if !isDevBuild,
           let bundleId = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            AppLog.shared.log("single-instance: another instance running (pid \(existing.processIdentifier)); activating & exiting")
            existing.activate(options: [.activateAllWindows])
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        // 开发版隔离（独立实例 + 独立 DSH_HOME + 错开端口）必须在任何配置读取
        // （L10n/AppTheme/Registry 走 ShellConfig = $DSH_HOME/shell/config.json）与
        // dsh web / CEF / skills / channel 启动之前注入环境变量。
        applyDevIsolation()
        // Snapshot the real system language BEFORE overriding AppleLanguages.
        L10n.captureSystemLang()
        // Make the WebView's navigator.language follow the shell language so
        // the dsh web page UI matches (dsh web defaults to browser language).
        UserDefaults.standard.set([L10n.isZh ? "zh-CN" : "en-US"], forKey: "AppleLanguages")
        // Apply the persisted appearance before any window is created, so the
        // first frame already uses the right theme (no flash of the default).
        AppTheme.apply()
        installSignalHandlers()
        buildMenu()
        AppLog.shared.log("launch: menu built")
        // Provision built-in skills into the global dsh home before dsh web starts,
        // so the agent can discover them in any workspace. Best-effort; never blocks.
        SkillInstaller.installBuiltinSkills()
        buildWindow()
        AppLog.shared.log("launch: window built")
        AppLog.shared.log("app did finish launching (lang=\(L10n.lang) followSystem=\(!L10n.hasExplicitChoice) AppleLanguages=\(UserDefaults.standard.array(forKey: "AppleLanguages") ?? []))")
        startServer()
        startCEF()
        startBrowserAPIServer()
        // Channel runners start once the server is up (see startServer): they
        // need its actual port and, on dsh 0.1.2+, its advertised launch token.
        showOnboardingIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Route SIGTERM/SIGINT/SIGHUP (kill, logout, system shutdown) through the
    /// normal quit path so the spawned server is always cleaned up.
    private func installSignalHandlers() {
        signal(SIGTERM) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        signal(SIGINT) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        signal(SIGHUP) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 关闭页签时 CEF（窗口化模式）会关闭宿主主窗口 → AppKit 触发
    /// "last window closed" 检查 → 误退出。用标记区分：CEF 引发的退出
    /// 取消并恢复主窗口；用户主动关闭窗口照常退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if g_cefClosingWindow {
            AppLog.shared.log("terminate: cancelled (CEF closing window)")
            if let w = window, !w.isVisible {
                // 延迟恢复：CEF 关闭流程可能异步二次关窗，等它收尾再恢复。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !w.isVisible { w.makeKeyAndOrderFront(nil) }
                }
            }
            return .terminateCancel
        }
        AppLog.shared.log("terminate: applicationShouldTerminate (user-initiated)\n" + Thread.callStackSymbols.prefix(10).joined(separator: "\n"))
        return .terminateNow
    }

    /// 拦截 CEF 误关主窗口（若走 performClose 路径；[window close] 直接关则
    /// 由 applicationShouldTerminate 的恢复兜底）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if g_cefClosingWindow, sender === window {
            AppLog.shared.log("terminate: windowShouldClose blocked (CEF)")
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        let w = notification.object as? NSWindow
        AppLog.shared.log("terminate: windowWillClose title=\(w?.title ?? "?") visible=\(w?.isVisible ?? false)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.shared.log("terminate: begin")
        // Flush any debounced ShellConfig writes before exit.
        ShellConfig.shared.flushNow()
        terminalPanel?.shutdownAll()
        browserPanel?.shutdownAll()
        browserAPIServer?.stop()
        stopChannelRunners()
        cefPumpTimer?.invalidate()
        CEFShim.shutdown()
        if didSpawnServer { server.stop() }
        AppLog.shared.log("terminate: done")
    }

    // MARK: Window

    private func buildWindow() {
        AppLog.shared.log("launch: buildWindow begin")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "oh-my-dsh (DeepSeek Harness)"
        window.contentView = content
        window.delegate = self  // NSWindowDelegate（windowWillClose 诊断 / CEF 误关拦截）
        // Minimum window width keeps the web view ≥ minWebViewWidth even with
        // the panel hidden (activity bar takes activityBarWidth), so shrinking
        // the window can never fold dsh's sidebar away.
        window.minSize = NSSize(width: minWebViewWidth + activityBarWidth, height: 480)
        window.center()
        window.setFrameAutosaveName("oh-my-dshMainWindow")
        window.makeKeyAndOrderFront(nil)

        buildStatusOverlay()
        buildSplitView()
        // Self-test hook (debugging / QA only): opens one or more paths
        // (comma-separated) in the preview panel at launch when
        // DSH_PREVIEW_TEST_PATH is set.
        if let testPath = ProcessInfo.processInfo.environment["DSH_PREVIEW_TEST_PATH"], !testPath.isEmpty {
            for p in testPath.split(separator: ",") where !p.isEmpty {
                previewPanel.open(path: String(p))
            }
            setRightPanel(.preview)
            AppLog.shared.log("preview self-test path: \(testPath)")
        }
        // Terminal self-test hook (debugging / QA only): opens the terminal
        // panel at launch when DSH_TERMINAL_TEST=1 is set.
        if ProcessInfo.processInfo.environment["DSH_TERMINAL_TEST"] == "1" {
            setRightPanel(.terminal)
            AppLog.shared.log("terminal self-test enabled")
        }
        // Wiki self-test hook (debugging / QA only): opens the wiki panel at
        // launch when DSH_WIKI_TEST=1 is set. Optionally point the panel at a
        // fixture wiki root with DSH_WIKI_TEST_PATH=<dir> instead of resolving
        // the active session's project directory.
        if ProcessInfo.processInfo.environment["DSH_WIKI_TEST"] == "1" {
            setRightPanel(.wiki)
            AppLog.shared.log("wiki self-test enabled")
        }
        // Browser self-test hook (debugging / QA only): opens the browser
        // panel at launch when DSH_BROWSER_TEST=1 is set.
        if uiDebug || ProcessInfo.processInfo.environment["DSH_BROWSER_TEST"] == "1" {
            setRightPanel(.browser)
            AppLog.shared.log("browser self-test enabled")
        }
        // Review self-test hook (debugging / QA only): opens the change-audit
        // panel when DSH_REVIEW_TEST=1. Deliberately LAST so it also wins under
        // --ui-debug/DSH_UI_DEBUG=1, whose browser-panel default would otherwise
        // take the slot (and the panel snapshot along with it).
        if ProcessInfo.processInfo.environment["DSH_REVIEW_TEST"] == "1" {
            setRightPanel(.review)
            AppLog.shared.log("review self-test enabled")
        }
    }

    /// Build the activity bar (leftmost icon strip) + the main split view:
    /// WKWebView (middle) + preview panel (right). The preview panel starts
    /// hidden; it expands when a file link is clicked or the bar/menu toggles.
    private func buildSplitView() {
        AppLog.shared.log("launch: buildSplitView begin")
        guard let content = window.contentView else { return }

        previewPanel = FilePanelController()
        AppLog.shared.log("launch: previewPanel created")
        previewPanel.onRequestHide = { [weak self] in self?.setRightPanel(.none) }
        previewPanel.serverPortProvider = { [weak self] in self?.server.port ?? 3080 }
        previewPanel.onTabsChanged = { [weak self] in self?.updateCloseTabMenuState() }

        terminalPanel = TerminalPanelController()
        AppLog.shared.log("launch: terminalPanel created")
        terminalPanel.onRequestHide = { [weak self] in self?.setRightPanel(.none) }
        terminalPanel.serverPortProvider = { [weak self] in self?.server.port ?? 3080 }

        wikiPanel = WikiPanelController()
        AppLog.shared.log("launch: wikiPanel created")
        wikiPanel.onRequestHide = { [weak self] in self?.setRightPanel(.none) }
        wikiPanel.serverPortProvider = { [weak self] in self?.server.port ?? 3080 }
        // The panel can flip the auto-update setting via its first-generation
        // prompt; rebuild the menu so the checkbox stays in sync.
        wikiPanel.onAutoUpdateSettingChanged = { [weak self] in self?.buildMenu() }

        tasksPanel = IssueRunnerPanelController()
        AppLog.shared.log("launch: tasksPanel created")
        tasksPanel.onRequestHide = { [weak self] in self?.setRightPanel(.none) }
        tasksPanel.serverPortProvider = { [weak self] in self?.server.port ?? 3080 }
        tasksPanel.workspacePath = { [weak self] in self?.activeWorkspacePath() }

        browserPanel = BrowserPanelController()
        AppLog.shared.log("launch: browserPanel created")
        browserPanel.onRequestHide = { [weak self] in self?.setRightPanel(.none) }
        channelPanel = ChannelPanelController()
        AppLog.shared.log("launch: channelPanel created")
        channelPanel.onRequestHide = { [weak self] in self?.setRightPanel(.none) }
        channelPanel.workspacePath = { [weak self] in self?.activeWorkspacePath() }
        channelPanel.channelLoginRunner = { [weak self] channelId, onQRUrl, completion in
            self?.runChannelLogin(channelId: channelId, onQRUrl: onQRUrl, completion: completion)
        }
        channelPanel.channelUnbind = { [weak self] channelId in
            self?.unbindChannel(channelId: channelId)
        }
        channelPanel.channelLoginCancel = { [weak self] channelId in
            self?.cancelChannelLogin(channelId: channelId)
        }
        // Panel → web session link: clicking a session's "open in dsh" drives the
        // web view to switch to that session.
        channelPanel.onOpenSession = { [weak self] sessionId in
            self?.openDSHSession(sessionId)
        }

        reviewPanel = ReviewPanelController()
        AppLog.shared.log("launch: reviewPanel created")
        reviewPanel.onRequestHide = { [weak self] in self?.setRightPanel(.none) }
        // Warm the session listing right away (the workspace resolves from dsh's
        // persisted store when the page has not reported a session yet), so
        // opening the panel renders instead of waiting on the core CLI.
        reviewPanel.prewarm()
        // QA (--ui-debug): snapshot the panel again once it has rendered data.
        reviewPanel.onDidRender = { [weak self] in
            guard let self = self, self.uiDebug else { return }
            self.dumpPanelDebugInfo(panelView: self.reviewPanel.view, label: "review-loaded")
        }
        // QA hook: DSH_REVIEW_TEST_PATH points the audit at a fixed workspace
        // (mirrors DSH_PREVIEW_TEST_PATH / DSH_WIKI_TEST_PATH).
        reviewPanel.workspacePath = { [weak self] in
            if let override = ProcessInfo.processInfo.environment["DSH_REVIEW_TEST_PATH"], !override.isEmpty {
                return override
            }
            return self?.activeWorkspacePath()
        }

        // --- leftmost activity bar (icon entries; extensible) ---
        // DynamicFillView keeps the strip's background following light/dark
        // (a fixed CGColor layer background would not).
        let activityBar = DynamicFillView()
        activityBar.kind = .control
        activityBar.translatesAutoresizingMaskIntoConstraints = false

        // 活动栏图标：tooltip 跟随系统语言（L10n 中英切换）；
        // 顺序 = 文件、终端、浏览器、Wiki、任务。
        previewBarButton = makeActivityButton(symbol: "doc.on.doc",
                                              tooltip: L10n.tr("bar.preview"),
                                              action: #selector(togglePreviewPanel(_:)))
        terminalBarButton = makeActivityButton(symbol: "terminal",
                                               tooltip: L10n.tr("bar.terminal"),
                                               action: #selector(terminalEntryTapped(_:)))
        browserBarButton = makeActivityButton(symbol: "globe",
                                              tooltip: L10n.tr("bar.browser"),
                                              action: #selector(browserEntryTapped(_:)))
        wikiBarButton = makeActivityButton(symbol: "book.closed",
                                           tooltip: L10n.tr("bar.wiki"),
                                           action: #selector(wikiEntryTapped(_:)))
        tasksBarButton = makeActivityButton(symbol: "checkmark.circle",
                                            tooltip: L10n.tr("bar.tasks"),
                                            action: #selector(tasksEntryTapped(_:)))
        channelBarButton = makeActivityButton(symbol: "dot.radiowaves.left.and.right",
                                              tooltip: L10n.tr("bar.channel"),
                                              action: #selector(channelEntryTapped(_:)))
        reviewBarButton = makeActivityButton(symbol: "doc.text",
                                             tooltip: L10n.tr("bar.review"),
                                             action: #selector(reviewEntryTapped(_:)))
        let barStack = NSStackView(views: [previewBarButton, terminalBarButton, browserBarButton, wikiBarButton, tasksBarButton, channelBarButton, reviewBarButton])
        barStack.orientation = .vertical
        barStack.alignment = .centerX
        barStack.spacing = 6
        barStack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        barStack.translatesAutoresizingMaskIntoConstraints = false
        activityBar.addSubview(barStack)
        NSLayoutConstraint.activate([
            barStack.topAnchor.constraint(equalTo: activityBar.topAnchor),
            barStack.leadingAnchor.constraint(equalTo: activityBar.leadingAnchor),
            barStack.trailingAnchor.constraint(equalTo: activityBar.trailingAnchor),
        ])

        content.addSubview(activityBar, positioned: .below, relativeTo: statusView)

        splitView = NSSplitView(frame: content.bounds)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(splitView, positioned: .below, relativeTo: statusView)
        NSLayoutConstraint.activate([
            // Activity bar on the right edge (next to the preview panel).
            activityBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            activityBar.topAnchor.constraint(equalTo: content.topAnchor),
            activityBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            activityBar.widthAnchor.constraint(equalToConstant: 48),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: activityBar.leadingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        AppLog.shared.log("launch: activity bar + split view ready")
        rebuildWebView() // creates the WKWebView and adds it as the left pane
        AppLog.shared.log("launch: webview ready")

        // The right slot is the ACTIVE panel's view mounted DIRECTLY as the
        // split view's second pane (the arrangement that rendered reliably
        // for the original preview panel). Swapping = replace subviews[1];
        // hiding = setPosition collapses the pane to zero width. No container,
        // no isHidden, no stacking — each of those visibility tricks failed to
        // re-composite panel content in this layer-backed window.
        AppLog.shared.log("launch: split ready (active panel mounted by setRightPanel)")

        // Restore the last state: "previewPanelState" marks the panel visible
        // (not the legacy "previewPanelVisible" key, which older builds may
        // have left set to true), "rightPanelKind" picks which panel — so a
        // fresh install starts with the panel closed, and only explicit user
        // actions mark it open.
        let visible = ShellConfig.shared.bool(forKey: "previewPanelState")
        let kind: RightPanel
        switch ShellConfig.shared.string(forKey: "rightPanelKind") {
        case "terminal": kind = .terminal
        case "wiki": kind = .wiki
        case "tasks": kind = .tasks
        case "browser": kind = .browser
        case "channel": kind = .channel
        case "review": kind = .review
        default: kind = .preview
        }
        setRightPanel(visible ? kind : .none)
    }

    /// The active panel's root view (preview / terminal / wiki).
    private func activePanelView(_ panel: RightPanel) -> NSView {
        switch panel {
        case .preview: return previewPanel.view
        case .terminal: return terminalPanel.view
        case .wiki: return wikiPanel.view
        case .tasks: return tasksPanel.view
        case .browser: return browserPanel.view
        case .channel: return channelPanel.view
        case .review: return reviewPanel.view
        case .none: return NSView()
        }
    }

    /// A borderless toggle button for the activity bar (hover highlight,
    /// pointing-hand cursor, accent highlight while active). The icon color is
    /// baked into the image (ActivityBarButton) so it stays visible in dark
    /// mode regardless of tint resolution.
    private func makeActivityButton(symbol: String, tooltip: String, action: Selector) -> ActivityBarButton {
        ActivityBarButton(symbol: symbol, tooltip: tooltip, action: action)
    }

    /// Show/hide the preview panel. The panel width is remembered across
    /// sessions (persisted when the divider is dragged / the panel resized).
    /// When called before the window has laid out (bounds width 0) the request
    /// is retried on the next runloop — a setPosition at width 0 is a no-op and
    /// leaves NSSplitView to equal-split the panes ("half-and-half" on launch).
    /// Show/hide the right-side panel slot and pick which panel occupies it
    /// (.preview or .terminal; both hidden when .none). The panel width is
    /// remembered across sessions (persisted when the divider is dragged /
    /// the panel resized). When called before the window has laid out (bounds
    /// width 0) the request is retried on the next runloop — a setPosition at
    /// width 0 is a no-op and leaves NSSplitView to equal-split the panes.
    private func setRightPanel(_ panel: RightPanel) {
        guard let split = splitView else { return }
        if ProcessInfo.processInfo.environment["DSH_PREVIEW_DEBUG"] == "1" {
            AppLog.shared.log("setRightPanel enter: panel=\(panel) win=\(window.frame) split=\(split.bounds) content=\(window.contentView?.bounds ?? .zero) pwSaved=\(ShellConfig.shared.object(forKey: "previewPanelWidth") ?? "nil" as Any)")
        }
        // Wait until Auto Layout has actually laid the split out: its bounds
        // width must be windowWidth - activityBar. Using the pre-layout frame
        // (which equals the window width, or a stale default while the window
        // restores its saved frame) computes a divider position against the
        // wrong total and leaves the panel huge / the web view tiny.
        guard split.bounds.width > 0, window.frame.width > 0 else {
            DispatchQueue.main.async { [weak self] in self?.setRightPanel(panel) }
            return
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let expectedSplitW = window.frame.width - activityBarWidth
        guard abs(split.bounds.width - expectedSplitW) < 2 else {
            DispatchQueue.main.async { [weak self] in self?.setRightPanel(panel) }
            return
        }
        rightPanel = panel
        // The layout work below is programmatic: its divider changes must not be
        // recorded as a user-chosen width (see isProgrammaticPanelLayout).
        isProgrammaticPanelLayout = true
        defer { isProgrammaticPanelLayout = false }
        let visible = panel != .none
        AppLog.shared.log("setRightPanel apply panel=\(panel) splitW=\(split.bounds.width) winW=\(window.frame.width)")
        previewToggleMenuItem?.state = (panel == .preview) ? .on : .off
        terminalToggleMenuItem?.state = (panel == .terminal) ? .on : .off
        wikiToggleMenuItem?.state = (panel == .wiki) ? .on : .off
        tasksToggleMenuItem?.state = (panel == .tasks) ? .on : .off
        browserToggleMenuItem?.state = (panel == .browser) ? .on : .off
        channelToggleMenuItem?.state = (panel == .channel) ? .on : .off
        reviewToggleMenuItem?.state = (panel == .review) ? .on : .off
        previewBarButton?.setActive(panel == .preview)
        terminalBarButton?.setActive(panel == .terminal)
        wikiBarButton?.setActive(panel == .wiki)
        tasksBarButton?.setActive(panel == .tasks)
        browserBarButton?.setActive(panel == .browser)
        channelBarButton?.setActive(panel == .channel)
        reviewBarButton?.setActive(panel == .review)
        // Mount the ACTIVE panel's view directly as the split view's right
        // pane (subviews[1]) — the arrangement that rendered reliably for the
        // original preview panel. Swapping replaces subviews[1]; hiding just
        // collapses its width via the divider below.
        if panel != .none {
            let activeView: NSView = activePanelView(panel)
            if split.subviews.count > 1, split.subviews[1] !== activeView {
                split.subviews[1].removeFromSuperview()
            }
            if !split.subviews.contains(activeView) {
                // Pre-size to the target BEFORE adding: NSSplitView otherwise
                // lays out an equal split on the subview swap, which briefly
                // shrinks the web view below minWebViewWidth (dsh web collapses
                // its sidebar for a frame) before applyRightPanelLayout corrects
                // it. Setting the frame first makes that first layout correct.
                let divider = split.dividerThickness
                let bound = max(split.bounds.width - minWebViewWidth - divider, Self.rightPanelMinWidth)
                let target = min(targetPanelWidth(), bound)
                activeView.frame = NSRect(x: max(0, split.bounds.width - target - divider), y: 0,
                                          width: target, height: split.bounds.height)
                split.addSubview(activeView)
                split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 1)
            }
            activeView.needsLayout = true
            activeView.needsDisplay = true
        }
        if visible {
            applyRightPanelLayout()
            switch panel {
            case .preview:
                // Show the project tree by default whenever the panel opens.
                previewPanel.ensureTreeLoaded()
                if uiDebug {
                    self.dumpPanelDebugInfo(panelView: previewPanel.view, label: "preview")
                }
            case .terminal:
                // Lazily spawn the first terminal session, then focus it.
                terminalPanel.ensureSession()
                DispatchQueue.main.async { [weak self] in self?.terminalPanel.focusActiveTerminal() }
                if uiDebug {
                    self.dumpPanelDebugInfo(panelView: terminalPanel.view, label: "terminal")
                }
            case .wiki:
                wikiPanel.ensureWikiLoaded()
                if uiDebug {
                    self.dumpPanelDebugInfo(panelView: wikiPanel.view, label: "wiki")
                }
            case .tasks:
                tasksPanel.ensureLoaded()
                if uiDebug {
                    self.dumpPanelDebugInfo(panelView: tasksPanel.view, label: "tasks")
                }
            case .browser:
                browserPanel.ensureLoaded()
                if uiDebug {
                    self.dumpPanelDebugInfo(panelView: browserPanel.view, label: "browser")
                }
            case .none:
                break
            case .channel:
                channelPanel.ensureLoaded()
                if uiDebug {
                    self.dumpPanelDebugInfo(panelView: channelPanel.view, label: "channel")
                }
            case .review:
                reviewPanel.ensureLoaded()
                if uiDebug {
                    self.dumpPanelDebugInfo(panelView: reviewPanel.view, label: "review")
                }
            }
        } else {
            split.setPosition(split.bounds.width, ofDividerAt: 0)
            split.adjustSubviews()
        }
        split.adjustSubviews()
        // Force a synchronous layout + display of the newly mounted panel so
        // its content actually draws (defends against stale/empty layer
        // contents after a swap).
        if panel != .none {
            let activeView: NSView = activePanelView(panel)
            window.contentView?.layoutSubtreeIfNeeded()
            activeView.layoutSubtreeIfNeeded()
            activeView.display()
            if uiDebug {
                let content = activeView.subviews.last
                AppLog.shared.log("ui debug: \(panel) after-layout pane=\(activeView.bounds.width)pt header=\(activeView.subviews.first?.frame.width ?? -1)pt content=\(content?.frame.width ?? -1)pt")
                // Re-dump AFTER the forced layout so frames reflect what is
                // actually on screen (the pre-layout dump shows stale widths).
                dumpHierarchy(activeView, label: "\(panel)-post", maxDepth: 4)
            }
        }
        ShellConfig.shared.set(visible, forKey: "previewPanelState")
        let kind: String
        switch panel {
        case .terminal: kind = "terminal"
        case .wiki: kind = "wiki"
        case .tasks: kind = "tasks"
        case .browser: kind = "browser"
        case .channel: kind = "channel"
        default: kind = "preview"
        }
        ShellConfig.shared.set(kind, forKey: "rightPanelKind")
        // Note: the panel width is persisted only while the user drags the
        // divider (splitViewDidResizeSubviews) — never overwrite the user's
        // setting here with a clamped value.
        AppLog.shared.log("right panel \(visible ? "shown(\(panel))" : "hidden") webView≈\(split.bounds.width - (split.subviews.count > 1 ? split.subviews[1].frame.width : 0) - split.dividerThickness)pt panelW≈\(split.subviews.count > 1 ? split.subviews[1].frame.width : 0)pt")
        // Layout may not be settled yet at startup; once the window has laid
        // out, make sure the web view never dips below dsh's sidebar
        // auto-collapse breakpoint (also widens too-narrow windows while the
        // panel is hidden).
        DispatchQueue.main.async { [weak self] in self?.ensureWebViewWidth() }
    }

    /// Diagnostics for the dark-mode / blank-panel reports (DSH_UI_DEBUG=1):
    /// logs the panel's window/layer/appearance state and writes a snapshot
    /// of what the VIEW hierarchy renders to the logs folder.
    private func dumpPanelDebugInfo(panelView: NSView, label: String) {
        dlog("ui debug: \(label) panel inWindow=\(panelView.window != nil) layer=\(panelView.layer != nil) isHidden=\(panelView.isHidden) layerHidden=\(panelView.layer?.isHidden ?? false) frame=\(panelView.frame) windowAppearance=\(String(describing: window.appearance)) effective=\(String(describing: panelView.effectiveAppearance.name)) splitSubviews=\(splitView?.subviews.map { $0 === previewPanel?.view ? "preview" : ($0 === terminalPanel?.view ? "terminal" : "web/other") } ?? [])")
        // Recursive view-hierarchy + frame dump of the panel's top levels, so
        // a "header renders blank" report can be pinned to frames/hierarchy.
        // The review panel renders a 会话→对话→文件→变更 tree, so its dump needs the
        // same depth as the browser panel's own view stack.
        dumpHierarchy(panelView, label: label, maxDepth: (label == "browser" || label.hasPrefix("review")) ? 8 : 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, panelView.window != nil, panelView.bounds.width > 10 else { return }
            guard let rep = panelView.bitmapImageRepForCachingDisplay(in: panelView.bounds) else { return }
            panelView.cacheDisplay(in: panelView.bounds, to: rep)
            let dir = NSHomeDirectory() + "/Library/Logs/oh-my-dsh"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: dir + "/panel-\(label)-debug.png")
                try? png.write(to: url)
                AppLog.shared.log("ui debug: \(label) panel snapshot -> \(url.path) size=\(rep.pixelsWide)x\(rep.pixelsHigh)")
            }
            // Also snapshot the preview panel for comparison.
            if let pv = self.previewPanel?.view, pv.window != nil, pv.bounds.width > 10,
               let rep2 = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) {
                pv.cacheDisplay(in: pv.bounds, to: rep2)
                if let png2 = rep2.representation(using: .png, properties: [:]) {
                    let url2 = URL(fileURLWithPath: dir + "/panel-preview-debug.png")
                    try? png2.write(to: url2)
                    AppLog.shared.log("ui debug: preview panel snapshot -> \(url2.path)")
                }
            }
        }
    }

    /// Recursive frame/hierarchy dump used to pin down blank-header reports.
    /// Includes per-view color info (layer background, and the resolved
    /// icon/label color for the custom-drawn header views) so the preview and
    /// terminal panels can be compared side by side.
    private func dumpHierarchy(_ view: NSView, label: String, indent: String = "", maxDepth: Int) {
        guard maxDepth > 0 else { return }
        var extra = ""
        if let layer = view.layer {
            extra += " layerBg=\(String(describing: layer.backgroundColor))"
        }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if view is HeaderLabel {
            extra += " labelColor=\(dark ? "light(0.78)" : "dark(0.38)")"
        }
        if let cb = view as? CustomIconButton {
            extra += " iconColor=\(dark ? "light(0.9)" : "dark(0.25)") enabled=\(cb.isEnabled)"
        }
        AppLog.shared.log("hier[\(label)]: \(indent)\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue) appearance=\(dark ? "dark" : "light")\(extra)")
        dlog("hier[\(label)]: \(indent)\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue) appearance=\(dark ? "dark" : "light")\(extra)")
        for sub in view.subviews {
            dumpHierarchy(sub, label: label, indent: indent + "  ", maxDepth: maxDepth - 1)
        }
    }

    /// 调试日志：同时写 AppLog 与 stdout（直接运行二进制时可从终端捕获）。
    private func dlog(_ msg: String) {
        AppLog.shared.log(msg)
        print(msg)
    }

    // MARK: 遮挡诊断（QA）

    /// 全窗口层级 JSON + 命中测试 + 窗口/面板截图。
    /// 返回数据由 POST /api/browser/hierarchy 拉取，截图写 /tmp。
    private func dumpBrowserHierarchyJSON() -> [String: Any] {
        var info: [String: Any] = [:]
        DispatchQueue.main.sync {
            guard let window = self.window, let content = window.contentView else { return }
            info["windowFrame"] = NSStringFromRect(window.frame)
            info["contentFrame"] = NSStringFromRect(content.frame)
            // 全窗口清单（排查 CEF 辅助窗口/DevTools 混入导致的误退出）。
            info["allWindows"] = NSApp.windows.map { w -> String in
                "\(type(of: w)) title=\(w.title) visible=\(w.isVisible) frame=\(NSStringFromRect(w.frame))"
            }
            let splits = self.splitView?.subviews.map { sub -> String in
                let wf = sub.window != nil ? NSStringFromRect(sub.convert(sub.bounds, to: nil)) : "no-window"
                return "\(type(of: sub)) \(wf) hidden=\(sub.isHidden)"
            } ?? []
            info["splitPanes"] = splits
            if let panel = self.browserPanel?.view {
                let wf = panel.window != nil ? NSStringFromRect(panel.convert(panel.bounds, to: nil)) : "no-window"
                info["panelFrameInWindow"] = wf
                info["panelHierarchy"] = self.hierarchyJSON(panel, maxDepth: 8)
                if panel.window != nil {
                    let center = NSPoint(x: panel.bounds.midX, y: panel.bounds.midY)
                    let winPt = panel.convert(center, to: nil)
                    let hit = window.contentView?.hitTest(winPt)
                    info["hitAtPanelCenter"] = hit.map { view -> String in
                        let vf = view.window != nil ? NSStringFromRect(view.convert(view.bounds, to: nil)) : "no-window"
                        return "\(type(of: view)) inWindowFrame=\(vf) hidden=\(view.isHidden)"
                    } ?? "nil"
                    info["hitAtPanelCenterPoint"] = NSStringFromPoint(winPt)
                    // 内容区中心（内容容器中央）命中测试
                    if let container = self.browserPanel?.contentContainerView {
                        let c = NSPoint(x: container.bounds.midX, y: container.bounds.midY)
                        let cWin = container.convert(c, to: nil)
                        let cHit = window.contentView?.hitTest(cWin)
                        info["hitAtContentCenter"] = cHit.map { "\(type(of: $0))" } ?? "nil"
                        info["hitAtContentCenterPoint"] = NSStringFromPoint(cWin)
                    }
                }
                self.writeScreenshot(panel, to: "/tmp/panel-browser-shot.png")
            }
            self.writeScreenshot(content, to: "/tmp/window-shot.png")
        }
        return info
    }

    /// 递归视图层级（含 layer 关键属性），JSON 可序列化。
    private func hierarchyJSON(_ view: NSView, maxDepth: Int) -> [String: Any] {
        var d: [String: Any] = [
            "class": String(describing: type(of: view)),
            "frame": NSStringFromRect(view.frame),
            "hidden": view.isHidden,
            "alpha": view.alphaValue,
            "opaque": view.isOpaque,
            "wantsLayer": view.wantsLayer,
        ]
        if let layer = view.layer {
            d["layerFrame"] = NSStringFromRect(layer.frame)
            d["layerZ"] = layer.zPosition
            d["layerHidden"] = layer.isHidden
            d["layerOpacity"] = layer.opacity
            d["layerMasks"] = layer.masksToBounds
            d["layerContents"] = layer.contents != nil
            d["layerBg"] = layer.backgroundColor.map { String(describing: $0) } ?? "nil"
            // 显示树挂接诊断：layer 是否真的挂进窗口 layer 树（superlayer 链）。
            var chain: [String] = []
            var sl = layer.superlayer
            var hop = 0
            while let s = sl, hop < 6 {
                chain.append("\(type(of: s)):\(NSStringFromRect(s.frame))")
                sl = s.superlayer
                hop += 1
            }
            d["layerSuperChain"] = chain
        }
        if maxDepth > 1 {
            d["subviews"] = view.subviews.map { self.hierarchyJSON($0, maxDepth: maxDepth - 1) }
        } else if !view.subviews.isEmpty {
            d["subviews"] = "…(\(view.subviews.count))"
        }
        return d
    }

    /// 把视图当前合成结果存 PNG（等价于屏幕上看到的内容）。
    private func writeScreenshot(_ view: NSView, to path: String) {
        guard view.bounds.width > 10, view.bounds.height > 10,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            dlog("snapshot \(type(of: view)) \(rep.pixelsWide)x\(rep.pixelsHigh) -> \(path)")
        }
    }

    /// The target panel width: the user's dragged width when saved, else the
    /// fixed default (never window-relative).
    private func targetPanelWidth() -> CGFloat {
        if let saved = ShellConfig.shared.object(forKey: "previewPanelWidth") as? NSNumber,
           saved.doubleValue >= Self.rightPanelMinWidth {
            return CGFloat(saved.doubleValue)
        }
        return Self.rightPanelDefaultWidth
    }

    /// THE single place that lays out the right panel: widen the window when
    /// needed (keeping the panel + min web view on screen), then set the
    /// divider so the panel is exactly `targetPanelWidth` wide and the web
    /// view takes the rest. Idempotent — calling it repeatedly yields the
    /// same divider, so toggling panels never changes the widths.
    private func applyRightPanelLayout() {
        guard let split = splitView, rightPanel != .none else { return }
        isProgrammaticPanelLayout = true
        defer { isProgrammaticPanelLayout = false }
        let divider = split.dividerThickness
        let pw = targetPanelWidth()
        let neededW = activityBarWidth + pw + minWebViewWidth + divider
        if window.frame.width < neededW {
            isWideningWindow = true
            widenWindow(to: neededW)
            isWideningWindow = false
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let maxPw = split.bounds.width - minWebViewWidth - divider
        let target = min(pw, max(maxPw, Self.rightPanelMinWidth))
        // Apply without implicit animation so no intermediate frame is shown.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        split.setPosition(split.bounds.width - target - divider, ofDividerAt: 0)
        split.adjustSubviews()
        NSAnimationContext.endGrouping()
        window.contentView?.layoutSubtreeIfNeeded()
        AppLog.shared.log("layout: panel=\(split.subviews.count > 1 ? split.subviews[1].frame.width : 0)pt webView=\(split.bounds.width - (split.subviews.count > 1 ? split.subviews[1].frame.width : 0) - divider)pt")
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // When visible, the right pane keeps a minimum width; when hidden the
        // divider may slide all the way to the edge.
        rightPanel != .none ? splitView.bounds.width - Self.rightPanelMinWidth : splitView.bounds.width
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Keep the web view at least minWebViewWidth wide (dsh collapses its
        // sidebar below 1024pt); on narrow windows the right pane keeps its
        // own minimum instead.
        min(minWebViewWidth, splitView.bounds.width - Self.rightPanelMinWidth - splitView.dividerThickness)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard splitView.subviews.count > 1 else { return }
        guard rightPanel != .none else { return }
        let pw = splitView.subviews[1].frame.width
        if pw >= Self.rightPanelMinWidth && !isProgrammaticPanelLayout {
            ShellConfig.shared.set(pw, forKey: "previewPanelWidth")
        }
        // Auto-hide ONLY when the window is genuinely too narrow for even the
        // minimum panel + web view (user shrank the window) — NOT during
        // transient programmatic states like the launch half-split, which are
        // corrected by applyRightPanelLayout moments later.
        // WebView-priority policy: the panel needs >= rightPanelMinWidth (560)
        // and the web view >= minWebViewWidth (1100). The two together need
        // activityBar + panelMin + webViewMin + divider (~1709pt). When the
        // window is narrower than that both cannot fit, so the panel yields and
        // auto-hides (the web view keeps its minimum).
        let webW = splitView.bounds.width - pw - splitView.dividerThickness
        let requiredW = activityBarWidth + Self.rightPanelMinWidth + minWebViewWidth + splitView.dividerThickness
        if webW < minWebViewWidth && window.frame.width < requiredW {
            AppLog.shared.log("window too narrow for panel(\(Int(Self.rightPanelMinWidth))) + webView(\(Int(minWebViewWidth))): need \(Int(requiredW))pt, have \(Int(window.frame.width))pt; auto-hiding panel")
            setRightPanel(.none)
        }
    }

    /// Ensure the web view stays at least minWebViewWidth wide. When the
    /// panel is visible this re-runs the single layout routine (widening the
    /// window AND re-applying the divider — the divider would otherwise stay
    /// stale and the panel would grow with the window). Called after every
    /// setRightPanel and on layout settle, so the launch "half and half" is
    /// corrected automatically without any toggle.
    private func ensureWebViewWidth() {
        guard let split = splitView,
              split.subviews.count > 1, let win = window else { return }
        if rightPanel != .none {
            applyRightPanelLayout()
        } else if win.frame.width < minWebViewWidth + activityBarWidth {
            isWideningWindow = true
            widenWindow(to: minWebViewWidth + activityBarWidth)
            isWideningWindow = false
            AppLog.shared.log("window widened to keep web view ≥ \(Int(minWebViewWidth))pt")
        }
    }

    /// Grow the window to the given width, clamping width AND position to the
    /// screen's visible frame so the right edge (activity bar) never ends up
    /// off-screen.
    private func widenWindow(to width: CGFloat) {
        guard let win = window else { return }
        let vf = win.screen?.visibleFrame ?? win.frame
        var f = win.frame
        f.size.width = min(width, vf.width)
        // Keep the right edge inside the screen (the activity bar lives there).
        if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width }
        if f.minX < vf.minX { f.origin.x = vf.minX }
        win.setFrame(f, display: true)
    }

    /// Create a fresh WKWebView pinned to the window content (below the status
    /// overlay). A user script injected at document start overrides
    /// `navigator.language`/`navigator.languages` to follow the shell language —
    /// dsh web reads the browser language to pick its UI locale, and WebKit's
    /// own language is fixed at process start (can't be changed at runtime).
    /// The website data store stays shared, so localStorage/cookies/sessions
    /// are preserved across rebuilds.
    ///
    /// A second user script intercepts clicks on dsh web's file links (tool
    /// outputs rendered as `<button class="…fileMention…" title="<path>">`
    /// and the produced-files row `<button title="<path>">` inside
    /// `[data-produced-files-row]`). It blocks the click from reaching the
    /// page's `host.openPath` RPC (which would open the file with the system
    /// default app) and posts the path to the native preview panel instead.
    private func rebuildWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let langTag = L10n.isZh ? "zh-CN" : "en-US"
        let langScript = """
        Object.defineProperty(Navigator.prototype, 'language', { get: () => '\(langTag)', configurable: true });
        Object.defineProperty(Navigator.prototype, 'languages', { get: () => ['\(langTag)'], configurable: true });
        """
        config.userContentController.addUserScript(
            WKUserScript(source: langScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        config.userContentController.addUserScript(
            WKUserScript(source: Self.previewInterceptorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "dshPreview")

        // Reports the session the user is viewing/interacting with in dsh web
        // (see sessionTrackerScript), so the project directory follows
        // workspace switches.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.sessionTrackerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "dshSession")

        // Panel → web session link: exposes window.__dshOpenSession(sessionId)
        // so the Channel panel can switch dsh web to a specific session.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.sessionOpenerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView?.removeFromSuperview()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // The split view manages the pane frames; plain autoresizing is enough.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]

        guard let split = splitView else { return }
        if split.subviews.first is WKWebView {
            split.subviews[0].removeFromSuperview()
        }
        // Keep the web view as the left pane (insert below the existing pane).
        split.addSubview(webView, positioned: .below, relativeTo: split.subviews.first)
    }

    /// Tracks which dsh session the user is currently viewing / interacting
    /// with. Opening a session or sending a message makes the dsh web client
    /// POST RPCs (callUnary → postJson → window.fetch, same path the preview
    /// interceptor hooks). We parse the request body and post the sessionId
    /// to the shell via the `dshSession` message handler, so the project
    /// directory (preview tree / terminal cwd / wiki root) can follow
    /// workspace switches in dsh web.
    ///
    /// session.history alone is NOT enough: the client's session open() is
    /// idempotent, so revisiting an already-loaded session does not refetch
    /// history. Every session switch DOES run followCurrent →
    /// refreshSubagents(current) → subagent.list { parentSessionId }, which
    /// is non-idempotent — so subagent.list is the reliable per-switch
    /// signal (history/prompt/rename/selectModel are bonus signals).
    /// Only posts when the id changes, to avoid noise.
    private static let sessionTrackerScript = """
    (function () {
      if (window.__dshSessionTracked) return;
      window.__dshSessionTracked = true;
      var origFetch = window.fetch;
      // dsh 0.1.2+ uses slash method names (e.g. subagents/list) and carries
      // the session id under payload.args; keep the legacy dot names/shape too
      // so both client generations are tracked.
      var tracked = {
        'session.history': 1, 'session.prompt': 1, 'session.rename': 1,
        'session.selectModel': 1, 'subagent.list': 1, 'subagents.list': 1,
        'session/history': 1, 'session/prompt': 1, 'session/rename': 1,
        'session/selectModel': 1, 'subagent/list': 1, 'subagents/list': 1
      };
      window.fetch = function (input, init) {
        var url = typeof input === 'string' ? input : (input && (input.href || input.url)) || '';
        if (url.indexOf('/api/') !== -1 && init && init.body) {
          try {
            var body = typeof init.body === 'string' ? JSON.parse(init.body) : null;
            if (body && body.type === 'client-request' && tracked[body.method]
                && body.payload) {
              var a = body.payload.args || {};
              var req = a.request || {};
              var sid = a.parentSessionId || a.agentId || a.sessionId || req.sessionId
                        || body.payload.sessionId || body.payload.parentSessionId;
              if (!window.__dshSessionSeen) window.__dshSessionSeen = [];
              if (window.__dshSessionSeen.length < 100) {
                window.__dshSessionSeen.push(body.method + ':' + (sid || ''));
              }
              if (sid && window.__dshLastTrackedSession !== sid) {
                window.__dshLastTrackedSession = sid;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dshSession) {
                  window.webkit.messageHandlers.dshSession.postMessage({ sessionId: sid });
                }
              }
            }
          } catch (e) {}
        }
        return origFetch.apply(this, arguments);
      };
    })()
    """

    /// Panel → web session link bridge. Exposes window.__dshOpenSession(id)
    /// which switches dsh web to the given session. dsh web does not expose
    /// its session store globally, so we locate the matching sidebar row by
    /// title (resolved via a session.list RPC we fire on demand) and click
    /// it — the same gesture the user performs to switch sessions.
    private static let sessionOpenerScript = """
    (function () {
      if (window.__dshSessionOpener) return;
      window.__dshSessionOpener = true;
      function expandGroups() {
        var groups = Array.prototype.slice.call(document.querySelectorAll('[role="treeitem"]'));
        for (var g = 0; g < groups.length; g++) {
          var r = groups[g];
          if (r.getAttribute("aria-expanded") === "false") r.click();
        }
      }
      function findAndClick(title) {
        var rows = Array.prototype.slice.call(document.querySelectorAll('[role="treeitem"]'));
        for (var i = 0; i < rows.length; i++) {
          if (rows[i].className.indexOf("sessionRow") === -1) continue;
          var lines = (rows[i].innerText || "").split(String.fromCharCode(10)).map(function (s) { return s.trim(); });
          if (lines.indexOf(title) !== -1) { rows[i].click(); return true; }
        }
        return false;
      }
      function openById(sessionId, title, attempt) {
        if (findAndClick(title)) return { ok: true };
        if (attempt < 8) {
          expandGroups();
          return new Promise(function (resolve) {
            setTimeout(function () { resolve(openById(sessionId, title, attempt + 1)); }, 120);
          });
        }
        console.log("[dsh-opener] row-not-found", sessionId, title);
        return { ok: false, reason: "row-not-found" };
      }
      // One session-list call in the shape the RUNNING server expects:
      //   dsh >= 0.1.2 — POST /api/session/list, method = "session/list",
      //                  args wrapped in payload.args._request;
      //   dsh <= 0.1.1 — POST /api/session.list, method = "session.list", payload = args.
      // The two must match (0.1.2 rejects "method does not match endpoint"), and
      // which one is right is only known at runtime — hence the fallback below.
      function fetchSessions(modern) {
        var rpcId = "dsh-open-" + Date.now();
        var req = modern
          ? {
              url: "/api/session/list",
              body: { type: "client-request", rpcId: rpcId, method: "session/list", payload: { args: { _request: {} } } }
            }
          : {
              url: "/api/session.list",
              body: { type: "client-request", rpcId: rpcId, method: "session.list", payload: {} }
            };
        return fetch(req.url, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(req.body)
        }).then(function (res) { return res.json(); }).then(function (json) {
          var ok = json && json.result && json.result.ok && json.result.value;
          var items = (ok && json.result.value.items) || null;
          if (!items) console.log("[dsh-opener] list failed", modern ? "modern" : "legacy", json && json.result && json.result.error && json.result.error.message);
          return items;
        }).catch(function (err) { console.log("[dsh-opener] list error", String(err)); return null; });
      }
      window.__dshOpenSession = function (sessionId) {
        if (!sessionId) return { ok: false, reason: "no-id" };
        return fetchSessions(true).then(function (items) {
          if (items) return items;
          return fetchSessions(false);   // older dsh: dot method surface
        }).then(function (items) {
          items = items || [];
          var target = null;
          for (var i = 0; i < items.length; i++) { if (items[i].sessionId === sessionId) { target = items[i]; break; } }
          if (!target) { console.log("[dsh-opener] no-session", sessionId); return { ok: false, reason: "no-session" }; }
          var title = (target.projections && target.projections.values && target.projections.values.title) || target.sessionId;
          return openById(sessionId, title, 0);
        }).catch(function (err) { console.log("[dsh-opener] error", String(err)); return { ok: false, reason: String(err) }; });
      };
    })()
    """

    /// Interceptor for dsh web's file-open requests. dsh web opens files by
    /// calling the host RPC `host.openPath`, which the client sends as an
    /// HTTP POST to `/api/host.openPath` with body
    /// `{type:"client-request", rpcId, method:"host.openPath", payload:{path}}`
    /// (see @deepseek-ai/dsh-client-connection: callUnary → postJson → doFetch
    /// → globalThis.fetch). Patching `window.fetch` catches EVERY file-open
    /// attempt regardless of which UI element triggered it (produced-file
    /// chips, inline mentions, "show in folder", future surfaces) and yields
    /// the exact absolute path. The request is swallowed and replaced with a
    /// fake successful `server-response`, so the page never opens the system
    /// default app and the client promise resolves cleanly. All other API
    /// calls pass through untouched. Diagnostic flags (DSH_PREVIEW_DEBUG=1)
    /// record install + hits.
    private static let previewInterceptorScript = """
    (function () {
      window.__dshPreviewInstalled = true;
      var origFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = typeof input === 'string' ? input : (input && (input.href || input.url)) || '';
        // dsh 0.1.2+ moved file-open to the session controller RPC
        // session/openWorkspacePath (endpoint /api/session/openWorkspacePath,
        // payload.args.path); match the legacy host.openPath too and accept
        // either payload shape.
        if (url.indexOf('/api/host.openPath') !== -1 || url.indexOf('/openWorkspacePath') !== -1) {
          var body = null;
          try { body = JSON.parse((init && init.body) || '{}'); } catch (e) {}
          var pl = (body && body.payload) || {};
          var args = pl.args || {};
          var req = args.request || {};
          var path = (typeof req.path === 'string') ? req.path
                   : (typeof args.path === 'string') ? args.path
                   : (typeof pl.path === 'string') ? pl.path : null;
          if (path && path.charAt(0) === '/') {
            window.__dshPreviewHit = path;
            try {
              window.webkit.messageHandlers.dshPreview.postMessage({ path: path });
            } catch (err) {}
            return Promise.resolve(new Response(JSON.stringify({
              type: 'server-response',
              rpcId: body.rpcId,
              result: { ok: true, value: { opened: true } }
            }), { status: 200, headers: { 'content-type': 'application/json' } }));
          }
        }
        return origFetch.apply(this, arguments);
      };
    })();
    """

    private func buildStatusOverlay() {
        guard let content = window.contentView else { return }
        statusView = NSView(frame: content.bounds)
        statusView.autoresizingMask = [.width, .height]
        statusView.wantsLayer = true
        statusView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        statusSpinner = NSProgressIndicator()
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .large
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: L10n.tr("status.starting"))
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        retryButton = NSButton(title: L10n.tr("btn.retry"), target: self, action: #selector(retryTapped))
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        statusView.addSubview(statusSpinner)
        statusView.addSubview(statusLabel)
        statusView.addSubview(retryButton)
        NSLayoutConstraint.activate([
            statusSpinner.centerXAnchor.constraint(equalTo: statusView.centerXAnchor),
            statusSpinner.centerYAnchor.constraint(equalTo: statusView.centerYAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: statusSpinner.bottomAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: statusView.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusView.leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusView.trailingAnchor, constant: -40),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            retryButton.centerXAnchor.constraint(equalTo: statusView.centerXAnchor),
        ])
        content.addSubview(statusView, positioned: .above, relativeTo: nil)
    }

    private func showStatus(_ text: String, spinner: Bool, retry: Bool) {
        statusLabel.stringValue = text
        statusSpinner.isHidden = !spinner
        if spinner { statusSpinner.startAnimation(nil) } else { statusSpinner.stopAnimation(nil) }
        retryButton.isHidden = !retry
        statusView.isHidden = false
    }

    private func hideStatus() {
        statusSpinner.stopAnimation(nil)
        statusView.isHidden = true
    }

    // MARK: Server boot

    private func startServer() {
        showStatus(L10n.tr("status.starting"), spinner: true, retry: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let url = try self.server.start()
                let didSpawn = self.server.spawned
                AppLog.shared.log("server ready: \(url.absoluteString) spawned=\(didSpawn)")
                DispatchQueue.main.async {
                    self.didSpawnServer = didSpawn
                    self.webView.load(URLRequest(url: url))
                    // Tell the terminal panel the server is reachable so any
                    // spawn deferred during server boot starts in the
                    // project directory (not ~).
                    self.terminalPanel?.serverReady(port: self.server.port)
                    // Tell the wiki panel too: deferred root loads resolve now.
                    self.wikiPanel?.serverReady(port: self.server.port)
                    // Tell the tasks panel: repo detection + issue load resolve now.
                    self.tasksPanel?.serverReady(port: self.server.port)
                    self.channelPanel?.ensureLoaded()
                    // Native RPC (wiki / issue-runner / session cwd) authenticates
                    // like a browser on dsh 0.1.2+: exchange the advertised launch
                    // token for its cookie once the server is up.
                    DshWebRPC.token = self.server.webToken
                    // Listeners need the actual port + (0.1.2+) the launch token,
                    // both only known once dsh web is up.
                    self.startConfiguredChannelRunners()
                    // Stepwise auto-upgrade (throttled, non-blocking): detect +
                    // background-download a newer dsh, then ask the user before
                    // the in-place install. Deliberately after the server is up
                    // so boot is never delayed by a registry check or download.
                    self.scheduleAutoUpgradeIfNeeded()
                }
            } catch {
                AppLog.shared.log("server start failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.showStatus(L10n.tr("status.startFailed", error.localizedDescription), spinner: false, retry: true)
                }
            }
        }
    }

    /// After a successful dsh upgrade the running dsh web still serves the old
    /// code loaded into memory, so stop the server we spawned and bring dsh web
    /// up again for the newly installed dsh to take effect. A reused external
    /// server can't be restarted — the new dsh applies on next app launch. Also
    /// covers the case where startup previously failed (nothing serving): we
    /// then just start the server with the new code.
    private func restartServerAfterUpgrade() {
        // Stop a server this app spawned — it still runs the pre-upgrade code
        // in memory. If startup previously failed (nothing serving) or the
        // server was reused from outside, there is nothing of ours to stop.
        if server.spawned {
            server.stop()
        }
        // startServer() either reuses an already-serving external server (which
        // we cannot restart — the new dsh applies on next app launch) or spawns
        // a fresh dsh web with the newly installed code, then reloads the
        // WebView on the main thread (re-running the panel server-ready wiring).
        DispatchQueue.main.async {
            self.startServer()
        }
    }

    @objc private func retryTapped() {
        startServer()
    }

    // MARK: dsh upgrade & registry

    func autoUpgradeEnabled() -> Bool {
        if ProcessInfo.processInfo.environment["DSH_AUTO_UPGRADE"] == "0" { return false }
        return ShellConfig.shared.object(forKey: "autoUpgradeDsh") as? Bool ?? true
    }

    /// A DSHUpdater for the active bundled runtime, or nil when dsh is not the
    /// self-contained bundled runtime (auto/manual upgrades only apply there).
    private func currentUpdater() -> DSHUpdater? {
        guard let node = server.resolveNode(), let bin = server.resolveDSHBin(),
              let updater = DSHUpdater(nodePath: node, dshBin: bin) else { return nil }
        return updater
    }

    /// The next STEPWISE upgrade target for \`updater\`: among published stable/rc
    /// versions strictly newer than the installed one, the immediately-next by
    /// semver (never jumps to dist-tags.latest). Chosen in the shared core so
    /// every platform shares the rule; falls back to latest only if core is
    /// unavailable (degraded).
    private func stepTarget(for updater: DSHUpdater) -> String? {
        guard let current = updater.currentVersion else { return nil }
        let versions = updater.publishedVersions(registry: RegistryConfig.current)
        if let t = CoreBridge.nextStepTarget(current: current, versions: versions) {
            return t.isEmpty ? nil : t
        }
        if let latest = updater.latestVersion(registry: RegistryConfig.current),
           VersionKit.compare(latest, current) > 0 { return latest }
        return nil
    }

    /// Persist the next auto-upgrade run time as a delay from now. Only called
    /// when an auto round reaches a terminal outcome — never at the start — so
    /// a brief-session quit before a round completes does not consume the
    /// window and the next launch retries.
    private func deferAutoUpgrade(by delay: TimeInterval) {
        // When force-testing (DSH_AUTO_UPGRADE_NOW=1) leave the throttle alone so
        // every launch re-checks; otherwise persist the next-run delay.
        guard !forceAutoUpgradeNow else { return }
        ShellConfig.shared.set(Date().timeIntervalSince1970 + delay, forKey: "nextAutoUpgradeCheck")
    }

    /// Schedule a main-thread "remind me later" that re-runs the (now due) auto
    /// check. Added to .common so it also fires while a modal alert is up.
    private func remindAutoUpgradeLater(after delay: TimeInterval) {
        autoUpgradeReminderTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.scheduleAutoUpgradeIfNeeded()
        }
        RunLoop.main.add(t, forMode: .common)
        autoUpgradeReminderTimer = t
    }

    /// Auto-upgrade entry, called on the main thread (at boot and on a reminder
    /// timer). Due only once the persisted next-run time has passed. It never
    /// commits that next-run time up front — the next run time is written only
    /// when this round reaches an outcome (up-to-date → +24h; offline/step error
    /// → +2h; offered and deferred → +2h; applied → +24h). A newer step target
    /// is downloaded silently in the background, then the user is asked before
    /// the in-place install.
    private func scheduleAutoUpgradeIfNeeded() {
        guard autoUpgradeEnabled(), !upgradeInFlight else { return }
        let nextAt = ShellConfig.shared.double(forKey: "nextAutoUpgradeCheck")
        guard forceAutoUpgradeNow || Date().timeIntervalSince1970 >= nextAt else { return }
        // Grey out "Check & Upgrade dsh" while this auto round runs.
        autoUpgradeRunning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Resolve on the background thread; every path below brings a single
            // terminal decision back to the main thread so autoUpgradeRunning is
            // always cleared (or carried into the download, which keeps the menu
            // greyed via upgradeInFlight).
            guard let self = self, let updater = self.currentUpdater(),
                  let current = updater.currentVersion else {
                DispatchQueue.main.async { self?.autoUpgradeRunning = false }
                return
            }
            let latest = updater.latestVersion(registry: RegistryConfig.current)
            guard latest != nil else {
                // Registry unreachable — retry shortly instead of burning the day.
                DispatchQueue.main.async {
                    self.autoUpgradeRunning = false
                    self.deferAutoUpgrade(by: 7200)
                    AppLog.shared.log("auto-upgrade: version check failed; will retry (registry=\(RegistryConfig.current))")
                }
                return
            }
            guard let target = self.stepTarget(for: updater) else {
                DispatchQueue.main.async {
                    self.autoUpgradeRunning = false
                    self.deferAutoUpgrade(by: 86_400)
                    AppLog.shared.log("auto-upgrade: up to date (\(current))")
                }
                return
            }
            AppLog.shared.log("auto-upgrade: next step \(current) -> \(target) via \(RegistryConfig.current)")
            DispatchQueue.main.async {
                // self is already non-optional here (bg guard); autoUpgradeRunning
                // stays true and download+apply keep the menu greyed.
                self.startDownloadThenPromptApply(updater: updater, current: current, target: target, origin: .auto)
            }
        }
    }

    /// Download phase shared by manual & auto: background-prefetch \`target\` into
    /// the shared npm cache (the live dsh tree is untouched), then prompt for
    /// the in-place install once the download completes. Runs fully in the
    /// background; only the step-completion prompt is surfaced to the user.
    private func startDownloadThenPromptApply(updater: DSHUpdater, current: String, target: String, origin: UpgradeOrigin) {
        guard !upgradeInFlight else { return }
        upgradeInFlight = true
        autoUpgradeReminderTimer?.invalidate()
        autoUpgradeReminderTimer = nil
        let token = UpgradeCancelToken()
        upgradeCancelToken = token

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var failure: String?
            do {
                _ = try updater.prefetch(registry: RegistryConfig.current, version: target, cancel: token)
            } catch {
                if !token.cancelled { failure = error.localizedDescription }
            }
            AppLog.shared.log("upgrade download \(target): \(failure ?? "ok")")

            DispatchQueue.main.async {
                self.upgradeCancelToken = nil
                if let failure = failure {
                    // Round ends here: re-enable the menu and retry auto shortly.
                    self.upgradeInFlight = false
                    self.autoUpgradeRunning = false
                    if origin == .auto { self.deferAutoUpgrade(by: 7200) }
                    let a = NSAlert()
                    a.messageText = L10n.tr("alert.downloadFailed")
                    a.informativeText = failure
                    a.addButton(withTitle: L10n.tr("btn.ok"))
                    a.runModal()
                    return
                }
                // upgradeInFlight stays true through the install-confirm + apply so
                // the menu remains greyed; it is cleared in offerApply/performApply.
                self.offerApply(updater: updater, current: current, target: target, origin: origin)
            }
        }
    }

    /// Second confirmation (manual & auto): the download finished; ask the user
    /// before replacing the live dsh tree and restarting. "Later" defers an
    /// auto offer by ~2h and schedules a reminder; a manual "Later" just stops
    /// (the user can re-check anytime).
    private func offerApply(updater: DSHUpdater, current: String, target: String, origin: UpgradeOrigin) {
        let a = NSAlert()
        a.messageText = L10n.tr("alert.downloadDone", target)
        a.informativeText = L10n.tr("alert.downloadDoneInfo")
        a.addButton(withTitle: L10n.tr("btn.installNow"))
        a.addButton(withTitle: L10n.tr("btn.later"))
        if a.runModal() == .alertFirstButtonReturn {
            // upgradeInFlight / autoUpgradeRunning stay true through the apply.
            performApply(updater: updater, current: current, target: target, origin: origin)
        } else {
            // Declined ("Later"): this round is done.
            upgradeInFlight = false
            autoUpgradeRunning = false
            if origin == .auto {
                deferAutoUpgrade(by: 7200)
                remindAutoUpgradeLater(after: 7200)
            }
        }
    }

    /// In-place install (with backup & automatic rollback on failure) on a
    /// background queue, then restart the server so the new dsh takes effect.
    private func performApply(updater: DSHUpdater, current: String, target: String, origin: UpgradeOrigin) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let new = try updater.apply(registry: RegistryConfig.current, version: target)
                self.server.refreshFacts()
                AppLog.shared.log("upgrade applied: \(current) -> \(new)")
                DispatchQueue.main.async {
                    self.upgradeInFlight = false
                    self.autoUpgradeRunning = false
                    self.autoUpgradeReminderTimer?.invalidate()
                    self.autoUpgradeReminderTimer = nil
                    if origin == .auto { self.deferAutoUpgrade(by: 86_400) }
                    self.restartServerAfterUpgrade()
                    let a = NSAlert()
                    a.messageText = L10n.tr("alert.dshUpgrade")
                    a.informativeText = L10n.tr("alert.upgraded", current, new)
                    a.addButton(withTitle: L10n.tr("btn.ok"))
                    a.runModal()
                }
            } catch {
                let msg = error.localizedDescription
                let rolledBack = updater.currentVersion
                AppLog.shared.log("upgrade apply failed: \(msg)")
                DispatchQueue.main.async {
                    self.upgradeInFlight = false
                    self.autoUpgradeRunning = false
                    self.autoUpgradeReminderTimer?.invalidate()
                    self.autoUpgradeReminderTimer = nil
                    if origin == .auto { self.deferAutoUpgrade(by: 7200) }
                    let a = NSAlert()
                    a.messageText = L10n.tr("alert.upgradeFailed")
                    if let rolledBack {
                        a.informativeText = L10n.tr("alert.rolledBack", rolledBack, msg)
                    } else {
                        a.informativeText = msg
                    }
                    a.addButton(withTitle: L10n.tr("btn.ok"))
                    a.runModal()
                    // A failed install / rollback may have left a stale tree on
                    // disk — restart so the server reloads whatever is there.
                    self.restartServerAfterUpgrade()
                }
            }
        }
    }

    /// Opens dsh web's Settings view, same as clicking its "Settings" entry.
    /// Located via the stable `data-slot="sidebar.settings"` slot attribute
    /// (works whether the sidebar is expanded or collapsed to an icon rail),
    /// with a localized-label match as fallback.
    private static let openDSHSettingsJS = """
    (function () {
      // 1) stable slot: the sidebar settings entry
      var slot = document.querySelector('[data-slot="sidebar.settings"]');
      if (slot) {
        var b = slot.querySelector('button');
        if (b) { b.click(); return true; }
      }
      // 2) fallback: match by localized label
      var btns = document.querySelectorAll('button');
      for (var i = 0; i < btns.length; i++) {
        var t = (btns[i].textContent || '').trim();
        var a = (btns[i].getAttribute('aria-label') || '').toLowerCase();
        if (t === 'Settings' || t === '设置' || a.indexOf('settings') !== -1) {
          btns[i].click();
          return true;
        }
      }
      return false;
    })()
    """

    @objc private func openDSHSettings(_ sender: Any?) {
        guard let webView = webView else { return }
        webView.evaluateJavaScript(Self.openDSHSettingsJS) { result, error in
            if let ok = result as? Bool, ok {
                AppLog.shared.log("dsh settings opened")
            } else {
                AppLog.shared.log("dsh settings open failed: \(String(describing: error))")
            }
        }
    }

    /// Panel → web session link: switch dsh web to the given session. Driven by
    /// the sessionOpenerScript bridge injected into the web view.
    private func openDSHSession(_ sessionId: String) {
        guard let webView = webView else { return }
        // sessionId is an opaque token (uuid) — quote it for JS safely.
        let escaped = sessionId.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let js = "window.__dshOpenSession ? window.__dshOpenSession(\"\(escaped)\") : Promise.resolve({ok:false,reason:\"bridge-unavailable\"})"
        webView.evaluateJavaScript(js) { result, error in
            if let err = error {
                AppLog.shared.log("openDSHSession JS error: \(err.localizedDescription)")
                return
            }
            if let dict = result as? [String: Any], let ok = dict["ok"] as? Bool, !ok {
                AppLog.shared.log("openDSHSession \(sessionId): \(dict["reason"] ?? "?" )")
            }
        }
    }

    /// Manual "Check & Upgrade": three-stage. (1) Check the next STEPWISE target
    /// and prompt with its version; (2) download it in the background on
    /// confirm (live dsh untouched); (3) after the download, ask again before
    /// the in-place install + restart.
    @objc func upgradeDSH() {
        if upgradeInFlight || autoUpgradeRunning {
            let busy = NSAlert()
            busy.messageText = L10n.tr("alert.dshUpgrade")
            busy.informativeText = L10n.tr("alert.upgradeInProgress")
            busy.addButton(withTitle: L10n.tr("btn.ok"))
            busy.runModal()
            return
        }
        guard let updater = currentUpdater() else {
            let alert = NSAlert()
            alert.messageText = L10n.tr("alert.cannotUpgrade")
            alert.informativeText = L10n.tr("alert.noRuntime")
            alert.addButton(withTitle: L10n.tr("btn.ok"))
            alert.runModal()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let current = updater.currentVersion else {
                DispatchQueue.main.async {
                    self.hideStatus()
                    let a = NSAlert()
                    a.messageText = L10n.tr("alert.upgradeFailed")
                    a.informativeText = L10n.tr("alert.noVersionInfo", RegistryConfig.current)
                    a.addButton(withTitle: L10n.tr("btn.ok"))
                    a.runModal()
                }
                return
            }
            guard let target = self.stepTarget(for: updater) else {
                AppLog.shared.log("manual upgrade: up to date (\(current))")
                DispatchQueue.main.async {
                    self.hideStatus()
                    let a = NSAlert()
                    a.messageText = L10n.tr("alert.dshUpgrade")
                    a.informativeText = L10n.tr("alert.upToDate", current)
                    a.addButton(withTitle: L10n.tr("btn.ok"))
                    a.runModal()
                }
                return
            }
            AppLog.shared.log("manual upgrade: found \(current) -> \(target)")
            DispatchQueue.main.async {
                self.hideStatus()
                let a = NSAlert()
                a.messageText = L10n.tr("alert.upgradeAvailable", target)
                a.informativeText = L10n.tr("alert.upgradeAvailableInfo", current, target)
                a.addButton(withTitle: L10n.tr("btn.download"))
                a.addButton(withTitle: L10n.tr("btn.cancel"))
                if a.runModal() == .alertFirstButtonReturn {
                    self.startDownloadThenPromptApply(updater: updater, current: current, target: target, origin: .manual)
                }
            }
        }
    }

    /// Shared auto-upgrade toggle used by the Settings menu and the Settings
    /// window; keeps the menu checkbox in sync.
    func setAutoUpgradeEnabled(_ enabled: Bool) {
        ShellConfig.shared.set(enabled, forKey: "autoUpgradeDsh")
        autoUpgradeMenuItem?.state = enabled ? .on : .off
        AppLog.shared.log("auto-upgrade \(enabled ? "enabled" : "disabled")")
    }

    @objc private func toggleAutoUpgrade(_ sender: NSMenuItem) {
        setAutoUpgradeEnabled(sender.state == .off)
    }

    @objc private func setRegistry() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("alert.setRegistryTitle")
        alert.informativeText = L10n.tr("alert.setRegistryInfo", RegistryConfig.current)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = RegistryConfig.current
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("btn.save"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty { RegistryConfig.reset() } else { RegistryConfig.set(url) }
            AppLog.shared.log("registry set to \(RegistryConfig.current)")
        }
    }

    @objc private func resetRegistry() {
        RegistryConfig.reset()
        AppLog.shared.log("registry reset to \(RegistryConfig.current)")
    }

    // MARK: WKNavigationDelegate

    private func isLocal(_ url: URL) -> Bool {
        guard let host = url.host else { return true } // about:, blob:, data:, file:
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if isLocal(url) {
            decisionHandler(.allow)
        } else {
            // External links open in the default browser, never inside the shell.
            AppLog.shared.log("opening externally: \(url.absoluteString)")
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        AppLog.shared.log("page did finish loading: \(webView.url?.absoluteString ?? "?")")
        // Warm the Review panel's session listing now that a workspace resolves,
        // so opening the panel renders immediately instead of waiting on the
        // core CLI (the first-open "empty panel" the user sees).
        reviewPanel?.prewarm()
        // Report the page's actual browser language (follows AppleLanguages).
        webView.evaluateJavaScript("navigator.language") { result, _ in
            if let lang = result as? String {
                AppLog.shared.log("webview navigator.language=\(lang)")
            }
        }
        // Debug probe (DSH_PREVIEW_DEBUG=1): fires a host.openPath request the
        // way the page would and reports whether the interceptor captured it,
        // swallowed it (fake success), and left the UI untouched.
        if ProcessInfo.processInfo.environment["DSH_PREVIEW_DEBUG"] == "1" {
            webView.evaluateJavaScript(Self.previewDebugProbeJS) { result, error in
                if let r = result {
                    AppLog.shared.log("preview debug probe: \(r)")
                } else {
                    AppLog.shared.log("preview debug probe failed: \(String(describing: error))")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    webView.evaluateJavaScript("JSON.stringify(window.__dshProbeAsync)") { r2, _ in
                        AppLog.shared.log("preview debug probe async: \(r2 ?? "none")")
                    }
                }
            }
            // Report dsh web's actual viewport and sidebar state inside the
            // real WKWebView (debugging the "sidebar collapsed" reports).
            webView.evaluateJavaScript("""
            JSON.stringify({
              innerWidth: window.innerWidth,
              innerHeight: window.innerHeight,
              sidebarCollapsed: (document.querySelector('[data-sidebar-collapsed]') || {}).getAttribute
                ? (document.querySelector('[data-sidebar-collapsed]').getAttribute('data-sidebar-collapsed') || false)
                : null
            })
            """) { result, _ in
                AppLog.shared.log("dsh viewport/sidebar: \(result ?? "?")")
            }
            // Injected-bridge health: the three scripts patch the page at document
            // start, so a dsh web change that breaks them fails SILENTLY (no row
            // click, no directory follow, no preview intercept). Report installed
            // flags so a broken bridge is at least visible in the log.
            webView.evaluateJavaScript("""
            JSON.stringify({
              tracker: !!window.__dshSessionTracked,
              opener: !!window.__dshSessionOpener,
              preview: !!window.__dshPreviewInstalled,
              rows: document.querySelectorAll('[role="treeitem"]').length
            })
            """) { result, _ in
                AppLog.shared.log("dsh injected bridges: \(result ?? "?")")
            }
        }
        // Session-tracking diagnostics (DSH_SESSION_DEBUG=1): dump the
        // session.* / subagent.list requests the tracker has observed so far.
        if ProcessInfo.processInfo.environment["DSH_SESSION_DEBUG"] == "1" {
            webView.evaluateJavaScript("JSON.stringify(window.__dshSessionSeen || [])") { result, _ in
                AppLog.shared.log("session tracker seen: \(result ?? "[]")")
            }
            webView.evaluateJavaScript("JSON.stringify({ tracked: !!window.__dshSessionTracked, last: window.__dshLastTrackedSession || null })") { result, _ in
                AppLog.shared.log("session tracker state: \(result ?? "?")")
            }
        }
        hideStatus()
    }

    /// Probe evaluated in the page when DSH_PREVIEW_DEBUG=1: checks the
    /// interceptor installed state, then fires a `host.openPath` request the
    /// exact way dsh web's client does (HTTP POST to /api/host.openPath) and
    /// verifies the interceptor captured the path synchronously (the hit flag
    /// is set before the promise resolves) and returned a fake success (read
    /// back on a second pass via __dshProbeAsync).
    private static let previewDebugProbeJS = """
    (function () {
      var out = { installed: !!window.__dshPreviewInstalled, hit: window.__dshPreviewHit || null };
      var chips = document.querySelectorAll('[data-produced-files-row] button[title]');
      out.chips = chips.length;
      out.mentions = document.querySelectorAll('button[class*="fileMention"]').length;
      window.__dshProbeAsync = null;
      var testPath = '/tmp/dsh-preview-fetch-test.txt';
      var fakeBody = JSON.stringify({
        type: 'client-request',
        rpcId: 'debug-probe-rpc',
        method: 'host.openPath',
        payload: { path: testPath }
      });
      fetch('/api/host.openPath', { method: 'POST', body: fakeBody }).then(function (r) {
        return r.json();
      }).then(function (json) {
        window.__dshProbeAsync = { fakeResponse: json, hitAfter: window.__dshPreviewHit || null };
        return true;
      }).catch(function (e) {
        window.__dshProbeAsync = { error: String(e) };
        return true;
      });
      out.hitSync = window.__dshPreviewHit || null;
      return JSON.stringify(out);
    })()
    """

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        AppLog.shared.log("provisional navigation failed: \(error.localizedDescription)")
        showStatus(L10n.tr("status.pageLoadFailed", error.localizedDescription), spinner: false, retry: true)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, !isLocal(url) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L10n.tr("btn.ok"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("btn.ok"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            completionHandler(field.stringValue)
        } else {
            completionHandler(nil)
        }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.begin { resp in
            completionHandler(resp == .OK ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        AppLog.shared.log("download finished")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        AppLog.shared.log("download failed: \(error.localizedDescription)")
    }

    // MARK: WKScriptMessageHandler (file preview bridge)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "dshPreview" {
            guard let body = message.body as? [String: Any], let path = body["path"] as? String else { return }
            AppLog.shared.log("preview request: \(path)")
            if rightPanel != .preview { setRightPanel(.preview) }
            previewPanel.open(path: path)
            return
        }
        // The user switched to a different session in dsh web: resolve its
        // working directory and re-point every project-dir consumer.
        guard message.name == "dshSession" else { return }
        guard let body = message.body as? [String: Any], let sid = body["sessionId"] as? String else { return }
        AppLog.shared.log("active session changed: \(sid)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let cwd = DSHSessionRPC.fetchSessionCwd(port: self.server.port, sessionId: sid)
            DispatchQueue.main.async {
                // Update ProjectDirectory FIRST so the tasks panel (and any
                // consumer) reads the NEW workspace path, then re-point it.
                // If fetch failed (cwd nil), still re-trigger — the panel's
                // resolver falls back to scanning registered workspaces.
                if let cwd = cwd {
                    if ProjectDirectory.current != cwd {
                        ProjectDirectory.set(cwd)
                        self.previewPanel?.setProjectDirectory(cwd)
                        self.wikiPanel?.reloadRoot()
                        AppLog.shared.log("project directory followed session \(sid): \(cwd)")
                    }
                }
                self.tasksPanel?.workspaceChanged()
                self.channelPanel?.workspaceChanged()
                self.reviewPanel?.workspaceChanged()
                // Web → panel session link: follow the session the user is
                // viewing — the panel auto-expands its row (or collapses all
                // when no session matches, e.g. a different workspace).
                self.channelPanel?.setActiveSession(sid)
                self.reviewPanel?.setActiveSession(sid)
            }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu (shown under the app name) — items carry no app-name text.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.tr("menu.about"), action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu: save the active preview-editor buffer (⌘S).
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: L10n.tr("menu.file"))
        let saveItem = fileMenu.addItem(withTitle: L10n.tr("menu.save"), action: #selector(saveActiveFile(_:)), keyEquivalent: "s")
        saveItem.target = self
        let closeTabItem = fileMenu.addItem(withTitle: L10n.tr("preview.closeTab"), action: #selector(closeActiveFileTab(_:)), keyEquivalent: "w")
        closeTabItem.keyEquivalentModifierMask = [.command]
        closeTabItem.isEnabled = false
        closeTabItem.target = self
        closeTabMenuItem = closeTabItem
        fileItem.submenu = fileMenu

        // Edit menu: routes Cmd+C/V/X/A/Z etc. to the first responder
        // (WKWebView). Without it, copy/paste shortcuts stop working.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L10n.tr("menu.edit"))
        editMenu.addItem(withTitle: L10n.tr("edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.tr("edit.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.tr("edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.tr("edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.tr("edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.tr("edit.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // View menu: preview/terminal panel toggles (checked while visible).
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: L10n.tr("menu.view"))
        let togglePreview = viewMenu.addItem(withTitle: L10n.tr("menu.togglePreview"), action: #selector(togglePreviewPanel(_:)), keyEquivalent: "p")
        togglePreview.keyEquivalentModifierMask = [.command, .option]
        togglePreview.target = self
        togglePreview.state = (rightPanel == .preview) ? .on : .off
        previewToggleMenuItem = togglePreview
        let toggleTerminal = viewMenu.addItem(withTitle: L10n.tr("menu.toggleTerminal"), action: #selector(terminalEntryTapped(_:)), keyEquivalent: "t")
        toggleTerminal.keyEquivalentModifierMask = [.command, .option]
        toggleTerminal.target = self
        toggleTerminal.state = (rightPanel == .terminal) ? .on : .off
        terminalToggleMenuItem = toggleTerminal
        let toggleWiki = viewMenu.addItem(withTitle: L10n.tr("menu.toggleWiki"), action: #selector(wikiEntryTapped(_:)), keyEquivalent: "w")
        toggleWiki.keyEquivalentModifierMask = [.command, .option]
        toggleWiki.target = self
        toggleWiki.state = (rightPanel == .wiki) ? .on : .off
        wikiToggleMenuItem = toggleWiki
        let toggleTasks = viewMenu.addItem(withTitle: L10n.tr("menu.toggleTasks"), action: #selector(tasksEntryTapped(_:)), keyEquivalent: "j")
        toggleTasks.keyEquivalentModifierMask = [.command, .option]
        toggleTasks.target = self
        toggleTasks.state = (rightPanel == .tasks) ? .on : .off
        tasksToggleMenuItem = toggleTasks
        let toggleBrowser = viewMenu.addItem(withTitle: L10n.tr("menu.toggleBrowser"), action: #selector(browserEntryTapped(_:)), keyEquivalent: "b")
        toggleBrowser.keyEquivalentModifierMask = [.command, .option]
        toggleBrowser.target = self
        toggleBrowser.state = (rightPanel == .browser) ? .on : .off
        browserToggleMenuItem = toggleBrowser
        let toggleChannel = viewMenu.addItem(withTitle: L10n.tr("menu.toggleChannel"), action: #selector(channelEntryTapped(_:)), keyEquivalent: "h")
        toggleChannel.keyEquivalentModifierMask = [.command, .option]
        toggleChannel.target = self
        toggleChannel.state = (rightPanel == .channel) ? .on : .off
        channelToggleMenuItem = toggleChannel
        let toggleReview = viewMenu.addItem(withTitle: L10n.tr("menu.toggleReview"), action: #selector(reviewEntryTapped(_:)), keyEquivalent: "r")
        toggleReview.keyEquivalentModifierMask = [.command, .option]
        toggleReview.target = self
        toggleReview.state = (rightPanel == .review) ? .on : .off
        reviewToggleMenuItem = toggleReview
        viewItem.submenu = viewMenu

        // Settings menu: dsh settings/upgrade/registry + logs + language.
        let settingsItem = NSMenuItem()
        mainMenu.addItem(settingsItem)
        let settingsMenu = NSMenu(title: L10n.tr("menu.settings"))
        // Settings window (⌘,) — the richer surface; the items below stay as
        // a fast path.
        let settingsWindowItem = settingsMenu.addItem(withTitle: L10n.tr("settings.openMenu"), action: #selector(openSettingsWindow(_:)), keyEquivalent: ",")
        settingsWindowItem.target = self
        settingsMenu.addItem(.separator())
        let dshSettings = settingsMenu.addItem(withTitle: L10n.tr("menu.dshSettings"), action: #selector(openDSHSettings(_:)), keyEquivalent: "")
        dshSettings.target = self
        settingsMenu.addItem(.separator())
        let upgrade = settingsMenu.addItem(withTitle: L10n.tr("menu.checkUpgrade"), action: #selector(upgradeDSH), keyEquivalent: "u")
        upgrade.target = self
        checkUpgradeMenuItem = upgrade
        refreshCheckUpgradeEnabled()
        let auto = settingsMenu.addItem(withTitle: L10n.tr("menu.autoUpgrade"), action: #selector(toggleAutoUpgrade(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = autoUpgradeEnabled() ? .on : .off
        autoUpgradeMenuItem = auto
        settingsMenu.addItem(.separator())
        let setReg = settingsMenu.addItem(withTitle: L10n.tr("menu.setRegistry"), action: #selector(setRegistry), keyEquivalent: "")
        setReg.target = self
        let resetReg = settingsMenu.addItem(withTitle: L10n.tr("menu.resetRegistry"), action: #selector(resetRegistry), keyEquivalent: "")
        resetReg.target = self
        settingsMenu.addItem(.separator())
        // Wiki (Repo Wiki) settings — toggles persist in UserDefaults.
        let wikiAuto = settingsMenu.addItem(withTitle: L10n.tr("wiki.settingsAuto"), action: #selector(toggleWikiAutoRegenerate(_:)), keyEquivalent: "")
        wikiAuto.target = self
        wikiAuto.state = wikiAutoRegenerateEnabled() ? .on : .off
        let wikiRegister = settingsMenu.addItem(withTitle: L10n.tr("wiki.settingsRegister"), action: #selector(toggleWikiRegisterAgentsMD(_:)), keyEquivalent: "")
        wikiRegister.target = self
        wikiRegister.state = wikiRegisterAgentsMdEnabled() ? .on : .off
        let rootItem = NSMenuItem(title: L10n.tr("wiki.settingsRoot"), action: nil, keyEquivalent: "")
        settingsMenu.addItem(rootItem)
        let rootMenu = NSMenu(title: L10n.tr("wiki.settingsRoot"))
        let inRepo = rootMenu.addItem(withTitle: L10n.tr("wiki.settingsRootInRepo"), action: #selector(setWikiRootMode(_:)), keyEquivalent: "")
        inRepo.target = self
        inRepo.tag = 0
        inRepo.state = WikiPaths.rootMode == "in-repo" ? .on : .off
        let dshHome = rootMenu.addItem(withTitle: L10n.tr("wiki.settingsRootHome"), action: #selector(setWikiRootMode(_:)), keyEquivalent: "")
        dshHome.target = self
        dshHome.tag = 1
        dshHome.state = WikiPaths.rootMode == "dsh-home" ? .on : .off
        rootItem.submenu = rootMenu
        settingsMenu.addItem(.separator())
        let logs = settingsMenu.addItem(withTitle: L10n.tr("menu.openLogs"), action: #selector(openLogs), keyEquivalent: "l")
        logs.target = self
        settingsMenu.addItem(.separator())
        let langItem = NSMenuItem(title: L10n.tr("menu.language"), action: nil, keyEquivalent: "")
        settingsMenu.addItem(langItem)
        let langMenu = NSMenu(title: L10n.tr("menu.language"))
        let followSystem = langMenu.addItem(withTitle: L10n.tr("menu.followSystem"), action: #selector(setLanguage(_:)), keyEquivalent: "")
        followSystem.target = self
        followSystem.tag = 0
        followSystem.state = L10n.hasExplicitChoice ? .off : .on
        let zh = langMenu.addItem(withTitle: "中文", action: #selector(setLanguage(_:)), keyEquivalent: "")
        zh.target = self
        zh.tag = 1
        zh.state = (L10n.hasExplicitChoice && L10n.isZh) ? .on : .off
        let en = langMenu.addItem(withTitle: "English", action: #selector(setLanguage(_:)), keyEquivalent: "")
        en.target = self
        en.tag = 2
        en.state = (L10n.hasExplicitChoice && !L10n.isZh) ? .on : .off
        langItem.submenu = langMenu
        settingsMenu.addItem(.separator())
        // Appearance submenu (System / Light / Dark) — kept in sync with the
        // Settings window radio group.
        let appearanceItem = NSMenuItem(title: L10n.tr("menu.appearance"), action: nil, keyEquivalent: "")
        settingsMenu.addItem(appearanceItem)
        let appearanceMenu = NSMenu(title: L10n.tr("menu.appearance"))
        let systemItem = appearanceMenu.addItem(withTitle: L10n.tr("settings.appearanceSystem"), action: #selector(appearanceMenuItemTapped(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.tag = 0
        let lightItem = appearanceMenu.addItem(withTitle: L10n.tr("settings.appearanceLight"), action: #selector(appearanceMenuItemTapped(_:)), keyEquivalent: "")
        lightItem.target = self
        lightItem.tag = 1
        let darkItem = appearanceMenu.addItem(withTitle: L10n.tr("settings.appearanceDark"), action: #selector(appearanceMenuItemTapped(_:)), keyEquivalent: "")
        darkItem.target = self
        darkItem.tag = 2
        appearanceMenuItems = [systemItem, lightItem, darkItem]
        refreshAppearanceMenuState()
        appearanceItem.submenu = appearanceMenu
        settingsItem.submenu = settingsMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func appearanceMenuItemTapped(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: AppTheme.set("light")
        case 2: AppTheme.set("dark")
        default: AppTheme.set("system")
        }
        themeDidChange()
    }

    /// Keep every theme UI in sync after AppTheme changes — the View menu
    /// checkmark and (if open) the Settings window radio group.
    func themeDidChange() {
        refreshAppearanceMenuState()
        settingsWindowController?.syncThemeRadios()
    }

    private func refreshAppearanceMenuState() {
        let mode = AppTheme.current
        for item in appearanceMenuItems {
            item.state = ((item.tag == 0 && mode == "system")
                || (item.tag == 1 && mode == "light")
                || (item.tag == 2 && mode == "dark")) ? .on : .off
        }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: applyLanguage(nil)              // follow system
        case 1: applyLanguage("zh")
        default: applyLanguage("en")
        }
    }

    /// Apply a shell language and refresh everything that displays it — the
    /// menu and the dsh web page (the rebuilt WebView injects a
    /// navigator.language override, so the page language follows immediately).
    /// Shared by the Language menu and the Settings window.
    func applyLanguage(_ lang: String?) {
        L10n.set(lang)
        UserDefaults.standard.set([L10n.isZh ? "zh-CN" : "en-US"], forKey: "AppleLanguages")
        AppLog.shared.log("language set: lang=\(L10n.lang) followSystem=\(!L10n.hasExplicitChoice) AppleLanguages=\(UserDefaults.standard.array(forKey: "AppleLanguages") ?? [])")
        buildMenu() // rebuild the whole menu in the new language
        // 活动栏 tooltip 跟随语言（构建时一次性设置，切换后需手动刷新）
        previewBarButton?.toolTip = L10n.tr("bar.preview")
        terminalBarButton?.toolTip = L10n.tr("bar.terminal")
        browserBarButton?.toolTip = L10n.tr("bar.browser")
        channelBarButton?.toolTip = L10n.tr("bar.channel")
        reviewBarButton?.toolTip = L10n.tr("bar.review")
        wikiBarButton?.toolTip = L10n.tr("bar.wiki")
        tasksBarButton?.toolTip = L10n.tr("bar.tasks")
        // 各面板头部操作按钮 tooltip 同样跟随语言
        previewPanel?.refreshTooltips()
        terminalPanel?.refreshTooltips()
        wikiPanel?.refreshTooltips()
        tasksPanel?.refreshTooltips()
        browserPanel?.refreshTooltips()
        channelPanel?.refreshTooltips()
        reviewPanel?.refreshTooltips()
        // Reload the dsh web page: the rebuilt WebView injects a navigator.language
        // override, so the page language follows immediately (no restart needed).
        let currentURL = webView.url
        rebuildWebView()
        webView.load(URLRequest(url: currentURL ?? URL(string: "http://127.0.0.1:\(server.port)")!))
        // rebuildWebView replaced the WebView pane, which resets the split
        // divider position — re-apply the panel's state and width so the web
        // view stays ≥ minWebViewWidth (and dsh's sidebar doesn't collapse).
        setRightPanel(rightPanel)
    }

    /// Custom, wider About window (the stock About panel wraps long lines).
    private var aboutWindow: NSWindow?

    /// Settings window (⌘,) — one instance, kept alive like the About window.
    private var settingsWindowController: SettingsWindowController?
    /// In-memory guard so the onboarding sheet can never appear twice in one
    /// session, even if the UserDefaults flag write is delayed.
    private var didShowOnboarding = false

    @objc private func openSettingsWindow(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(appDelegate: self)
        }
        settingsWindowController?.show()
    }

    /// dsh runtime version for the Settings window (facts refreshed so the
    /// value is current after an upgrade).
    func settingsDSHVersion() -> String {
        server.refreshFacts()
        return server.dshVersion
    }

    /// First-run welcome sheet (once, ever). Shown shortly after launch once
    /// the main window is on screen; dismissed with "Get Started" or
    /// "Learn More" (which opens the repo README in the browser).
    private func showOnboardingIfNeeded() {
        guard !didShowOnboarding, !ShellConfig.shared.bool(forKey: "hasCompletedOnboarding") else { return }
        didShowOnboarding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, let window = self.window else { return }
            let alert = NSAlert()
            alert.messageText = L10n.tr("onboarding.title")
            alert.informativeText = L10n.tr("onboarding.points")
            alert.addButton(withTitle: L10n.tr("onboarding.getStarted"))
            alert.addButton(withTitle: L10n.tr("onboarding.learnMore"))
            alert.beginSheetModal(for: window) { response in
                ShellConfig.shared.set(true, forKey: "hasCompletedOnboarding")
                if response == .alertSecondButtonReturn,
                   let url = URL(string: "https://github.com/insky2005/oh-my-dsh") {
                    NSWorkspace.shared.open(url)
                }
            }
            AppLog.shared.log("onboarding sheet shown")
        }
    }

    @objc private func showAbout() {
        if let w = aboutWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.8.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "64"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("menu.about")
        window.isReleasedWhenClosed = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: "oh-my-dsh")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        name.translatesAutoresizingMaskIntoConstraints = false

        let ver = NSTextField(labelWithString: L10n.tr("about.version", version, build))
        ver.textColor = .secondaryLabelColor
        ver.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let info = NSTextField(wrappingLabelWithString:
            L10n.tr("about.credits", server.dshVersion, server.runtimeSource, server.nodeVersion, server.nodePath, RegistryConfig.current))
        info.font = .systemFont(ofSize: 12)
        info.preferredMaxLayoutWidth = 500
        info.translatesAutoresizingMaskIntoConstraints = false

        let ok = NSButton(title: L10n.tr("btn.ok"), target: window, action: #selector(NSWindow.performClose(_:)))
        ok.keyEquivalent = "\r"
        ok.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(icon)
        content.addSubview(name)
        content.addSubview(ver)
        content.addSubview(separator)
        content.addSubview(info)
        content.addSubview(ok)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            name.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            ver.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            ver.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            separator.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 20),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            info.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            info.bottomAnchor.constraint(lessThanOrEqualTo: ok.topAnchor, constant: -12),
            ok.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            ok.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            ok.widthAnchor.constraint(equalToConstant: 88),
        ])

        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        aboutWindow = window
        AppLog.shared.log("about window shown (size \(window.frame.size.width)x\(window.frame.size.height))")
    }

    /// Save the active preview-editor tab (File ▸ Save / ⌘S).
    @objc private func saveActiveFile(_ sender: Any?) {
        previewPanel.saveActiveTab()
    }

    /// Close the active preview tab (File ▸ 关闭页签 / ⌘W). When no tab is open
    /// the item is disabled so ⌘W falls through to closing the window.
    @objc private func closeActiveFileTab(_ sender: Any?) {
        previewPanel.closeActiveTab()
    }

    private func updateCloseTabMenuState() {
        closeTabMenuItem?.isEnabled = previewPanel?.hasOpenTabs ?? false
    }

    @objc private func togglePreviewPanel(_ sender: Any?) {
        setRightPanel(rightPanel == .preview ? .none : .preview)
    }

    /// Toggle the integrated terminal panel (activity bar entry / ⌥⌘T).
    @objc private func terminalEntryTapped(_ sender: Any?) {
        setRightPanel(rightPanel == .terminal ? .none : .terminal)
    }

    /// Toggle the Repo Wiki panel (activity bar entry / ⌥⌘W).
    @objc private func wikiEntryTapped(_ sender: Any?) {
        setRightPanel(rightPanel == .wiki ? .none : .wiki)
    }

    /// Toggle the IssueRunner task panel (activity bar entry / ⌥⌘J).
    @objc private func tasksEntryTapped(_ sender: Any?) {
        setRightPanel(rightPanel == .tasks ? .none : .tasks)
    }

    /// Toggle the Browser panel (activity bar entry / ⌥⌘B).
    @objc private func browserEntryTapped(_ sender: Any?) {
        setRightPanel(rightPanel == .browser ? .none : .browser)
    }
    @objc private func channelEntryTapped(_ sender: Any?) {
        setRightPanel(rightPanel == .channel ? .none : .channel)
    }
    /// Toggle the Review (change audit) panel (activity bar entry / ⌥⌘R).
    @objc private func reviewEntryTapped(_ sender: Any?) {
        setRightPanel(rightPanel == .review ? .none : .review)
    }
    /// Run QR login for a channel via the core CLI, open the QR URL in the
    /// browser, and save the token to ~/.dsh/channels/<channelId>.json.
    /// completion(true) when login confirmed.
    private func runChannelLogin(channelId: String, onQRUrl: @escaping (String?) -> Void, completion: @escaping (Bool) -> Void) {
        guard let cli = CoreBridge.coreCLIPath, let node = ServerManager().resolveNode() else {
            completion(false)
            return
        }
        let dshHome = dshDataHome
        let savePath = ((dshHome as NSString).appendingPathComponent("channels") as NSString).appendingPathComponent(channelId + ".json")
        try? FileManager.default.createDirectory(atPath: (dshHome as NSString).appendingPathComponent("channels"), withIntermediateDirectories: true)

        // DingTalk uses the device-code app-registration flow (channel login-dingtalk);
        // WeChat uses the ClawBot QR login (channel login). Dispatch by channel id prefix.
        let isDingTalk = channelId.hasPrefix("dingtalk")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = [cli, "channel", isDingTalk ? "login-dingtalk" : "login", "--save", savePath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let outHandle = pipe.fileHandleForReading
        var outputData = Data()
        outHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            outputData.append(data)
            if let str = String(data: data, encoding: .utf8),
               let url = str.range(of: isDingTalk ? "https://open-dev.dingtalk.com" : "https://liteapp.weixin.qq.com") {
                let sub = str[url.lowerBound...]
                let end = sub.firstIndex(where: { $0 == "）" || $0 == "\n" }) ?? sub.endIndex
                let link = String(sub[..<end])
                DispatchQueue.main.async { onQRUrl(link) }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            self?.loginProcs.removeValue(forKey: channelId)
            let out = String(data: outputData, encoding: .utf8) ?? ""
            let ok = out.contains("\"connected\":true") || FileManager.default.fileExists(atPath: savePath)
            DispatchQueue.main.async {
                if ok { self?.startChannelRunner(channelId: channelId) }
                completion(ok)
            }
        }
        loginProcs[channelId] = proc
        try? proc.run()
    }

    /// Cancel an in-flight login (user left the wizard on step 1/2).
    private func cancelChannelLogin(channelId: String) {
        guard let proc = loginProcs.removeValue(forKey: channelId) else { return }
        proc.terminate()
        AppLog.shared.log("channel login cancelled for \(channelId)")
    }

    /// Start the live channel listener (channel run) in the background so
    /// inbound WeChat messages — including slash commands like /help — are
    /// received and answered. Uses the saved token + the active workspace's
    /// refs. Kept strongly by the delegate so it survives after login returns.
    private var channelRunnerProcs: [Process] = []
    private var channelRunnerIds: [String] = []
    // In-flight QR / device-code login processes (channel login / login-dingtalk),
    // keyed by channelId, so leaving the wizard can cancel them.
    private var loginProcs: [String: Process] = [:]
    private func startChannelRunner(channelId: String) {
        // dedup: never run two listeners for the same channel (each would
        // long-poll the same token and re-handle every message -> duplicates)
        if channelRunnerIds.contains(channelId) {
            AppLog.shared.log("channel runner already running for \(channelId)")
            return
        }
        guard let cli = CoreBridge.coreCLIPath, let node = ServerManager().resolveNode() else { return }
        let port = server.port
        // The runner's "project" = the active workspace root; it re-reads the
        // channel's global workspaces.json to decide whether this project has the
        // channel enabled (docs/channel-project-switch.md). Per-project refs are no
        // longer read/force-added here.
        let activeRoot = activeWorkspacePath() ?? ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        var args = [cli, "channel", "run", channelId, String(port), "[]", "--project-root", activeRoot]
        // dsh 0.1.2+ authenticates /api with a cookie minted from the launch
        // token dsh web advertises; a spawned runner has no browser cookie, so
        // pass the token (never logged). Without it /wks, /ses and message
        // routing cannot reach dsh at all (docs/plans/dsh-012rc1-compat-audit.md).
        if let token = server.webToken {
            args.append(contentsOf: ["--dsh-token", token])
        }
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        // Route the runner's stdout/stderr to a per-channel log under
        // ~/Library/Logs/oh-my-dsh/ (so channel/core logs like [weixin-clawbot]
        // are inspectable), and drain it so the pipe doesn't fill and block the child.
        let runnerLogPath = NSHomeDirectory() + "/Library/Logs/oh-my-dsh/channel-runner-" + channelId + ".log"
        let runnerLogDir = (runnerLogPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: runnerLogDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: runnerLogPath) {
            FileManager.default.createFile(atPath: runnerLogPath, contents: nil)
        }
        let runnerLog = FileHandle(forWritingAtPath: runnerLogPath)
        try? runnerLog?.seekToEnd()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty, let runnerLog {
                try? runnerLog.write(contentsOf: data)
            }
        }
        do {
            try proc.run()
            channelRunnerProcs.append(proc)
            channelRunnerIds.append(channelId)
            AppLog.shared.log("channel runner started for \(channelId) on port \(port)")
        } catch {
            AppLog.shared.log("channel runner failed to start: \(error.localizedDescription)")
        }
    }

    /// Start channel listeners for every configured global channel at launch.
    private func startConfiguredChannelRunners() {
        guard let data = ShellConfig.shared.data(forKey: "channel.global.list"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            AppLog.shared.log("channel runners: no configured channels")
            return
        }
        for dict in arr {
            if let id = dict["id"] as? String, (dict["enabled"] as? Bool) ?? true {
                startChannelRunner(channelId: id)
            }
        }
    }

    /// Stop all channel listener processes on quit.
    private func stopChannelRunners() {
        for proc in channelRunnerProcs { proc.terminate() }
        channelRunnerProcs.removeAll()
        channelRunnerIds.removeAll()
        AppLog.shared.log("channel runners stopped")
    }

    /// Stop a single channel's runner (dedup-safe).
    private func stopChannelRunner(channelId: String) {
        if let idx = channelRunnerIds.firstIndex(of: channelId) {
            channelRunnerProcs[idx].terminate()
            channelRunnerProcs.remove(at: idx)
            channelRunnerIds.remove(at: idx)
            AppLog.shared.log("channel runner stopped for \(channelId)")
        }
    }

    /// Unbind a channel: stop its runner and remove its local channel files.
    private func unbindChannel(channelId: String) {
        stopChannelRunner(channelId: channelId)
        let dir = (dshDataHome as NSString).appendingPathComponent("channels")
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: dir) {
            for f in files where f.hasPrefix(channelId) {
                try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(f))
            }
        }
        AppLog.shared.log("channel unbound: \(channelId)")
    }

    /// 开发版构建（DSH_DEV_BUILD=1 打包，Info.plist 写入 DSHDevBuild=1）。开发版用于与
    /// 已安装正式版并存测试：CEF 用独立 profile，且跳过单实例退出。未来如需隔离其他
    /// 资源（端口 / channel runner 等），都以 isDevBuild 为入口在此处快速追加覆盖项。
    private var isDevBuild: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "DSHDevBuild") as? String) == "1"
    }

    /// 开发版运行隔离（DSH_DEV_BUILD=1 打包，Info.plist 写入 DSHDevBuild=1）。
    /// 让开发版与已安装正式版并存测试而不互相干扰：
    ///   1. 独立 dsh 实例 —— 强制自拉起（DSH_NATIVE_FORCE_SPAWN=1），不复用已在
    ///      127.0.0.1:3080 运行的 dsh web；3080 被占时自动取空闲端口。
    ///   2. 独立运行空间 —— 默认用 ~/.dsh-dev 作 DSH_HOME（用户显式设 DSH_HOME 时
    ///      尊重覆盖），使 dsh 的会话/配置/skills/channel 与正式 ~/.dsh 完全隔离。
    ///   3. 错开固定端口 —— CEF CDP 默认 9333→9433、Browser API 默认 3081→4081
    ///      （均尊重用户显式覆盖），可与正式版同时运行。
    /// 通过 setenv 注入，dsh web 子进程与各按 $DSH_HOME 解析的组件自动落到 dev 目录。
    private func applyDevIsolation() {
        guard isDevBuild else { return }
        let env = ProcessInfo.processInfo.environment
        // 1) 独立 DSH_HOME（尊重显式覆盖）
        let explicitHome = env["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if explicitHome.isEmpty {
            let devHome = (NSHomeDirectory() as NSString).appendingPathComponent(".dsh-dev")
            setenv("DSH_HOME", devHome, 1)
            // 旧开发版把 CEF profile 放在 ~/.dsh/browser-dev；迁到新隔离目录保留数据。
            migrateLegacyDevBrowserProfile(toHome: devHome)
        }
        // 2) 不复用已启动实例
        if env["DSH_NATIVE_FORCE_SPAWN"] != "1" {
            setenv("DSH_NATIVE_FORCE_SPAWN", "1", 1)
        }
        // 3) 错开 CEF CDP / Browser API 端口（尊重显式覆盖）
        if env["DSH_CDP_PORT"].flatMap({ Int($0) }) == nil {
            setenv("DSH_CDP_PORT", "9433", 1)
        }
        if env["DSH_BROWSER_PORT"].flatMap({ Int($0) }) == nil {
            setenv("DSH_BROWSER_PORT", "4081", 1)
        }
        let e = ProcessInfo.processInfo.environment
        AppLog.shared.log("dev isolation: DSH_HOME=\(e["DSH_HOME"] ?? "?") forceSpawn=\(e["DSH_NATIVE_FORCE_SPAWN"] ?? "-") cdp=\(e["DSH_CDP_PORT"] ?? "?") browserApi=\(e["DSH_BROWSER_PORT"] ?? "?")")
    }

    /// 迁移旧开发版（隔离前）在共享 ~/.dsh 下创建的 CEF profile（~/.dsh/browser-dev）
    /// 到新的开发隔离目录 ~/.dsh-dev/browser-dev，保留既有浏览器数据。幂等：
    /// 源不存在或目标已存在（已迁过/已有新数据）则跳过，避免覆盖。
    private func migrateLegacyDevBrowserProfile(toHome devHome: String) {
        let fm = FileManager.default
        let legacy = (NSHomeDirectory() as NSString).appendingPathComponent(".dsh/browser-dev")
        let dest = (devHome as NSString).appendingPathComponent("browser-dev")
        guard fm.fileExists(atPath: legacy) else { return }
        guard !fm.fileExists(atPath: dest) else {
            AppLog.shared.log("dev isolation: legacy ~/.dsh/browser-dev exists, target \(dest) present — skip migrate")
            return
        }
        try? fm.createDirectory(atPath: devHome, withIntermediateDirectories: true)
        do {
            try fm.moveItem(atPath: legacy, toPath: dest)
            AppLog.shared.log("dev isolation: migrated \(legacy) -> \(dest)")
        } catch {
            AppLog.shared.log("dev isolation: browser-dev migrate failed: \(error.localizedDescription)")
        }
    }

    /// 本 App（shell 侧）读写 dsh 数据目录的实际路径：优先 $DSH_HOME（开发版已由
    /// applyDevIsolation() 注入 ~/.dsh-dev），否则默认 ~/.dsh。让 shell 自己的文件
    /// （如 channel token/清理）与 dsh 运行空间保持一致，开发版不会写入正式 ~/.dsh。
    private var dshDataHome: String {
        if let h = ProcessInfo.processInfo.environment["DSH_HOME"],
           !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return h.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
    }

    /// 初始化 CEF（浏览器面板渲染内核）并启动消息泵定时器。
    /// CDP 端口：DSH_CDP_PORT 覆盖，默认 9333（与 BrowserCDP.port 一致）。
    private func startCEF() {
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"] ?? (NSHomeDirectory() + "/.dsh")
        // Chromium 数据全部收进 ~/.dsh/browser/ 专用子树：
        //   root_cache_path = ~/.dsh/browser（单例锁/组件缓存）
        //   cache_path      = ~/.dsh/browser/profile（profile 数据）
        // 绝不把 root 指向 ~/.dsh 本身（会把 Chromium 文件洒进 dsh 主目录，
        // 曾因 cachePath=~/.dsh/browser-profile 导致 root=~/.dsh 污染）。
        // 调试钩子：--browser-cache-dir=<dir> 指定全新 profile。
        // 开发版用独立 profile（~/.dsh/browser-dev），与正式版 ~/.dsh/browser 隔离，
        // 可与正式版并存而不争抢（等价于追加 --browser-cache-dir=<dev profile>）。
        let browserRoot = dshHome + (isDevBuild ? "/browser-dev" : "/browser")
        var cachePath = browserRoot + "/profile"
        if let idx = CommandLine.arguments.firstIndex(of: "--browser-cache-dir"),
           CommandLine.arguments.count > idx + 1 {
            cachePath = CommandLine.arguments[idx + 1]
        }
        try? FileManager.default.createDirectory(atPath: cachePath, withIntermediateDirectories: true)
        cleanStaleCEFSingleton(in: browserRoot)
        cleanStaleCEFSingleton(in: cachePath)
        let logPath = NSHomeDirectory() + "/Library/Logs/oh-my-dsh/cef.log"
        do {
            // 渲染模式：defaults write com.ohmydsh.app browserRenderMode -string windowed
            // 切换窗口化（Chromium 原生绘制）vs OSR（默认，帧回调自绘）。
            let windowed = ShellConfig.shared.string(forKey: "browserRenderMode") == "windowed"
            CEFShim.setWindowedMode(windowed)
            AppLog.shared.log("CEF render mode: \(windowed ? "windowed" : "osr")")
            try CEFShim.initialize(withCachePath: cachePath,
                                   remoteDebuggingPort: Int32(BrowserCDP.port),
                                   logPath: logPath)
        } catch {
            AppLog.shared.log("CEF init failed: \(error.localizedDescription)")
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in
            CEFShim.runMessageLoopWork()
        }
        RunLoop.main.add(timer, forMode: .common)
        cefPumpTimer = timer
        AppLog.shared.log("CEF initialized (cdp port \(BrowserCDP.port), cache \(cachePath))")
    }

    /// 清理上次异常退出（kill -9 等）残留的 Chromium 进程单例锁。
    /// 只清理"连接被拒绝"的陈旧 socket（还有活实例时不动，避免双实例
    /// 共用 profile 导致损坏）。
    private func cleanStaleCEFSingleton(in dir: String) {
        let socketPath = dir + "/SingletonSocket"
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let n = min(pathBytes.count, buf.count - 1)
            pathBytes[0..<n].withUnsafeBytes { src in
                buf.copyMemory(from: src)
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        if connected != 0 {
            for name in ["SingletonLock", "SingletonSocket", "SingletonCookie"] {
                try? FileManager.default.removeItem(atPath: dir + "/" + name)
            }
            AppLog.shared.log("cleaned stale CEF singleton in \(dir)")
        }
    }

    /// Start the browser panel's localhost REST API (Agent / user curl).
    /// 端口：DSH_BROWSER_PORT 覆盖，默认 3081；被占用自动递增；生效端口写
    /// $DSH_HOME/browser-api.port 供 web-dev-tools 技能发现。
    private func startBrowserAPIServer() {
        let bridge = BrowserAPIBridge()
        bridge.panel = browserPanel
        bridge.showPanel = { [weak self] in self?.setRightPanel(.browser) }
        bridge.hidePanel = { [weak self] in
            if self?.rightPanel == .browser { self?.setRightPanel(.none) }
        }
        bridge.isPanelVisible = { [weak self] in self?.rightPanel == .browser }
        bridge.debugDump = { [weak self] in
            guard let self = self, let panelView = self.browserPanel?.view else { return }
            self.dumpPanelDebugInfo(panelView: panelView, label: "browser")
        }
        bridge.debugState = { [weak self] in
            self?.browserPanel?.debugState() ?? [:]
        }
        bridge.debugHierarchy = { [weak self] in
            self?.dumpBrowserHierarchyJSON() ?? [:]
        }
        browserAPIBridge = bridge

        let server = BrowserAPIServer()
        browserAPIServer = server
        let envPort = ProcessInfo.processInfo.environment["DSH_BROWSER_PORT"].flatMap { Int($0) }
        let preferred = envPort ?? 3081
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"] ?? (NSHomeDirectory() + "/.dsh")
        let portFile = dshHome + "/browser-api.port"
        let port = server.start(preferredPort: preferred, delegate: bridge, portFile: portFile)
        AppLog.shared.log(port > 0
            ? "browser api server listening on 127.0.0.1:\(port) (port file \(portFile))"
            : "browser api server failed to start (preferred \(preferred))")
    }

    /// The workspace directory the task panel should operate on: the shell's
    /// shared active project directory (follows the session the user is
    /// viewing), falling back to the workspace root of the main repo.
    private func activeWorkspacePath() -> String? {
        if let current = ProjectDirectory.current,
           FileManager.default.fileExists(atPath: current) {
            return current
        }
        // Fallback: a panel can be opened before dsh web reports the session the
        // user is viewing (fresh launch / page still loading), and a nil
        // workspace leaves it with nothing to show. dsh persists the workspace
        // list itself, so read the last one from there.
        if let persisted = DSHSessionRPC.persistedWorkspacePath(sessionId: nil),
           FileManager.default.fileExists(atPath: persisted) {
            return persisted
        }
        return ProjectDirectory.current
    }

    // MARK: Wiki settings (UserDefaults-backed menu toggles)

    private func wikiAutoRegenerateEnabled() -> Bool {
        ShellConfig.shared.object(forKey: WikiPaths.autoRegenerateKey) as? Bool ?? false
    }

    private func wikiRegisterAgentsMdEnabled() -> Bool {
        ShellConfig.shared.object(forKey: WikiPaths.registerAgentsMdKey) as? Bool ?? false
    }

    @objc private func toggleWikiAutoRegenerate(_ sender: NSMenuItem) {
        let enabled = sender.state == .off
        ShellConfig.shared.set(enabled, forKey: WikiPaths.autoRegenerateKey)
        sender.state = enabled ? .on : .off
        AppLog.shared.log("wiki auto-regenerate \(enabled ? "enabled" : "disabled")")
    }

    /// Enabling writes the registration block on the next generation
    /// completion (the panel does that); disabling removes it immediately for
    /// the current project when one is resolved.
    @objc private func toggleWikiRegisterAgentsMD(_ sender: NSMenuItem) {
        let enabled = sender.state == .off
        ShellConfig.shared.set(enabled, forKey: WikiPaths.registerAgentsMdKey)
        sender.state = enabled ? .on : .off
        AppLog.shared.log("wiki AGENTS.md register \(enabled ? "enabled" : "disabled")")
        if let repo = wikiPanel?.currentRepoRoot {
            if enabled {
                _ = WikiAgentsMD.register(repoRoot: repo)
            } else {
                _ = WikiAgentsMD.unregister(repoRoot: repo)
            }
        }
    }

    @objc private func setWikiRootMode(_ sender: NSMenuItem) {
        let mode = sender.tag == 1 ? "dsh-home" : "in-repo"
        ShellConfig.shared.set(mode, forKey: WikiPaths.rootModeKey)
        AppLog.shared.log("wiki root mode set to \(mode)")
        wikiPanel?.reloadRoot()
        // Rebuild the menu so the radio state updates.
        buildMenu()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    @objc private func openInBrowser() {
        if let url = webView.url {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "http://127.0.0.1:\(server.port)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLogs() {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/oh-my-dsh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - Settings window

/// The app's Settings window: language / registry / upgrade / theme /
/// shortcuts. One instance per app, owned strongly by AppDelegate (same
/// pattern as the About window). The existing Settings menu items stay as a
/// fast path; this window is the richer surface.
final class SettingsWindowController {

    weak var appDelegate: AppDelegate?
    private var window: NSWindow!
    private var registryField: NSTextField!
    private var registryHint: NSTextField!
    private var autoUpgradeCheckbox: NSButton!
    private var versionLabel: NSTextField!
    private var languageButtons: [NSButton] = []
    private var themeButtons: [NSButton] = []

    /// (label key, key equivalent) pairs for the read-only Shortcuts list.
    private let shortcutRows: [(key: String, shortcut: String)] = [
        ("menu.checkUpgrade", "⌘U"),
        ("menu.openLogs", "⌘L"),
        ("menu.togglePreview", "⌥⌘P"),
        ("menu.toggleTerminal", "⌥⌘T"),
        ("menu.toggleWiki", "⌥⌘W"),
        ("menu.toggleBrowser", "⌥⌘B"),
        ("menu.toggleChannel", "⌥⌘H"),
        ("menu.toggleReview", "⌥⌘R"),
        ("settings.openMenu", "⌘,"),
    ]

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func show() {
        if window == nil { buildWindow() }
        syncVersion()
        autoUpgradeCheckbox?.state = (appDelegate?.autoUpgradeEnabled() ?? true) ? .on : .off
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppLog.shared.log("settings window shown")
    }

    // MARK: Construction

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 460)
        window = w
        buildContent()
        w.center()
    }

    /// (Re)build the window content. Called on first show and again after a
    /// language change so every label is localized in the new language.
    private func buildContent() {
        guard let window = window else { return }
        window.title = L10n.tr("settings.title")

        let languageSection = buildLanguageSection()
        let registrySection = buildRegistrySection()
        let upgradeSection = buildUpgradeSection()
        let themeSection = buildThemeSection()
        let shortcutsSection = buildShortcutsSection()

        let sep1 = makeSeparator(), sep2 = makeSeparator(), sep3 = makeSeparator(), sep4 = makeSeparator()
        let sections = [languageSection, sep1, registrySection, sep2,
                        upgradeSection, sep3, themeSection, sep4, shortcutsSection]

        let mainStack = NSStackView(views: sections)
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = mainStack
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            mainStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        window.contentView = scroll

        // Stretch every section/separator across the content width (the stack
        // otherwise hugs its content) and let the registry field fill its row.
        for view in sections {
            view.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -40).isActive = true
        }
        registryField.widthAnchor.constraint(equalTo: registrySection.widthAnchor).isActive = true
    }

    /// A vertical section: bold header + arranged controls, leading-aligned.
    private func makeSection(headerKey: String, views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: [sectionHeader(headerKey)] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func sectionHeader(_ key: String) -> NSTextField {
        let label = NSTextField(labelWithString: L10n.tr(key))
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func makeRadio(title: String, tag: Int, action: Selector) -> NSButton {
        let b = NSButton(radioButtonWithTitle: title, target: self, action: action)
        b.tag = tag
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    // MARK: Sections

    private func buildLanguageSection() -> NSStackView {
        let follow = makeRadio(title: L10n.tr("settings.followSystem"), tag: 0, action: #selector(languageChanged(_:)))
        let zh = makeRadio(title: "中文", tag: 1, action: #selector(languageChanged(_:)))
        let en = makeRadio(title: "English", tag: 2, action: #selector(languageChanged(_:)))
        languageButtons = [follow, zh, en]
        if L10n.hasExplicitChoice {
            (L10n.isZh ? zh : en).state = .on
        } else {
            follow.state = .on
        }
        let row = NSStackView(views: languageButtons)
        row.orientation = .horizontal
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        return makeSection(headerKey: "settings.language", views: [row])
    }

    private func buildRegistrySection() -> NSStackView {
        registryField = NSTextField(string: RegistryConfig.current)
        registryField.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: L10n.tr("btn.save"), target: self, action: #selector(saveRegistry(_:)))
        save.translatesAutoresizingMaskIntoConstraints = false
        let reset = NSButton(title: L10n.tr("menu.resetRegistry"), target: self, action: #selector(resetRegistry(_:)))
        reset.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [save, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        registryHint = NSTextField(wrappingLabelWithString: registryHintText())
        registryHint.font = .systemFont(ofSize: 11)
        registryHint.textColor = .secondaryLabelColor
        registryHint.translatesAutoresizingMaskIntoConstraints = false

        let section = makeSection(headerKey: "settings.registry", views: [registryField, buttons, registryHint])
        buttons.trailingAnchor.constraint(equalTo: section.trailingAnchor).isActive = true
        registryHint.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func buildUpgradeSection() -> NSStackView {
        autoUpgradeCheckbox = NSButton(checkboxWithTitle: L10n.tr("menu.autoUpgrade"),
                                       target: self, action: #selector(autoUpgradeToggled(_:)))
        autoUpgradeCheckbox.state = (appDelegate?.autoUpgradeEnabled() ?? true) ? .on : .off
        autoUpgradeCheckbox.translatesAutoresizingMaskIntoConstraints = false

        versionLabel = NSTextField(labelWithString: L10n.tr("settings.dshVersion",
                                                            appDelegate?.settingsDSHVersion() ?? L10n.tr("fact.unknown")))
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let check = NSButton(title: L10n.tr("menu.checkUpgrade"), target: self, action: #selector(checkUpgradeTapped(_:)))
        check.translatesAutoresizingMaskIntoConstraints = false

        return makeSection(headerKey: "settings.upgrade", views: [autoUpgradeCheckbox, versionLabel, check])
    }

    private func buildThemeSection() -> NSStackView {
        let system = makeRadio(title: L10n.tr("settings.appearanceSystem"), tag: 0, action: #selector(themeChanged(_:)))
        let light = makeRadio(title: L10n.tr("settings.appearanceLight"), tag: 1, action: #selector(themeChanged(_:)))
        let dark = makeRadio(title: L10n.tr("settings.appearanceDark"), tag: 2, action: #selector(themeChanged(_:)))
        themeButtons = [system, light, dark]
        switch AppTheme.current {
        case "light": light.state = .on
        case "dark": dark.state = .on
        default: system.state = .on
        }
        let row = NSStackView(views: themeButtons)
        row.orientation = .horizontal
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        return makeSection(headerKey: "settings.appearance", views: [row])
    }

    private func buildShortcutsSection() -> NSStackView {
        var cells: [[NSView]] = []
        for row in shortcutRows {
            let label = NSTextField(labelWithString: L10n.tr(row.key))
            label.translatesAutoresizingMaskIntoConstraints = false
            let key = NSTextField(labelWithString: row.shortcut)
            key.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            key.textColor = .secondaryLabelColor
            key.alignment = .right
            key.translatesAutoresizingMaskIntoConstraints = false
            cells.append([label, key])
        }
        let grid = NSGridView(views: cells)
        grid.rowSpacing = 6
        grid.columnSpacing = 24
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        let section = makeSection(headerKey: "settings.shortcuts", views: [grid])
        grid.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    // MARK: Actions

    @objc private func languageChanged(_ sender: NSButton) {
        for b in languageButtons { b.state = (b === sender) ? .on : .off }
        let lang: String? = sender.tag == 0 ? nil : (sender.tag == 1 ? "zh" : "en")
        appDelegate?.applyLanguage(lang)
        // Every label in this window is localized — rebuild it in the new language.
        buildContent()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func themeChanged(_ sender: NSButton) {
        for b in themeButtons { b.state = (b === sender) ? .on : .off }
        switch sender.tag {
        case 1: AppTheme.set("light")
        case 2: AppTheme.set("dark")
        default: AppTheme.set("system")
        }
        // NSApp.appearance drives every window (incl. the WKWebView), which
        // re-renders with the new appearance automatically — no reload needed.
        // Keep the View menu checkmark in sync too.
        appDelegate?.themeDidChange()
    }

    /// Sync the theme radio group from AppTheme.current — used when the theme
    /// was changed from the View menu while the settings window is open.
    func syncThemeRadios() {
        guard themeButtons.count == 3 else { return }
        let mode = AppTheme.current
        for b in themeButtons {
            b.state = ((b.tag == 0 && mode == "system")
                || (b.tag == 1 && mode == "light")
                || (b.tag == 2 && mode == "dark")) ? .on : .off
        }
    }

    @objc private func saveRegistry(_ sender: Any?) {
        let url = registryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { RegistryConfig.reset() } else { RegistryConfig.set(url) }
        AppLog.shared.log("registry set to \(RegistryConfig.current)")
        registryHint.stringValue = registryHintText()
    }

    @objc private func resetRegistry(_ sender: Any?) {
        RegistryConfig.reset()
        registryField.stringValue = RegistryConfig.current
        registryHint.stringValue = registryHintText()
        AppLog.shared.log("registry reset to \(RegistryConfig.current)")
    }

    @objc private func autoUpgradeToggled(_ sender: NSButton) {
        appDelegate?.setAutoUpgradeEnabled(sender.state == .on)
    }

    @objc private func checkUpgradeTapped(_ sender: Any?) {
        appDelegate?.upgradeDSH()
    }

    // MARK: Sync helpers

    private func syncVersion() {
        guard let delegate = appDelegate else { return }
        versionLabel?.stringValue = L10n.tr("settings.dshVersion", delegate.settingsDSHVersion())
    }

    private func registryHintText() -> String {
        let env = ProcessInfo.processInfo.environment["DSH_REGISTRY"] ?? ""
        if !env.isEmpty {
            return L10n.tr("settings.registryEnvOverride", RegistryConfig.current)
        }
        return L10n.tr("settings.registryHint", RegistryConfig.current)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
