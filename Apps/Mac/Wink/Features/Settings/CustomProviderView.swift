import WinkCore
import SwiftUI

/// Custom provider management view for adding, editing, and removing AI providers
struct CustomProviderView: View {
    @Environment(WinkSettings.self) private var settings
    @State private var showingAddProvider = false
    @State private var providerToEdit: IdentifiableCustomProvider?
    @State private var selectedProviderId: String?
    @State private var showingDeleteConfirmation = false
    @State private var testResults: [String: (success: Bool, message: String)] = [:]
    @State private var isTestingConnection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Custom Providers")
                    .font(.headline)

                Spacer()

                Button("Add Provider") {
                    self.showingAddProvider = true
                }
                .buttonStyle(.borderedProminent)
            }

            // Provider list
            if self.settings.customProviders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)

                    Text("No Custom Providers")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text(
                        "Add custom AI providers to connect to additional endpoints like OpenRouter, " +
                            "Groq, or self-hosted models.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(
                            Array(self.settings.customProviders.sorted(by: { $0.key < $1.key })),
                            id: \.key)
                        { id, provider in
                            CustomProviderRowView(
                                id: id,
                                provider: provider,
                                isSelected: self.settings.selectedProvider == id,
                                testResult: self.testResults[id],
                                isTesting: self.isTestingConnection.contains(id),
                                onSelect: {
                                    self.settings.selectCustomProvider(id: id)
                                },
                                onEdit: {
                                    self.providerToEdit = IdentifiableCustomProvider((id, provider))
                                },
                                onDelete: {
                                    self.selectedProviderId = id
                                    self.showingDeleteConfirmation = true
                                },
                                onTest: {
                                    self.testConnection(for: id)
                                })
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .sheet(isPresented: self.$showingAddProvider) {
            AddCustomProviderView()
        }
        .sheet(item: self.$providerToEdit) { editInfo in
            EditCustomProviderView(providerId: editInfo.id, provider: editInfo.provider)
        }
        .confirmationDialog(
            "Delete Provider",
            isPresented: self.$showingDeleteConfirmation,
            titleVisibility: .visible)
        {
            Button("Delete", role: .destructive) {
                if let id = selectedProviderId {
                    self.deleteProvider(id: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let id = selectedProviderId,
               let provider = settings.customProviders[id]
            {
                Text("Are you sure you want to delete '\(provider.name)'? This action cannot be undone.")
            }
        }
    }

    private func testConnection(for id: String) {
        self.isTestingConnection.insert(id)
        self.testResults[id] = nil

        Task {
            let (success, error) = await settings.testCustomProvider(id: id)
            await MainActor.run {
                self.isTestingConnection.remove(id)
                self.testResults[id] = (success, error ?? (success ? "Connection successful" : "Connection failed"))
            }
        }
    }

    private func deleteProvider(id: String) {
        do {
            try self.settings.removeCustomProvider(id: id)
            self.testResults.removeValue(forKey: id)
        } catch {
            // Show error alert
            print("Failed to delete provider: \(error)")
        }
    }
}

/// Individual custom provider row
struct CustomProviderRowView: View {
    let id: String
    let provider: Configuration.CustomProvider
    let isSelected: Bool
    let testResult: (success: Bool, message: String)?
    let isTesting: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTest: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(self.provider.name)
                        .font(.headline)

                    if self.isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }

                    Spacer()

                    // Provider type badge
                    Text(self.provider.type.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }

                Text(self.provider.options.baseURL)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let description = provider.description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                // Test result
                if let result = testResult {
                    HStack {
                        Image(systemName: result.success ? "checkmark.circle" : "xmark.circle")
                            .foregroundColor(result.success ? .green : .red)
                        Text(result.message)
                            .font(.caption)
                            .foregroundColor(result.success ? .green : .red)
                    }
                } else if self.isTesting {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Testing connection...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            VStack(spacing: 4) {
                Button("Select") {
                    self.onSelect()
                }
                .buttonStyle(.bordered)
                .disabled(self.isSelected)

                HStack(spacing: 4) {
                    Button("Test") {
                        self.onTest()
                    }
                    .buttonStyle(.bordered)
                    .disabled(self.isTesting)

                    Button("Edit") {
                        self.onEdit()
                    }
                    .buttonStyle(.bordered)

                    Button("Delete") {
                        self.onDelete()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// Old AddCustomProviderView has been moved to a separate file with a modern redesign

/// Edit custom provider sheet
struct EditCustomProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WinkSettings.self) private var settings

    let providerId: String
    private let originalProvider: Configuration.CustomProvider
    @State private var name: String
    @State private var description: String
    @State private var type: Configuration.CustomProvider.ProviderType
    @State private var modelIds: String
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var headers: String
    @State private var showingError = false
    @State private var errorMessage = ""

    init(providerId: String, provider: Configuration.CustomProvider) {
        self.providerId = providerId
        self.originalProvider = provider
        self._name = State(initialValue: provider.name)
        self._description = State(initialValue: provider.description ?? "")
        self._type = State(initialValue: provider.type)
        self._modelIds = State(initialValue: provider.models?.keys.sorted().joined(separator: ", ") ?? "")
        self._baseURL = State(initialValue: provider.options.baseURL)
        self._apiKey = State(initialValue: provider.options.apiKey)

        // Convert headers back to string
        let headersString = provider.options.headers?.map { "\($0.key):\($0.value)" }.joined(separator: ",") ?? ""
        self._headers = State(initialValue: headersString)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Basic Information") {
                    HStack {
                        Text("Provider ID")
                            .frame(width: 100, alignment: .trailing)
                        Text(self.providerId)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Name")
                            .frame(width: 100, alignment: .trailing)
                        TextField("OpenRouter", text: self.$name)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Description")
                            .frame(width: 100, alignment: .trailing)
                        TextField("Access to 300+ models", text: self.$description)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Configuration") {
                    HStack {
                        Text("Type")
                            .frame(width: 100, alignment: .trailing)
                        Picker("Type", selection: self.$type) {
                            ForEach(Configuration.CustomProvider.ProviderType.allCases, id: \.self) { providerType in
                                Text(providerType.displayName).tag(providerType)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Text("Base URL")
                            .frame(width: 100, alignment: .trailing)
                        TextField("https://openrouter.ai/api/v1", text: self.$baseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Model IDs")
                            .frame(width: 100, alignment: .trailing)
                        TextField("model-id, another-model-id", text: self.$modelIds)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("API Key")
                            .frame(width: 100, alignment: .trailing)
                        TextField("${OPENROUTER_API_KEY}", text: self.$apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Headers")
                            .frame(width: 100, alignment: .trailing)
                        TextField("key:value,key:value", text: self.$headers)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Custom Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        self.dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        self.saveProvider()
                    }
                    .disabled(!self.isValid)
                }
            }
        }
        .frame(width: 500, height: 500)
        .alert("Error", isPresented: self.$showingError) {
            Button("OK") {}
        } message: {
            Text(self.errorMessage)
        }
    }

    private var isValid: Bool {
        !self.name.isEmpty &&
            Self.canSaveModels(self.modelIdentifiers, originalProvider: self.originalProvider) &&
            !self.baseURL.isEmpty &&
            !self.apiKey.isEmpty
    }

    private var modelIdentifiers: [String] {
        Set(self.modelIds.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }).sorted()
    }

    private func saveProvider() {
        // Parse headers
        var headerDict: [String: String]?
        if !self.headers.isEmpty {
            headerDict = [:]
            let pairs = self.headers.split(separator: ",")
            for pair in pairs {
                let components = pair.split(separator: ":", maxSplits: 1)
                if components.count == 2 {
                    let key = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    headerDict?[key] = value
                }
            }
        }

        let editedProvider = Configuration.CustomProvider(
            name: self.name,
            description: self.description.isEmpty ? nil : self.description,
            type: self.type,
            options: Configuration.ProviderOptions(
                baseURL: self.baseURL,
                apiKey: self.apiKey,
                headers: headerDict),
            models: Self.editedModels(
                modelIdentifiers: self.modelIdentifiers,
                originalProvider: self.originalProvider))
        let provider = Self.preservingMetadata(from: self.originalProvider, in: editedProvider)

        do {
            try self.settings.replaceCustomProvider(provider, id: self.providerId)
            self.dismiss()
        } catch {
            self.errorMessage = error.localizedDescription
            self.showingError = true
        }
    }

    static func canSaveModels(
        _ modelIdentifiers: [String],
        originalProvider: Configuration.CustomProvider) -> Bool
    {
        !modelIdentifiers.isEmpty || originalProvider.models?.isEmpty != false
    }

    static func editedModels(
        modelIdentifiers: [String],
        originalProvider: Configuration.CustomProvider) -> [String: Configuration.ModelDefinition]?
    {
        guard !modelIdentifiers.isEmpty else {
            return originalProvider.models?.isEmpty == true ? [:] : nil
        }
        return Dictionary(uniqueKeysWithValues: modelIdentifiers.map {
            ($0, Configuration.ModelDefinition(name: $0))
        })
    }

    static func preservingMetadata(
        from original: Configuration.CustomProvider,
        in edited: Configuration.CustomProvider) -> Configuration.CustomProvider
    {
        let options = Configuration.ProviderOptions(
            baseURL: edited.options.baseURL,
            apiKey: edited.options.apiKey,
            headers: edited.options.headers,
            timeout: original.options.timeout,
            retryAttempts: original.options.retryAttempts,
            defaultParameters: original.options.defaultParameters)

        let models = edited.models.map { editedModels in
            Dictionary(uniqueKeysWithValues: editedModels.map { id, definition in
                (id, original.models?[id] ?? definition)
            })
        } ?? original.models

        return Configuration.CustomProvider(
            name: edited.name,
            description: edited.description,
            type: edited.type,
            options: options,
            models: models,
            enabled: original.enabled)
    }
}

/// Helper struct to make tuple identifiable for sheet presentation
struct IdentifiableCustomProvider: Identifiable {
    let id: String
    let provider: Configuration.CustomProvider

    init(_ tuple: (String, Configuration.CustomProvider)) {
        self.id = tuple.0
        self.provider = tuple.1
    }
}
