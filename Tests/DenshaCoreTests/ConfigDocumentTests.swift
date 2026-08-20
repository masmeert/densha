import Foundation
import Testing

@testable import DenshaCore

@Suite("ConfigDocument")
struct ConfigDocumentTests {
    private let twoProjects = """
        [defaults]
        stop_timeout = 5

        [[project]]
        name = "storefront"
        cwd = "~/code/storefront"

          [[project.service]]
          name = "web"
          command = "pnpm dev"
          port = 3000

        [[project]]
        name = "warehouse"
        cwd = "~/code/warehouse"

          [[project.service]]
          name = "web"
          command = "pnpm dev"

        """

    private func parse(_ document: ConfigDocument) throws -> Config {
        try ConfigLoader.parse(Data(document.text.utf8))
    }

    @Test("a service joins the project it names, not the last one in the file")
    func serviceJoinsItsOwnProject() throws {
        var document = ConfigDocument(text: twoProjects)

        try document.add(
            ServiceDraft(name: "api", command: "go run ./cmd/api", port: 8080),
            toProject: "storefront")

        let config = try parse(document)
        #expect(config.service(named: "storefront/api")?.port == 8080)
        #expect(config.service(named: "warehouse/api") == nil)
        #expect(document.text.contains("[[project]]\nname = \"warehouse\""))
    }

    @Test("a service appended to the last project stays inside it")
    func serviceJoinsTheLastProject() throws {
        var document = ConfigDocument(text: twoProjects)

        try document.add(
            ServiceDraft(name: "worker", command: "pnpm worker"),
            toProject: "warehouse")

        #expect(try parse(document).service(named: "warehouse/worker") != nil)
    }

    @Test("a new project is appended with its first service")
    func projectIsAppended() throws {
        var document = ConfigDocument(text: twoProjects)

        try document.add(
            ProjectDraft(
                name: "atlas", cwd: "~/code/atlas",
                services: [
                    ServiceDraft(
                        name: "web", command: "npm run dev", port: 5173, autostart: true,
                        health: HealthDraft(kind: .http, port: 5173, path: "/healthz"))
                ]))

        let web = try #require(try parse(document).service(named: "atlas/web"))
        #expect(web.cwd == ConfigLoader.expandTilde("~/code/atlas"))
        #expect(web.autostart)
        #expect(web.health?.kind == .http)
        #expect(web.health?.path == "/healthz")
    }

    @Test("an ungrouped service keeps its bare name")
    func ungroupedServiceKeepsItsName() throws {
        var document = ConfigDocument(text: twoProjects)

        try document.add(
            ServiceDraft(name: "postgres", cwd: "/tmp", command: "postgres -D /tmp"),
            toProject: nil)

        #expect(try parse(document).service(named: "postgres")?.cwd == "/tmp")
    }

    @Test("comments and existing entries survive an edit")
    func commentsSurvive() throws {
        var document = ConfigDocument(text: Template.starter)

        try document.add(
            ProjectDraft(
                name: "storefront", cwd: "~/code/storefront",
                services: [ServiceDraft(name: "web", command: "pnpm dev")]))
        try document.add(ServiceDraft(name: "api", command: "go run ."), toProject: "storefront")

        #expect(document.text.hasPrefix("# Densha — services.toml"))
        #expect(document.text.contains("# name = \"postgres\""))
        #expect(try parse(document).services.map(\.name) == ["storefront/web", "storefront/api"])
    }

    @Test("an unknown project is refused")
    func unknownProjectIsRefused() {
        var document = ConfigDocument(text: twoProjects)

        #expect(throws: ConfigError.self) {
            try document.add(ServiceDraft(name: "web", command: "pnpm dev"), toProject: "atlas")
        }
    }

    @Test("a duplicate name is refused and leaves the document untouched")
    func duplicateNameIsRefused() {
        var document = ConfigDocument(text: twoProjects)

        #expect(throws: ConfigError.self) {
            try document.add(
                ServiceDraft(name: "web", command: "pnpm dev"),
                toProject: "storefront")
        }
        #expect(document.text == twoProjects)
    }

    @Test("an edited service keeps its place in the file")
    func editKeepsItsPlace() throws {
        var document = ConfigDocument(text: twoProjects)
        try document.add(
            ServiceDraft(name: "worker", command: "pnpm worker"),
            toProject: "storefront")

        try document.replace(
            ServiceDraft(name: "site", command: "pnpm dev --host", port: 4000),
            named: "storefront/web")

        let config = try parse(document)
        #expect(
            config.services.map(\.name) == [
                "storefront/site", "storefront/worker", "warehouse/web",
            ])
        #expect(config.service(named: "storefront/site")?.port == 4000)
    }

    @Test("an ungrouped service can be edited too")
    func ungroupedServiceIsEdited() throws {
        var document = ConfigDocument(text: twoProjects)
        try document.add(
            ServiceDraft(name: "postgres", cwd: "/tmp", command: "postgres"), toProject: nil)

        try document.replace(
            ServiceDraft(name: "postgres", cwd: "/tmp", command: "postgres -D /tmp", port: 5432),
            named: "postgres")

        #expect(try parse(document).service(named: "postgres")?.port == 5432)
    }

    @Test("removing a service leaves its neighbours alone")
    func removalLeavesNeighboursAlone() throws {
        var document = ConfigDocument(text: twoProjects)
        try document.add(
            ServiceDraft(name: "worker", command: "pnpm worker"),
            toProject: "storefront")

        try document.remove(serviceNamed: "storefront/web")

        #expect(try parse(document).services.map(\.name) == ["storefront/worker", "warehouse/web"])
    }

    @Test("removing the last service of a project removes the project")
    func removingTheLastServiceRemovesTheProject() throws {
        var document = ConfigDocument(text: twoProjects)

        try document.remove(serviceNamed: "warehouse/web")

        #expect(try parse(document).services.map(\.name) == ["storefront/web"])
        #expect(!document.text.contains("warehouse"))
        #expect(document.text.contains("[defaults]"))
    }

    @Test("a comment written under a service survives an edit")
    func commentUnderAServiceSurvives() throws {
        var document = ConfigDocument(
            text: """
                [[project]]
                name = "storefront"
                cwd = "~/code/storefront"

                  [[project.service]]
                  name = "web"
                  command = "pnpm dev"

                # the api lives in its own checkout
                  [[project.service]]
                  name = "api"
                  command = "go run ."

                """)

        try document.replace(
            ServiceDraft(name: "web", command: "pnpm dev --host"), named: "storefront/web")

        #expect(document.text.contains("# the api lives in its own checkout"))
        #expect(try parse(document).service(named: "storefront/web")?.command == "pnpm dev --host")
    }

    @Test("quotes and backslashes in values are escaped")
    func valuesAreEscaped() throws {
        var document = ConfigDocument(text: twoProjects)

        try document.add(
            ServiceDraft(
                name: "seed", cwd: "/tmp/a b", command: #"psql -c "select 1" \d"#),
            toProject: nil)

        #expect(try parse(document).service(named: "seed")?.command == #"psql -c "select 1" \d"#)
    }

    @Test("a project's folder is reported for services that inherit it")
    func projectFolderIsReported() {
        let document = ConfigDocument(text: twoProjects)

        #expect(document.hasProject(named: "warehouse"))
        #expect(!document.hasProject(named: "atlas"))
        #expect(document.cwd(ofProject: "storefront") == "~/code/storefront")
    }
}
