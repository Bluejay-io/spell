import ComposableArchitecture
import Inject
import SwiftUI

struct ModelSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let shouldFlash: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Transcription Model")
				.font(.headline)

			ModelDownloadView(
				store: store.scope(state: \.modelDownload, action: \.modelDownload),
				shouldFlash: shouldFlash
			)
			OpenAIAPIKeyView(store: store)
		}
		.enableInjection()
	}
}
