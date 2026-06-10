import Foundation

enum OpenAITranscriptionModel: String, CaseIterable, Sendable {
	case fast = "openai:gpt-4o-mini-transcribe"
	case accurate = "openai:gpt-4o-transcribe"

	var apiModel: String {
		switch self {
		case .fast:
			return "gpt-4o-mini-transcribe"
		case .accurate:
			return "gpt-4o-transcribe"
		}
	}

	var displayName: String {
		switch self {
		case .fast:
			return "OpenAI Fast"
		case .accurate:
			return "OpenAI Accurate"
		}
	}

	var description: String {
		switch self {
		case .fast:
			return "Low-latency hosted transcription"
		case .accurate:
			return "Higher-accuracy hosted transcription"
		}
	}

	var accuracyStars: Int {
		switch self {
		case .fast:
			return 4
		case .accurate:
			return 5
		}
	}

	var speedStars: Int {
		switch self {
		case .fast:
			return 5
		case .accurate:
			return 4
		}
	}
}
