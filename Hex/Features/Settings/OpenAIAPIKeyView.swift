import ComposableArchitecture
import Inject
import SwiftUI

struct OpenAIAPIKeyView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Image(systemName: store.hasOpenAIAPIKey ? "checkmark.seal.fill" : "key")
					.foregroundStyle(store.hasOpenAIAPIKey ? .green : .secondary)
					.frame(width: 20)

				SecureField(
					store.hasOpenAIAPIKey ? "OpenAI API key saved" : "OpenAI API key",
					text: Binding(
						get: { store.openAIAPIKeyInput },
						set: { store.send(.setOpenAIAPIKeyInput($0)) }
					)
				)
				.textFieldStyle(.roundedBorder)

				Button("Save") {
					store.send(.saveOpenAIAPIKey)
				}
				.disabled(store.openAIAPIKeyInput.isEmpty)

				if store.hasOpenAIAPIKey {
					Button("Remove", role: .destructive) {
						store.send(.deleteOpenAIAPIKey)
					}
				}
			}

			Button {
				store.send(.openOpenAIAPIKeysConsole)
			} label: {
				Label("Create an OpenAI API key", systemImage: "arrow.up.right.square")
			}
			.buttonStyle(.link)

			if let message = store.openAIAPIKeyMessage {
				Text(message)
					.font(.caption)
					.foregroundStyle(store.hasOpenAIAPIKey ? Color.secondary : Color.red)
			}
		}
		.enableInjection()
	}
}
