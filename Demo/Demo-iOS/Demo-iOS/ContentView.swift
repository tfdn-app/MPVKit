// arnage #476 — throwaway spike harness (replaces the stock MPVKit demo view).
// Drives libmpv with the clean-room vo=avfoundation output onto an
// AVSampleBufferDisplayLayer (passed via --wid) and logs the EDR signals that
// are the spike's verdict. Grep the device log for "AVFSPIKE".
import AVFoundation
import Foundation
import Libmpv
import SwiftUI
import UIKit

// Public HDR test clips (no Jellyfin needed for the core EDR validation).
private enum SpikeClip: String, CaseIterable, Identifiable {
    case hdr10 = "HDR10"
    case dvP8 = "DV P8.1"
    case dvP5 = "DV P5"
    case h265 = "h265 SDR"
    var id: String { rawValue }
    var url: URL {
        switch self {
        case .hdr10: return URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/HDR10_ToneMapping_Test_240_1000_nits.mp4")!
        case .dvP8:  return URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/DolbyVision_P8.mp4")!
        case .dvP5:  return URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/DolbyVision_P5.mp4")!
        case .h265:  return URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/h265.mp4")!
        }
    }
}

struct ContentView: View {
    @State private var clip: SpikeClip = .hdr10
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AvfSpikePlayer(url: clip.url).ignoresSafeArea()
            VStack {
                Spacer()
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(SpikeClip.allCases) { c in
                            Button { clip = c } label: {
                                Text(c.rawValue)
                                    .frame(width: 110, height: 64)
                                    .background(c == clip ? Color.blue : Color.gray.opacity(0.4))
                                    .foregroundColor(.white).cornerRadius(8)
                            }
                        }
                    }.padding()
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct AvfSpikePlayer: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> AvfSpikeViewController {
        let vc = AvfSpikeViewController()
        vc.playUrl = url
        return vc
    }
    func updateUIViewController(_ vc: AvfSpikeViewController, context: Context) {
        if vc.currentUrl != url { vc.loadFile(url) }
    }
}

final class AvfSpikeViewController: UIViewController {
    var displayLayer = AVSampleBufferDisplayLayer()
    var mpv: OpaquePointer!
    lazy var queue = DispatchQueue(label: "avfspike.mpv", qos: .userInitiated)
    var playUrl: URL?
    private(set) var currentUrl: URL?
    private var edrTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(displayLayer)

        setupMpv()
        if let url = playUrl { loadFile(url) }

        edrTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.logEDR(tag: "tick")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        displayLayer.frame = view.bounds
    }

    func setupMpv() {
        mpv = mpv_create()
        if mpv == nil { fatalError("AVFSPIKE: mpv_create failed") }
        checkError(mpv_request_log_messages(mpv, "v"))
        // Hand the AVSampleBufferDisplayLayer to the VO via --wid (int64 of the
        // layer pointer) — same mechanism the Metal demo uses for its layer.
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &displayLayer))
        checkError(mpv_set_option_string(mpv, "vo", "avfoundation"))
        checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))
        checkError(mpv_set_option_string(mpv, "video-rotate", "no"))
        checkError(mpv_initialize(mpv))
        mpv_set_wakeup_callback(mpv, { ctx in
            let me = unsafeBitCast(ctx, to: AvfSpikeViewController.self)
            me.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    func loadFile(_ url: URL) {
        currentUrl = url
        command("loadfile", args: [url.absoluteString, "replace"])
    }

    // MARK: - EDR instrumentation (the verdict)
    private func logEDR(tag: String) {
        let primaries = getString("video-params/primaries") ?? "?"
        let gamma = getString("video-params/gamma") ?? "?"
        let sigPeak = getString("video-params/sig-peak") ?? "?"
        let w = getString("width") ?? "?"
        let h = getString("height") ?? "?"
        let wantsEDR: Bool = {
            if #available(iOS 17.0, *) { return displayLayer.wantsExtendedDynamicRangeContent }
            return false
        }()
        let screen = view.window?.screen ?? UIScreen.main
        NSLog("AVFSPIKE-EDR[\(tag)] \(w)x\(h) gamma=\(gamma) primaries=\(primaries) sig-peak=\(sigPeak) | wantsEDR=\(wantsEDR) currentEDRHeadroom=\(screen.currentEDRHeadroom) potentialEDRHeadroom=\(screen.potentialEDRHeadroom) layerStatus=\(displayLayer.status.rawValue)")
    }

    // MARK: - mpv plumbing (mirrors the MPVKit demo)
    private func getString(_ name: String) -> String? {
        guard mpv != nil, let cstr = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    func command(_ command: String, args: [String?] = []) {
        guard mpv != nil else { return }
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p!)) } }
        checkError(mpv_command(mpv, &cargs))
    }

    func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while self.mpv != nil {
                let event = mpv_wait_event(self.mpv, 0)
                guard let event, event.pointee.event_id != MPV_EVENT_NONE else { break }
                switch event.pointee.event_id {
                case MPV_EVENT_FILE_LOADED:
                    DispatchQueue.main.async { self.logEDR(tag: "file-loaded") }
                case MPV_EVENT_LOG_MESSAGE:
                    let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data))!
                    NSLog("AVFSPIKE-MPV[\(String(cString: msg.pointee.prefix))] \(String(cString: msg.pointee.level)): \(String(cString: msg.pointee.text))")
                case MPV_EVENT_SHUTDOWN:
                    mpv_terminate_destroy(self.mpv); self.mpv = nil
                default:
                    break
                }
            }
        }
    }

    private func checkError(_ status: CInt) {
        if status < 0 { NSLog("AVFSPIKE: mpv API error: \(String(cString: mpv_error_string(status)))") }
    }
}
