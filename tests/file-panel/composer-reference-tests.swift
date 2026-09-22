import Foundation

// Headless tests for the Files panel → composer reference grammar
// (ComposerReference.swift). The rules mirror dsh's own @-token grammar
// (@deepseek-ai/dsh-file-reference/grammar): what the composer has to receive,
// and what a path the grammar cannot carry must NOT become.
// Usage: tests/file-panel/run.sh

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

let root = "/Users/dev/project"

// MARK: files

test("a plain file is the bare @ + workspace-relative path",
     ComposerReferenceFormatter.mention(path: root + "/src/foo.ts", root: root, isDirectory: false)
        == ComposerReference(text: "@src/foo.ts", label: "foo.ts", appearance: "file"))
test("nesting is kept whole",
     ComposerReferenceFormatter.mention(path: root + "/a/b/c/deep.swift", root: root, isDirectory: false)?.text
        == "@a/b/c/deep.swift")
test("a trailing slash on the path does not leak into the token",
     ComposerReferenceFormatter.mention(path: root + "/src/foo.ts/", root: root, isDirectory: false)?.text
        == "@src/foo.ts")
test("'..' is resolved before the path is made relative",
     ComposerReferenceFormatter.mention(path: root + "/src/../foo.ts", root: root, isDirectory: false)?.text
        == "@foo.ts")
test("the label is the file name, not the path",
     ComposerReferenceFormatter.mention(path: root + "/a/b/c.txt", root: root, isDirectory: false)?.label == "c.txt")

// MARK: folders

test("a folder is marked by a trailing slash",
     ComposerReferenceFormatter.mention(path: root + "/src", root: root, isDirectory: true)
        == ComposerReference(text: "@src/", label: "src", appearance: "folder"))
test("a nested folder keeps its path",
     ComposerReferenceFormatter.mention(path: root + "/src/components", root: root, isDirectory: true)?.text
        == "@src/components/")

// MARK: whitespace (dsh's quoted form)

test("a file with a space is quoted and closed",
     ComposerReferenceFormatter.mention(path: root + "/my dir/file name.txt", root: root, isDirectory: false)?.text
        == "@\"my dir/file name.txt\"")
test("a folder with a space keeps its quote OPEN (dsh completion descends with it)",
     ComposerReferenceFormatter.mention(path: root + "/my dir", root: root, isDirectory: true)?.text
        == "@\"my dir/")
test("a CJK name needs no quotes",
     ComposerReferenceFormatter.mention(path: root + "/文档/说明.md", root: root, isDirectory: false)?.text
        == "@文档/说明.md")

// MARK: what must NOT become a reference

test("the project root itself has no relative path", 
     ComposerReferenceFormatter.mention(path: root, root: root, isDirectory: true) == nil)
test("a path outside the workspace is refused (it would not resolve)",
     ComposerReferenceFormatter.mention(path: "/Users/dev/other/file.txt", root: root, isDirectory: false) == nil)
test("a sibling sharing the root's prefix is outside it, not inside",
     ComposerReferenceFormatter.mention(path: root + "-backup/file.txt", root: root, isDirectory: false) == nil)
test("a quote in the name cannot be represented",
     ComposerReferenceFormatter.mention(path: root + "/we\"ird.txt", root: root, isDirectory: false) == nil)
test("a newline in the name cannot be represented",
     ComposerReferenceFormatter.mention(path: root + "/two\nlines.txt", root: root, isDirectory: false) == nil)
test("the filesystem root cannot be a workspace root for references",
     ComposerReferenceFormatter.mention(path: "/etc/hosts", root: "/", isDirectory: false) == nil)
test("an empty relative path is refused",
     ComposerReferenceFormatter.mention(relativePath: "", isDirectory: true) == nil)

// MARK: the relative form on its own (what the panel hands to the formatter)

test("a relative folder keeps exactly one trailing slash",
     ComposerReferenceFormatter.mention(relativePath: "src//", isDirectory: true)?.text == "@src/")
test("a relative path without a name is refused",
     ComposerReferenceFormatter.mention(relativePath: "/", isDirectory: false) == nil)

print("done")
