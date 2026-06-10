//
//  HexCapsuleView.swift
//  Hex
//
//  Created by Kit Langton on 1/25/25.

import Inject
import SwiftUI

struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject

  enum Status {
    case hidden
    case optionKeyPressed
    case recording
    case transcribing
    case prewarming
  }

  var status: Status
  var meter: Meter

  private let height: CGFloat = 30
  private let activeWidth: CGFloat = 92
  private let armedWidth: CGFloat = 56
  private let bars = 11
  private let baseHeights: [CGFloat] = [4, 6, 9, 12, 15, 17, 14, 11, 8, 6, 4]

  var isHidden: Bool {
    status == .hidden
  }

  var body: some View {
    let averagePower = normalizedAveragePower

    TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
      let phase = processingPhase(at: timeline.date)

      Capsule()
        .fill(background)
        .overlay {
          Capsule()
            .strokeBorder(border, lineWidth: 1)
        }
        .overlay(alignment: .top) {
          Capsule()
            .fill(Color.white.opacity(0.16))
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.top, 1)
        }
        .overlay {
          HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { index in
              Capsule()
                .fill(barColor(for: index, phase: phase))
                .frame(width: 3, height: barHeight(for: index, phase: phase))
                .shadow(color: .white.opacity(shadowOpacity(for: index, phase: phase)), radius: 2)
            }
          }
        }
        .overlay {
          if status == .recording {
            Capsule()
              .strokeBorder(Color.red.opacity(0.10 + averagePower * 0.20), lineWidth: 1.5)
              .blur(radius: 0.5)
              .padding(2)
              .transition(.opacity)
          }
        }
    }
    .frame(width: width(for: status), height: height)
    .opacity(status == .hidden ? 0 : 1)
    .scaleEffect(status == .hidden ? 0.82 : 1)
    .blur(radius: status == .hidden ? 6 : 0)
    .shadow(color: .black.opacity(status == .hidden ? 0 : 0.28), radius: 12, y: 7)
    .shadow(color: .red.opacity(status == .recording ? 0.10 + averagePower * 0.16 : 0), radius: 10)
    .animation(.bouncy(duration: 0.28), value: status)
    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.72), value: meter)
    .enableInjection()
  }

  private var normalizedAveragePower: Double {
    pow(min(1, meter.averagePower * 10), 0.55)
  }

  private var normalizedPeakPower: CGFloat {
    CGFloat(pow(min(1, meter.peakPower * 8), 0.5))
  }

  private var background: LinearGradient {
    LinearGradient(
      colors: [
        Color(red: 0.12, green: 0.12, blue: 0.13),
        Color(red: 0.02, green: 0.02, blue: 0.025)
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var border: Color {
    switch status {
    case .recording:
      return Color.white.opacity(0.20 + normalizedAveragePower * 0.12)
    case .transcribing, .prewarming:
      return Color.white.opacity(0.24)
    case .hidden:
      return Color.clear
    case .optionKeyPressed:
      return Color.white.opacity(0.18)
    }
  }

  private func width(for status: Status) -> CGFloat {
    switch status {
    case .hidden, .optionKeyPressed:
      return armedWidth
    case .recording, .transcribing, .prewarming:
      return activeWidth
    }
  }

  private func processingPhase(at date: Date) -> Double {
    guard status == .transcribing || status == .prewarming else { return 0 }
    return date.timeIntervalSinceReferenceDate * 5.2
  }

  private func barHeight(for index: Int, phase: Double) -> CGFloat {
    let baseHeight = baseHeights[index % baseHeights.count]

    switch status {
    case .hidden:
      return 0
    case .optionKeyPressed:
      return max(3, baseHeight * 0.45)
    case .recording:
      let centerBias = 1 - abs(CGFloat(index) - CGFloat(bars - 1) / 2) / CGFloat(bars)
      let meterLift = CGFloat(normalizedAveragePower) * (12 + centerBias * 10)
      let peakLift = normalizedPeakPower * CGFloat((index % 3) + 1) * 2
      return min(24, max(3, baseHeight * 0.30 + meterLift + peakLift))
    case .transcribing, .prewarming:
      let wave = sin(Double(index) * 0.72 + phase)
      return max(4, baseHeight * 0.55 + CGFloat(wave + 1) * 2.8)
    }
  }

  private func barColor(for index: Int, phase: Double) -> Color {
    switch status {
    case .hidden:
      return Color.clear
    case .optionKeyPressed:
      return Color.white.opacity(0.58)
    case .recording:
      return Color.white.opacity(0.78 + normalizedPeakPower * 0.16)
    case .transcribing, .prewarming:
      let highlight = (sin(Double(index) * 0.95 - phase) + 1) / 2
      return Color.white.opacity(0.52 + highlight * 0.32)
    }
  }

  private func shadowOpacity(for index: Int, phase: Double) -> Double {
    switch status {
    case .recording:
      return 0.08 + normalizedAveragePower * 0.14
    case .transcribing, .prewarming:
      let highlight = (sin(Double(index) * 0.95 - phase) + 1) / 2
      return highlight * 0.12
    case .hidden, .optionKeyPressed:
      return 0
    }
  }
}

#Preview("HEX") {
  VStack(spacing: 8) {
    TranscriptionIndicatorView(status: .hidden, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .optionKeyPressed, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.5, peakPower: 0.5))
    TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .prewarming, meter: .init(averagePower: 0, peakPower: 0))
  }
  .padding(40)
}
