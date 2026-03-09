import SwiftUI
import AVKit

struct IntroVideoView: View {
    @Binding var isFinished: Bool
    @State private var player: AVPlayer?
    @State private var opacity: Double = 1.0
    @State private var observer: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayerLayer(player: player)
                    .ignoresSafeArea()
            }

            VStack {
                Spacer()
                Button {
                    dismissIntro()
                } label: {
                    Text("Skip")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.bottom, 60)
            }
        }
        .opacity(opacity)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            player?.pause()
            player = nil
        }
    }

    private func setupPlayer() {
        let localURL = Self.cachedVideoURL
        let bundleURL = Bundle.main.url(forResource: "intro_video", withExtension: "mp4")

        let videoURL: URL?
        if FileManager.default.fileExists(atPath: localURL.path()) {
            videoURL = localURL
        } else {
            videoURL = bundleURL
        }

        guard let url = videoURL else {
            dismissIntro()
            return
        }
        let avPlayer = AVPlayer(url: url)
        avPlayer.isMuted = false
        player = avPlayer

        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            dismissIntro()
        }

        avPlayer.play()
    }

    private static var cachedVideoURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("intro_video.mp4")
    }

    private func dismissIntro() {
        withAnimation(.easeOut(duration: 0.5)) {
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isFinished = true
        }
    }
}

struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = PlayerUIView(player: player)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

class PlayerUIView: UIView {
    private var playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override func layoutSubviews() {
        MainActor.assumeIsolated {
            super.layoutSubviews()
            playerLayer.frame = bounds
        }
    }
}
