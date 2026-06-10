import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct ModelsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				ModelSectionView(store: store, shouldFlash: store.shouldFlashModelSection)

				// Only show language picker for WhisperKit models (not Parakeet or hosted models).
				if ParakeetModel(rawValue: store.hexSettings.selectedModel) == nil,
				   OpenAITranscriptionModel(rawValue: store.hexSettings.selectedModel) == nil
				{
					LanguageSectionView(store: store)
				}
			}
			.frame(maxWidth: 560, alignment: .leading)
			.padding(24)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.task {
			await store.send(.task).finish()
		}
		.enableInjection()
	}
}
