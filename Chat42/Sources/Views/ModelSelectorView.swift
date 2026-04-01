import SwiftUI

struct ModelSelectorView: View {
    @Environment(AppState.self) private var state
    @Environment(MLXService.self) private var mlxService

    var body: some View {
        HStack(spacing: 6) {
            Picker(String(localized: "model.backend.label"), selection: Binding(
                get: { state.activeBackend },
                set: { state.activeBackend = $0 }
            )) {
                ForEach(AIBackend.allCases, id: \.self) { backend in
                    Label(backend.rawValue, systemImage: backend == .ollama ? "server.rack" : "apple.terminal")
                        .tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .labelsHidden()

            Divider().frame(height: 20)

            switch state.activeBackend {
            case .ollama:   ollamaModelPicker
            case .mlx:      mlxModelPicker
            case .gateway:  gatewayModelPicker
            }

                    if state.activeBackend == .ollama {
                Button {
                    Task { await state.refreshOllamaModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(state.isLoadingModels ? .degrees(360) : .zero)
                        .animation(state.isLoadingModels
                                   ? .linear(duration: 1).repeatForever(autoreverses: false)
                                   : .default,
                                   value: state.isLoadingModels)
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .help(String(localized: "model.refresh.help"))
                .disabled(state.isLoadingModels)
            } else if state.activeBackend == .gateway {
                Button {
                    Task { await state.refreshGatewayModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(state.isLoadingGatewayModels ? .degrees(360) : .zero)
                        .animation(state.isLoadingGatewayModels
                                   ? .linear(duration: 1).repeatForever(autoreverses: false)
                                   : .default,
                                   value: state.isLoadingGatewayModels)
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .help(String(localized: "model.refresh.help"))
                .disabled(state.isLoadingGatewayModels)
            }
        }
    }

    // MARK: - Ollama picker

    private var ollamaModelPicker: some View {
        Group {
            if state.ollamaModels.isEmpty {
                Menu {
                    if !state.ollamaReachable {
                        Label(String(localized: "model.ollama.not_running"), systemImage: "exclamationmark.triangle")
                    } else {
                        Label(String(localized: "model.ollama.no_models"), systemImage: "tray")
                        Divider()
                        Link(String(localized: "model.ollama.open_docs"),
                             destination: URL(string: "https://ollama.com/library")!)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.ollamaReachable ? Color.orange : Color.red)
                            .frame(width: 6, height: 6)
                        Text(state.ollamaReachable
                             ? String(localized: "model.ollama.no_models_short")
                             : String(localized: "model.ollama.offline"))
                            .font(.callout)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            } else {
                Menu {
                    ForEach(state.ollamaModels) { model in
                        Button {
                            state.selectedOllamaModel = model
                        } label: {
                            HStack {
                                Text(model.name)
                                if model.name == state.selectedOllamaModel?.name {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text(state.selectedOllamaModel?.name ?? String(localized: "model.ollama.select"))
                            .font(.callout)
                            .fontWeight(.medium)
                        if let size = state.selectedOllamaModel?.sizeFormatted, !size.isEmpty {
                            Text(size).font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Gateway picker

    private var gatewayModelPicker: some View {
        Group {
            if state.gatewayModels.isEmpty {
                Menu {
                    if !state.gatewayReachable {
                        Label(String(localized: "model.gateway.not_connected"), systemImage: "exclamationmark.triangle")
                    } else {
                        Label(String(localized: "model.gateway.no_models"), systemImage: "tray")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.gatewayReachable ? Color.orange : Color.red)
                            .frame(width: 6, height: 6)
                        Text(state.gatewayReachable
                             ? String(localized: "model.gateway.no_models_short")
                             : String(localized: "model.gateway.offline"))
                            .font(.callout)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            } else {
                Menu {
                    ForEach(state.gatewayModels) { model in
                        Button {
                            state.selectedGatewayModel = model
                        } label: {
                            HStack {
                                Text(model.displayName)
                                if model.id == state.selectedGatewayModel?.id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text(state.selectedGatewayModel?.displayName ?? String(localized: "model.gateway.select"))
                            .font(.callout)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - MLX picker

    private var mlxModelPicker: some View {
        Menu {
            ForEach(MLXModelInfo.bundled) { model in
                Button {
                    state.selectedMLXModel = model
                    Task { try? await mlxService.loadModel(repoId: model.repoId) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.name)
                            Text(model.description).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.id == mlxService.loadedModelId {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if mlxService.isLoading {
                    ProgressView().scaleEffect(0.6).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "apple.terminal")
                        .font(.caption)
                        .foregroundStyle(mlxService.loadedModelId != nil ? .green : .secondary)
                }
                Text(state.selectedMLXModel?.name ?? String(localized: "model.mlx.select"))
                    .font(.callout)
                    .fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
    }
}
