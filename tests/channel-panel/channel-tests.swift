import Foundation

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

let home = NSTemporaryDirectory() + "/chanpanel-" + UUID().uuidString
let dir = (home as NSString).appendingPathComponent("channels")
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let projectA = "/Users/loie/repo/alpha"
let projectB = "/Users/loie/repo/beta"

func write(_ name: String, _ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
    try! data.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name)))
}

// sessions: 2 in projectA, 1 in projectB
write("wx-1.sessions.json", ["version": 1, "sessions": [
    ["conversationId": "conv-1", "sessionId": "sess-1", "projectRoot": projectA, "workspaceKey": "alpha", "name": "会话甲", "updatedAt": 2000],
    ["conversationId": "conv-2", "sessionId": "sess-2", "projectRoot": projectA, "workspaceKey": "alpha", "name": "会话乙", "updatedAt": 1000],
    ["conversationId": "conv-3", "sessionId": "sess-3", "projectRoot": projectB, "workspaceKey": "beta", "name": "会话丙", "updatedAt": 3000],
]])
write("wx-1.alpha.sess-1.messages.json", ["version": 1, "messages": [
    ["channelId": "wx-1", "conversationId": "conv-1", "sessionId": "sess-1", "dir": "in", "text": "你好", "ts": 1, "projectRoot": projectA],
    ["channelId": "wx-1", "conversationId": "conv-1", "sessionId": "sess-1", "dir": "out", "text": "回复", "ts": 2, "projectRoot": projectA],
]])
write("wx-1.alpha.sess-2.messages.json", ["version": 1, "messages": [
    ["channelId": "wx-1", "conversationId": "conv-2", "sessionId": "sess-2", "dir": "in", "text": "第二会话", "ts": 1, "projectRoot": projectA],
]])

let sessions = ChannelStoreReader.loadSessions(channelId: "wx-1", projectRoot: projectA, dshHome: home)
test("only sessions of projectA returned", sessions.count == 2)
test("sorted by updatedAt desc", sessions.first?.sessionId == "sess-1")
test("session carries name", sessions.first?.name == "会话甲")
test("session carries workspaceKey", sessions.first?.workspaceKey == "alpha")
test("session messages loaded", sessions.first?.messages.count == 2)
test("messages oldest first", sessions.first?.messages.first?.text == "你好")
test("empty for unknown channel", ChannelStoreReader.loadSessions(channelId: "zz", projectRoot: projectA, dshHome: home).isEmpty)
test("empty for unmatched project", ChannelStoreReader.loadSessions(channelId: "wx-1", projectRoot: "/nowhere", dshHome: home).isEmpty)

print("done")