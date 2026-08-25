import DenshaCore
import SwiftUI

public enum ServiceEditorWindowID {
    public static let value = "densha.service-editor"
}

public struct ServiceEditorWindow: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        if let request = model.serviceEditor {
            ServiceEditorForm(request: request)
                .id(request.id)
        } else {
            ContentUnavailableView(
                "Nothing to edit", systemImage: "plus.rectangle.on.folder",
                description: Text("Add a service with + in the menu bar."))
        }
    }
}

private enum ProjectChoice: Hashable {
    case ungrouped
    case existing(String)
    case new
}

private struct ServiceEditorForm: View {
    let request: AppModel.ServiceEditorRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var folder: String
    @State private var projectChoice: ProjectChoice
    @State private var newProject: String
    @State private var projectChosenByHand = false
    @State private var name: String
    @State private var command: String
    @State private var port: String
    @State private var autostart: Bool
    @State private var healthChecked: Bool
    @State private var healthKind: HealthKind
    @State private var healthPath: String
    @State private var detected: ProjectFolder?
    @State private var failure: String?

    init(request: AppModel.ServiceEditorRequest) {
        self.request = request
        let service = request.service
        _folder = State(initialValue: request.folder ?? "")
        _projectChoice = State(
            initialValue: request.newProject != nil
                ? .new : request.project.map(ProjectChoice.existing) ?? .ungrouped)
        _newProject = State(initialValue: request.newProject ?? "")
        _name = State(initialValue: service?.name ?? "web")
        _command = State(initialValue: service?.command ?? "")
        _port = State(initialValue: service?.port.map(String.init) ?? "")
        _autostart = State(initialValue: service?.autostart ?? false)
        _healthChecked = State(initialValue: service?.health != nil)
        _healthKind = State(initialValue: service?.health?.kind ?? .tcp)
        _healthPath = State(initialValue: service?.health?.path ?? "/")
    }

    private var editing: Bool { request.editing != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(folder.isEmpty ? "None chosen" : folder)
                                .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Choose…", action: chooseFolder)
                        }
                    }

                    Picker("Project", selection: projectSelection) {
                        Text("None").tag(ProjectChoice.ungrouped)
                        ForEach(model.projectNames, id: \.self) { project in
                            Text(project).tag(ProjectChoice.existing(project))
                        }
                        Divider()
                        Text("New project…").tag(ProjectChoice.new)
                    }

                    if projectChoice == .new {
                        TextField("Project name", text: $newProject, prompt: Text("storefront"))
                    }
                } footer: {
                    Text(projectHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Name", text: $name)
                    TextField("Command", text: $command, prompt: Text("pnpm dev"))
                    TextField("Port", text: $port, prompt: Text("optional"))
                        .monospacedDigit()
                }

                Section {
                    Toggle("Health check", isOn: $healthChecked)
                    if healthChecked {
                        Picker("Probe", selection: $healthKind) {
                            Text("TCP").tag(HealthKind.tcp)
                            Text("HTTP").tag(HealthKind.http)
                        }
                        .pickerStyle(.segmented)
                        if healthKind == .http {
                            TextField("Path", text: $healthPath)
                        }
                    }
                    Toggle("Start at login", isOn: $autostart)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                if let message = failure ?? problem {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(failure == nil ? .secondary : Color.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing ? "Save" : "Add Service", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!complete || problem != nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 440)
        .navigationTitle(editing ? "Edit Service" : "New Service")
    }

    private var projectSelection: Binding<ProjectChoice> {
        Binding(
            get: { projectChoice },
            set: {
                projectChoice = $0
                projectChosenByHand = true
            })
    }

    private var project: String? {
        switch projectChoice {
        case .ungrouped: nil
        case .existing(let name): name
        case .new:
            newProject.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : newProject.trimmingCharacters(in: .whitespaces)
        }
    }

    private var projectHint: String {
        switch projectChoice {
        case .ungrouped:
            return "Without a project the service keeps its bare name and starts on its own."
        case .existing(let name):
            return "Starts and stops with the rest of \(name)."
        case .new:
            guard let project else { return "Name the project these services belong to." }
            return "Creates the \(project) project, taken from the folder."
        }
    }

    private var complete: Bool {
        !folder.trimmingCharacters(in: .whitespaces).isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
            && (projectChoice != .new || project != nil)
    }

    private var problem: String? {
        let name = self.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !ConfigLoader.isValidName(name) {
            return "A name may only hold letters, digits, dot, dash and underscore."
        }
        if let project, !ConfigLoader.isValidName(project) {
            return "A project name may only hold letters, digits, dot, dash and underscore."
        }
        let qualified = ServiceName.qualified(project: project, name: name)
        if !name.isEmpty, qualified != request.editing,
            model.services.contains(where: { $0.name == qualified })
        {
            return "\(qualified) already exists."
        }
        if !port.isEmpty, portNumber == nil {
            return "A port is a number between 1 and 65535."
        }
        if healthChecked, portNumber == nil {
            return "A health check needs a port."
        }
        return nil
    }

    private var portNumber: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)),
            (1...65535).contains(value)
        else { return nil }
        return value
    }

    private func chooseFolder() {
        guard let inspected = model.inspectFolder(startingAt: folder) else { return }
        if !projectChosenByHand {
            if model.projectNames.contains(inspected.projectName) {
                projectChoice = .existing(inspected.projectName)
            } else {
                projectChoice = .new
                newProject = inspected.projectName
            }
        }
        if command.isEmpty || command == detected?.command {
            command = inspected.command ?? ""
        }
        folder = inspected.path
        detected = inspected
    }

    private func save() {
        let service = ServiceDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            port: portNumber,
            autostart: autostart,
            health: healthChecked
                ? HealthDraft(kind: healthKind, port: portNumber, path: healthPath) : nil
        )
        do {
            try model.save(
                service, project: project, folder: folder.trimmingCharacters(in: .whitespaces),
                replacing: request.editing)
            dismiss()
        } catch {
            failure = "\(error)"
        }
    }
}

#if DEBUG
    #Preview("Service editor — new") {
        ServiceEditorWindow().environment(AppModel.preview(serviceEditor: .init()))
    }

    #Preview("Service editor — editing") {
        ServiceEditorWindow().environment(
            AppModel.preview(
                serviceEditor: .init(
                    editing: "storefront/api", project: "storefront",
                    folder: "~/code/storefront-api",
                    service: ServiceDraft(
                        name: "api", command: "dotnet run --project src/Api", port: 5040))))
    }
#endif
