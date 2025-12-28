import SwiftUI
import AVFoundation
import CoreMotion

struct ContentView: View {
    private let motionManager = CMMotionManager()
    @State private var playerReference: AVPlayer?
    @Environment(\.scenePhase) private var scenePhase
    @State private var canExit = false
    private var isDetectionEnabled: Bool {
        // 設定がない場合はデフォルトを true にする
        UserDefaults.standard.object(forKey: "enable_sensor") == nil ? true : UserDefaults.standard.bool(forKey: "enable_sensor")
    }
    private var rotationThreshold: Double {
        let val = UserDefaults.standard.double(forKey: "rotation_threshold")
        return val == 0 ? 2.5 : val
    }
    private var exitDelay: Double {
        UserDefaults.standard.double(forKey: "exit_delay") == 0 ? 1.0 : UserDefaults.standard.double(forKey: "exit_delay")
    }
    
    var body: some View {
        CustomVideoPlayerView(videoName: "demo_video", playerBinding: $playerReference) {
            handleExit()
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .onAppear {
            setupAudioSession()
            startMotionDetection() // 初回起動時
            enableDetectionWithDelay()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                // 1. 動画を再セットして再生
                rebindVideo()
                
                // 2. センサーを一度止めてから再開始（これが重要）
                motionManager.stopDeviceMotionUpdates()
                startMotionDetection()
                
                // 3. 復帰後1秒間は誤作動防止で判定しない
                enableDetectionWithDelay()
                
                print("✅ アプリ復帰：動画とセンサーを再起動しました")
            }
        }
    }
    
    // 終了処理を共通化
    // MARK: - 終了処理（MainActorで実行を保証）
    @MainActor
    func handleExit() {
        guard canExit else { return }
        canExit = false
        
        // 1. センサーを即座に停止（新たなデータ流入を遮断）
        motionManager.stopDeviceMotionUpdates()
        
        // 2. ビデオの描画と音を停止（リソースの完全解放は後回し）
        playerReference?.pause()
        playerReference?.isMuted = true
        
        // 3. オーディオセッションの非アクティブ化
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        // 4. 非同期で実行ループを回し、サスペンドを実行
        // これにより、ビデオ停止処理が完了する時間を稼ぎ、XPCエラーを減らします
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let selector = NSSelectorFromString("suspend")
            if UIApplication.shared.responds(to: selector) {
                UIApplication.shared.perform(selector)
            }
            
            // 5. 完全にバックグラウンドへ回ったタイミングで重いリソースを解放
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.scenePhase == .background {
                    self.playerReference?.replaceCurrentItem(with: nil)
                }
            }
        }
    }
    
    // MARK: - センサー監視
    func startMotionDetection() {
        guard isDetectionEnabled && motionManager.isDeviceMotionAvailable else { return }
        
        // 念のため一旦停止してから開始
        motionManager.stopDeviceMotionUpdates()
        
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(to: .main) { data, error in
            guard let data = data, self.canExit else { return }
            
            let rotation = data.rotationRate
            let rotationIntensity = sqrt(pow(rotation.x, 2) + pow(rotation.y, 2) + pow(rotation.z, 2))
            
            if rotationIntensity > rotationThreshold {
                Task { @MainActor in
                    self.handleExit()
                }
            }
        }
    }
    
    func enableDetectionWithDelay() {
        canExit = false
        DispatchQueue.main.asyncAfter(deadline: .now() + exitDelay) {
            self.canExit = true
        }
    }
    
    func rebindVideo() {
        guard let url = Bundle.main.url(forResource: "demo_video", withExtension: "mov") else { return }
        let newItem = AVPlayerItem(url: url)
        playerReference?.replaceCurrentItem(with: newItem)
        playerReference?.seek(to: .zero)
        playerReference?.play()
    }
    
    func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
}

// MARK: - Video Player Component
struct CustomVideoPlayerView: UIViewRepresentable {
    let videoName: String
    @Binding var playerBinding: AVPlayer?
    var onTap: () -> Void // 【追加】タップ時のコールバック
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        
        // 【追加】タップジェスチャーの設定
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        view.addGestureRecognizer(tapGesture)
        
        guard let url = Bundle.main.url(forResource: videoName, withExtension: "mov") else { return view }
        
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none
        
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = UIScreen.main.bounds
        playerLayer.opacity = 0
        view.layer.addSublayer(playerLayer)
        
        context.coordinator.playerLayer = playerLayer
        context.coordinator.onTap = onTap // コールバックを保持
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = view.bounds
            playerLayer.opacity = 1
            CATransaction.commit()
            player.play()
            self.playerBinding = player
        }
        
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
            player.seek(to: .zero)
            player.play()
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    class Coordinator: NSObject {
        var playerLayer: AVPlayerLayer?
        var onTap: (() -> Void)?
        
        @objc func handleTap() {
            onTap?()
        }
    }
}
