import SwiftUI

@main
struct AgentLabApp: App {
    #if AGENT_DEVKIT
    @NSApplicationDelegateAdaptor(TestingSession.self) private var testingSession
    #else
    @State private var model = LabModel()
    #endif

    var body: some Scene {
        Window("AgentLab", id: LabRoute.windowID) {
            #if AGENT_DEVKIT
            WorkspaceView(model: testingSession.model)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        Label(testingSession.bridge.statusText, systemImage: "hammer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("status.agent-testing")
                        Spacer()
                        #if ADK_LOOPBACK
                        if testingSession.bridge.usesPairing {
                            if testingSession.bridge.paired {
                                Button("Forget Pairing", action: testingSession.bridge.forgetPairing)
                            } else {
                                Button("Pair Folder…", action: testingSession.bridge.pair)
                            }
                        }
                        #endif
                    }
                    .padding(10)
                    .background(.bar)
                }
            #else
            WorkspaceView(model: model)
                .task { model.configureDefaultStore() }
            #endif
        }
        .defaultSize(width: 860, height: 550)
    }
}

private struct WorkspaceView: View {
    let model: LabModel

    var body: some View {
        let presentation = model.presentationID
        NavigationSplitView {
            VStack(spacing: 4) {
                sidebarButton("Home", icon: "house", route: .home)
                sidebarButton("Projects", icon: "folder", route: .projects)
                sidebarButton("Settings", icon: "gearshape", route: .settings)
                Spacer(minLength: 0)
            }
            .padding(12)
            .navigationSplitViewColumnWidth(min: 145, ideal: 175)
        } detail: {
            VStack(alignment: .leading, spacing: 14) {
                if let error = model.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("status.storage-error")
                }
                if model.destination.route.requiresProject && model.documentPhase != .ready {
                    documentStatus
                } else {
                    page
                        .onAppear { model.didAppear(presentation) }
                        .onDisappear { model.didDisappear(presentation) }
                        .id(presentation)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .task(id: presentation) { await model.fetchDocument(presentation) }
        }
        .frame(minWidth: 650, minHeight: 420)
        .preferredColorScheme(colorScheme)
        .tint(accentColor)
        .sheet(item: Binding(get: { model.projectForm }, set: { form in
            if form == nil { model.dismissProjectForm() }
        })) { form in
            ProjectForm(form: form) { draft in
                try model.saveProject(draft, id: form.projectId)
                model.dismissProjectForm(form.id)
            } cancel: {
                model.dismissProjectForm(form.id)
            }
            .onAppear { model.projectFormDidAppear(form.id) }
            .onDisappear { model.dismissProjectForm(form.id) }
        }
    }

    @ViewBuilder
    private var documentStatus: some View {
        switch model.documentPhase {
        case .failed, .idle:
            VStack(spacing: 12) {
                Label(model.documentPhase == .failed ? "Document unavailable" : "Load interrupted",
                      systemImage: "exclamationmark.triangle")
                    .font(.title2)
                    .accessibilityIdentifier("status.document.error")
                Text("The project could not be loaded.").foregroundStyle(.secondary)
                Button("Retry", action: model.retryDocument)
                    .accessibilityIdentifier("document.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading, .ready:
            ProgressView("Loading document…")
                .accessibilityIdentifier("status.document.loading")
        }
    }

    private var colorScheme: ColorScheme? {
        switch model.previewAppearance.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var accentColor: Color? {
        switch model.previewAppearance.accent {
        case .system: nil
        case .blue: .blue
        case .purple: .purple
        case .orange: .orange
        }
    }

    private func sidebarButton(_ label: String, icon: String, route: LabRoute) -> some View {
        Button {
            model.present(Destination(route: route))
        } label: {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.horizontal, 6)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nav.\(route.rawValue)")
    }

    @ViewBuilder
    private var page: some View {
        switch model.destination.route {
        case .home:
            ContentUnavailableView(
                "AgentLab", systemImage: "square.stack.3d.up",
                description: Text("Open Projects to organize your workspace.")
            )
            .accessibilityIdentifier(LabRoute.home.accessibilityID)
        case .projects:
            ProjectsPage(projects: model.workspace.projects) { project in
                model.present(Destination(route: .editor, projectId: project.id))
            } create: {
                model.openProjectForm()
            }
        case .editor:
            if let project = model.project {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(project.name).font(.largeTitle)
                            .accessibilityIdentifier(LabRoute.editor.accessibilityID)
                        Spacer()
                        Button("Project Details") { model.openProjectForm(project) }
                            .accessibilityIdentifier("project.details")
                    }
                    if let summary = project.summary, !summary.isEmpty {
                        Text(summary).foregroundStyle(.secondary)
                            .accessibilityIdentifier("project.summary")
                    }
                    List(project.nodes) { node in
                        Button {
                            model.present(Destination(route: .inspector, projectId: project.id, nodeId: node.id))
                        } label: {
                            Label(node.name, systemImage: "doc.text")
                                .lineLimit(2)
                        }
                        .accessibilityIdentifier("node.open.\(node.id)")
                    }
                }
            }
        case .inspector:
            if let project = model.project, let node = model.node {
                InspectorPage(project: project, node: node, save: { try? model.saveNode($0) }) {
                    model.present(Destination(route: .editor, projectId: project.id))
                }
            }
        case .settings:
            Text("Settings").font(.largeTitle).accessibilityIdentifier(LabRoute.settings.accessibilityID)
            Button("Advanced") { model.present(Destination(route: .advanced)) }
                .accessibilityIdentifier("settings.advanced")
            Button("Controls") { model.present(Destination(route: .controls)) }
                .accessibilityIdentifier("settings.controls")
        case .controls:
            ControlsPage(model: model)
        case .advanced:
            Text("Advanced").font(.largeTitle).accessibilityIdentifier(LabRoute.advanced.accessibilityID)
            Button("Appearance") { model.present(Destination(route: .appearance)) }
                .accessibilityIdentifier("settings.appearance")
        case .appearance:
            AppearancePage(model: model)
        }
    }
}

private struct ProjectsPage: View {
    let projects: [Workspace.Project]
    let open: (Workspace.Project) -> Void
    let create: () -> Void
    @State private var search = ""

    private var matches: [Workspace.Project] {
        search.isEmpty ? projects : projects.filter { $0.name.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects").font(.largeTitle).accessibilityIdentifier(LabRoute.projects.accessibilityID)
                Spacer()
                Button("New Project", systemImage: "plus", action: create)
                    .accessibilityIdentifier("project.new")
            }
            TextField("Search projects", text: $search)
                .accessibilityIdentifier("projects.search")
            if matches.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No Projects" : "No Results", systemImage: "folder"
                )
                .accessibilityIdentifier("projects.empty")
            } else {
                List(matches) { project in
                    Button(project.name) { open(project) }
                        .accessibilityIdentifier("project.open.\(project.id)")
                }
            }
        }
    }
}

private struct ProjectForm: View {
    let form: ProjectFormState
    let save: (ProjectDraft) throws -> Void
    let cancel: () -> Void
    @State private var draft: ProjectDraft
    @State private var saveFailed = false

    init(form: ProjectFormState, save: @escaping (ProjectDraft) throws -> Void, cancel: @escaping () -> Void) {
        self.form = form
        self.save = save
        self.cancel = cancel
        _draft = State(initialValue: form.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(form.projectId == nil ? "New Project" : "Project Details")
                .font(.title2)
                .accessibilityIdentifier("project.form")
            Form {
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier("project.form.name")
                TextField("Summary", text: $draft.summary, axis: .vertical)
                    .accessibilityIdentifier("project.form.summary")
            }
            if saveFailed {
                Label("The project could not be saved.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("project.form.cancel")
                Button("Save") {
                    do { try save(draft) }
                    catch { saveFailed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.valid)
                .accessibilityIdentifier("project.form.save")
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct InspectorPage: View {
    let project: Workspace.Project
    let node: Workspace.Node
    let save: (Workspace.Node) -> Void
    let back: () -> Void
    @State private var name: String?
    @State private var notes: String?
    @State private var enabled: Bool?

    private var draft: Workspace.Node {
        var draft = node
        draft.name = name ?? node.name
        draft.notes = notes ?? node.notes
        draft.enabled = enabled ?? node.enabled
        return draft
    }

    private var titleLineLimit: Int? {
        #if AGENT_DEVKIT
        if CommandLine.arguments.contains("--agentdevkit-legacy-overflow") { return 1 }
        #endif
        return nil
    }

    private var nodeTitle: some View {
        Text(node.name)
            .font(.title2)
            .lineLimit(titleLineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("inspector.node-title")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Back to Editor", systemImage: "chevron.left", action: back)
                Text("Inspector").font(.largeTitle)
                    .accessibilityIdentifier(LabRoute.inspector.accessibilityID)
                nodeTitle
                Form {
                    TextField("Name", text: Binding(get: { name ?? node.name }, set: { name = $0 }))
                        .accessibilityIdentifier("field.node.name")
                    TextField("Notes", text: Binding(get: { notes ?? node.notes }, set: { notes = $0 }), axis: .vertical)
                        .accessibilityIdentifier("field.node.notes")
                    Toggle("Enabled", isOn: Binding(get: { enabled ?? node.enabled }, set: { enabled = $0 }))
                    if !draft.valid {
                        Text("Enter a name up to 512 bytes and notes up to 2,048 bytes.")
                            .foregroundStyle(.red)
                    }
                }
                Button("Save") {
                    save(draft)
                }
                .disabled(!draft.valid)
                .accessibilityIdentifier("button.inspector.save")
            }
        }
        .navigationTitle(project.name)
    }
}

/// A disk-cleanup style screen: a map-detail slider in a popover, a menu button, a disclosure, and a
/// cleanup queue whose rows copy their identifier onto the checkbox (left in on purpose for `ui tree --lint`).
private struct ControlsPage: View {
    let model: LabModel
    @State private var showDisplay = false
    @FocusState private var queueFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controls").font(.largeTitle).accessibilityIdentifier(LabRoute.controls.accessibilityID)
            HStack(spacing: 12) {
                Button("Display…") { showDisplay = true }
                    .accessibilityIdentifier("controls.display")
                    .popover(isPresented: Binding(get: { showDisplay }, set: { shown in
                        showDisplay = shown
                        model.setDisplayPopover(shown)
                    }), arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Map detail").font(.headline)
                            Slider(value: Binding(get: { model.detailLevel }, set: { model.setDetail($0) }), in: 0...4, step: 1)
                                .frame(width: 220)
                                .accessibilityIdentifier("controls.detail")
                                .accessibilityValue(model.detailName)
                            Text(model.detailName).accessibilityIdentifier("controls.detail.name")
                        }
                        .padding(16)
                        .onAppear { model.setDisplayPopover(true) }
                        .onDisappear { model.setDisplayPopover(false) }
                    }
                Menu("Density: \(model.density.title)") {
                    ForEach(LabModel.Density.allCases) { density in
                        Button(density.title) { model.setDensity(density) }
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("controls.density")
                Button("Import…") { Task { _ = await model.chooseImportFolder() } }
                    .accessibilityIdentifier("controls.import")
                if let folder = model.importedFolder {
                    Text("Imported \(folder)").foregroundStyle(.secondary).accessibilityIdentifier("controls.imported")
                }
            }
            DisclosureGroup("Advanced", isExpanded: Binding(get: { model.advancedExpanded }, set: { model.setAdvanced($0) })) {
                Toggle("Show hidden files", isOn: Binding(get: { model.showHidden }, set: { model.setShowHidden($0) }))
                    .accessibilityIdentifier("controls.hidden")
            }
            .accessibilityIdentifier("controls.advanced")
            Text("Cleanup queue").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Toggle(item.name, isOn: Binding(get: { item.queued }, set: { _ in model.toggleQueue(item.name) }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("queueCheckbox")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(index == model.highlighted ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
                    .contentShape(.rect)
                    .onHover { inside in model.setHovered(inside ? item.name : (model.hovered == item.name ? nil : model.hovered)) }
                    // The row's identifier is copied onto its checkbox, as in the DiskUnbloat report.
                    .accessibilityIdentifier("queueRow")
                }
            }
            .frame(maxWidth: 360)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cleanupQueue")
            .focusable()
            .focused($queueFocused)
            .onKeyPress(.downArrow) { model.moveHighlight(1); return .handled }
            .onKeyPress(.upArrow) { model.moveHighlight(-1); return .handled }
            .onKeyPress(.space) { model.toggleQueue(model.queue[model.highlighted].name); return .handled }
            if let hovered = model.hovered {
                Text("\(hovered): \(model.queue.first { $0.name == hovered }.map { ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) } ?? "")")
                    .padding(6)
                    .background(.thickMaterial, in: .rect(cornerRadius: 6))
                    .accessibilityIdentifier("controls.hover-card")
            }
            Text("Map").font(.headline)
            HStack(spacing: 6) {
                ForEach(model.mapItems, id: \.self) { name in
                    Text(name)
                        .padding(.horizontal, 8)
                        .padding(.vertical, CGFloat(4 + model.detailLevel * 2))
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                        .accessibilityIdentifier("map.\(name)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("map")
        }
        .onAppear { queueFocused = true }
    }
}

private struct AppearancePage: View {
    let model: LabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance").font(.largeTitle).accessibilityIdentifier(LabRoute.appearance.accessibilityID)
            Picker("Theme", selection: Binding(get: { model.previewAppearance.theme }, set: { theme in
                var preview = model.previewAppearance
                preview.theme = theme
                model.updateAppearance(preview)
            })) {
                ForEach(Workspace.Theme.allCases, id: \.self) { theme in
                    Text(theme.rawValue.capitalized).tag(theme)
                }
            }
            .accessibilityIdentifier("settings.theme")
            Picker("Accent", selection: Binding(get: { model.previewAppearance.accent }, set: { accent in
                var preview = model.previewAppearance
                preview.accent = accent
                model.updateAppearance(preview)
            })) {
                ForEach(Workspace.Accent.allCases, id: \.self) { accent in
                    Text(accent.rawValue.capitalized).tag(accent)
                }
            }
            .accessibilityIdentifier("settings.accent")
            if model.appearanceDirty {
                Label("Unsaved preview", systemImage: "circle.lefthalf.filled")
                    .accessibilityIdentifier("settings.appearance.dirty")
            }
            HStack {
                Button("Reset", action: model.resetAppearance)
                    .accessibilityIdentifier("settings.appearance.reset")
                Button("Save") { try? model.saveAppearance(model.previewAppearance) }
                    .accessibilityIdentifier("settings.theme.save")
            }
            .disabled(!model.appearanceDirty)
        }
    }
}
