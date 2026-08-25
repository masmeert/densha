import Foundation
import Testing

@testable import DenshaCore

@Suite("ProjectFolder")
struct ProjectFolderTests {
    private func folder(
        _ files: [String: String], named directoryName: String = "checkout"
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("densha-tests-\(UUID().uuidString)")
            .appendingPathComponent(directoryName)
        for (path, contents) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("package.json names the project and its dev script starts it")
    func packageNamesTheProject() throws {
        let directory = try folder([
            "package.json": #"{"name": "storefront", "scripts": {"dev": "vite"}}"#,
            "pnpm-lock.yaml": "",
        ])

        let project = ProjectFolder.inspect(directory)

        #expect(project.projectName == "storefront")
        #expect(project.command == "pnpm dev")
    }

    @Test("a scoped package keeps only the package name")
    func scopedPackageIsUnscoped() throws {
        let directory = try folder([
            "package.json": #"{"name": "@acme/warehouse", "scripts": {"start": "node ."}}"#
        ])

        let project = ProjectFolder.inspect(directory)

        #expect(project.projectName == "warehouse")
        #expect(project.command == "npm run start")
    }

    @Test("the git remote names the project when there is no package.json")
    func gitRemoteNamesTheProject() throws {
        let directory = try folder([
            ".git/config": """
            [core]
                bare = false
            [remote "origin"]
                url = git@github.com:masmeert/densha.git
                fetch = +refs/heads/*:refs/remotes/origin/*
            """
        ])

        let project = ProjectFolder.inspect(directory)

        #expect(project.projectName == "densha")
        #expect(project.command == nil)
    }

    @Test("a repository without a remote falls back to its own folder")
    func repositoryWithoutRemoteUsesItsFolder() throws {
        let directory = try folder(
            [".git/config": "[core]\n\tbare = false\n"], named: "atlas")

        #expect(ProjectFolder.inspect(directory).projectName == "atlas")
    }

    @Test("a plain folder names the project after itself")
    func plainFolderNamesTheProject() throws {
        let directory = try folder([:], named: "side project")

        let project = ProjectFolder.inspect(directory)

        #expect(project.projectName == "side-project")
        #expect(project.command == nil)
    }

    @Test("names are reduced to characters services.toml accepts")
    func namesAreSanitized() {
        #expect(ProjectFolder.sanitized("Storefront v2 (old)") == "Storefront-v2-old")
        #expect(ProjectFolder.sanitized("--edge--") == "edge")
        #expect(ConfigLoader.isValidName(ProjectFolder.sanitized("café/api")))
    }

    @Test("an https remote is read as well as an ssh one")
    func httpsRemoteIsRead() {
        let config = """
            [remote "upstream"]
                url = https://github.com/other/upstream.git
            [remote "origin"]
                url = https://github.com/masmeert/densha
            """

        #expect(ProjectFolder.remoteName(inGitConfig: config) == "densha")
    }

    @Test("the working directory of a live process is read")
    func workingDirectoryIsRead() {
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL.path
        let found = ProjectFolder.workingDirectory(of: getpid())
        #expect(found.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == expected)
        #expect(ProjectFolder.inspect(pid: getpid()) != nil)
        #expect(ProjectFolder.workingDirectory(of: -1) == nil)
    }

}
