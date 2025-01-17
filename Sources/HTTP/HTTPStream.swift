import AVFoundation

open class HTTPStream: NetStream {
    private(set) var name: String?
    public var tsWriter: TSWriter { return _tsWriter }
    private lazy var _tsWriter = TSFileWriter()

    open func publish(_ name: String?) {
        lockQueue.async {
            if name == nil {
                self.name = name
                #if os(iOS)
                self.mixer.videoIO.screen?.stopRunning()
                #endif
                self.mixer.stopEncoding()
                self._tsWriter.stopRunning()
                return
            }
            self.name = name
            #if os(iOS)
            self.mixer.videoIO.screen?.startRunning()
            #endif
            self.mixer.startEncoding(delegate: self._tsWriter)
            self.mixer.startRunning()
            self._tsWriter.startRunning()
        }
    }

    #if os(iOS) || os(macOS)
    override open func attachCamera(_ camera: AVCaptureDevice?, onError: ((NSError) -> Void)? = nil) {
        if camera == nil {
            _tsWriter.expectedMedias.remove(.video)
        } else {
            _tsWriter.expectedMedias.insert(.video)
        }
        super.attachCamera(camera, onError: onError)
    }

    override open func attachAudio(_ audio: AVCaptureDevice?, automaticallyConfiguresApplicationAudioSession: Bool = true, onError: ((NSError) -> Void)? = nil) {
        if audio == nil {
            _tsWriter.expectedMedias.remove(.audio)
        } else {
            _tsWriter.expectedMedias.insert(.audio)
        }
        super.attachAudio(audio, automaticallyConfiguresApplicationAudioSession: automaticallyConfiguresApplicationAudioSession, onError: onError)
    }
    #endif

    func getResource(_ resourceName: String) -> (MIME, String)? {
        let url = URL(fileURLWithPath: resourceName)
        guard let name: String = name, 2 <= url.pathComponents.count && url.pathComponents[1] == name else {
            return nil
        }
        let fileName: String = url.pathComponents.last!
        switch true {
        case fileName == "playlist.m3u8":
            return (.applicationXMpegURL, _tsWriter.playlist)
        case fileName.contains(".ts"):
            if let mediaFile: String = _tsWriter.getFilePath(fileName) {
                return (.videoMP2T, mediaFile)
            }
            return nil
        default:
            return nil
        }
    }
}
