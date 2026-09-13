// Headless tests for ShellConfig (platforms/macos/src/ShellConfig.swift):
// the legacy UserDefaults merge that keeps pre-1.14 settings from being lost
// when the shell moved them into $DSH_HOME/shell/config.json.
//
// Compiled together with a local AppLog/CoreBridge stub (no app, no core CLI).

import Foundation

var failures = 0
var passed = 0

func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond { passed += 1; print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name) \(detail)") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    check(a == b, name, "expected \(b), got \(a)")
}

// MARK: - helpers

/// 每个用例一个全新的 DSH_HOME（ShellConfig 按 DSH_HOME 解析文件路径）。
func freshHome(_ tag: String) -> String {
    let dir = NSTemporaryDirectory() + "shell-config-test-" + tag + "-\(getpid())"
    try? FileManager.default.removeItem(atPath: dir)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    setenv("DSH_HOME", dir, 1)
    return dir
}

func configPath(_ home: String) -> String { home + "/shell/config.json" }

func json(_ home: String) -> [String: Any] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath(home))),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}

func clearLegacyDefaults(_ keys: [String]) {
    for k in keys { UserDefaults.standard.removeObject(forKey: k) }
}

// MARK: - tests

/// 1.13 及以前存在的 UserDefaults 值在 1.14 迁移后必须还在（这正是
/// browserRenderMode=windowed 丢失、浏览器面板变空白的那次事故）。
func testLegacyUserDefaultsAreMigrated() {
    let home = freshHome("migrate")
    clearLegacyDefaults(ShellConfig.legacyUserDefaultsKeys)
    UserDefaults.standard.set("windowed", forKey: "browserRenderMode")
    UserDefaults.standard.set("zh", forKey: "appLanguage")
    UserDefaults.standard.set(907.0, forKey: "previewPanelWidth")
    let list = try! JSONSerialization.data(withJSONObject: [["id": "c1", "platform": "dingtalk"]])
    UserDefaults.standard.set(list, forKey: "channel.global.list")
    UserDefaults.standard.synchronize()

    // 第一次读触发迁移。
    eq(ShellConfig.shared.string(forKey: "browserRenderMode"), "windowed",
       "migrate: browserRenderMode survives the move to config.json")
    eq(ShellConfig.shared.string(forKey: "appLanguage"), "zh", "migrate: appLanguage")
    eq(Int(ShellConfig.shared.double(forKey: "previewPanelWidth")), 907, "migrate: previewPanelWidth")
    eq((ShellConfig.shared.array(forKey: "channel.global.list")?.count) ?? 0, 1,
       "migrate: channel list data decoded to JSON")

    let onDisk = json(home)
    eq(onDisk["browserRenderMode"] as? String, "windowed", "migrate: persisted to config.json")
    check(onDisk["legacyUserDefaultsMigratedAt"] != nil, "migrate: marker recorded (single shot)")

    clearLegacyDefaults(ShellConfig.legacyUserDefaultsKeys)
}

/// 迁移只做一次：之后用户（或旧版 App）再改 UserDefaults 不再覆盖 config.json。
func testMigrationRunsOnce() {
    let home = freshHome("once")
    clearLegacyDefaults(ShellConfig.legacyUserDefaultsKeys)
    UserDefaults.standard.set("windowed", forKey: "browserRenderMode")
    UserDefaults.standard.synchronize()
    eq(ShellConfig.shared.string(forKey: "browserRenderMode"), "windowed", "once: first read migrates")

    UserDefaults.standard.set("osr", forKey: "browserRenderMode")
    UserDefaults.standard.synchronize()
    eq(ShellConfig.shared.string(forKey: "browserRenderMode"), "windowed",
       "once: later UserDefaults writes do not re-migrate")
    eq(json(home)["browserRenderMode"] as? String, "windowed", "once: config.json unchanged")

    clearLegacyDefaults(ShellConfig.legacyUserDefaultsKeys)
}

/// config.json 里已有值 → 以它为准（用户在新版里改过的设置不被旧值回滚）。
func testExistingConfigWins() {
    let home = freshHome("existing")
    clearLegacyDefaults(ShellConfig.legacyUserDefaultsKeys)
    try? FileManager.default.createDirectory(atPath: home + "/shell", withIntermediateDirectories: true)
    try? Data("{\"browserRenderMode\": \"osr\"}".utf8).write(to: URL(fileURLWithPath: configPath(home)))
    UserDefaults.standard.set("windowed", forKey: "browserRenderMode")
    UserDefaults.standard.synchronize()

    eq(ShellConfig.shared.string(forKey: "browserRenderMode"), "osr", "existing: config.json wins over UserDefaults")
    eq(json(home)["browserRenderMode"] as? String, "osr", "existing: not overwritten on disk")

    clearLegacyDefaults(ShellConfig.legacyUserDefaultsKeys)
}

/// 迁移不会把无关键（AppleLanguages 等）搬进 config.json。
func testOnlyOwnedKeysAreMigrated() {
    let home = freshHome("owned")
    clearLegacyDefaults(ShellConfig.legacyUserDefaultsKeys)
    UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
    UserDefaults.standard.set("secret", forKey: "someUnrelatedKey")
    UserDefaults.standard.synchronize()
    _ = ShellConfig.shared.string(forKey: "appTheme")   // 触发加载/迁移
    let onDisk = json(home)
    check(onDisk["someUnrelatedKey"] == nil, "owned: unrelated key not migrated")
    check(onDisk["AppleLanguages"] == nil, "owned: AppleLanguages not migrated")

    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    clearLegacyDefaults(ShellConfig.legacyUserDefaultsKeys)
}

testLegacyUserDefaultsAreMigrated()
testMigrationRunsOnce()
testExistingConfigWins()
testOnlyOwnedKeysAreMigrated()

print("== shell-config tests: \(passed) passed, \(failures) failed")
if failures > 0 { exit(1) }
