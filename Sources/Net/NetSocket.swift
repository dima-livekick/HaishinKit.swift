import Foundation

open class NetSocket: NSObject {
    public static let defaultTimeout: Int = 15 // sec
    public static let defaultWindowSizeC = Int(UInt16.max)

    open var inputBuffer = Data()
    /// The time to wait for TCP/IP Handshake done.
    open var timeout: Int = NetSocket.defaultTimeout
    /// This instance connected to server(true) or not(false).
    open var connected: Bool = false
    public var windowSizeC: Int = NetSocket.defaultWindowSizeC
    /// The statistics of total incoming bytes.
    open var totalBytesIn: Int64 = 0
    open var qualityOfService: DispatchQoS = .default
    open var securityLevel: StreamSocketSecurityLevel = .none
    /// The statistics of total outgoing bytes.
    open private(set) var totalBytesOut: Int64 = 0
    open private(set) var queueBytesOut: Int64 = 0

    var inputStream: InputStream?
    var outputStream: OutputStream?
    lazy var inputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.NetSocket.input", qos: qualityOfService)

    private var runloop: RunLoop?
    private lazy var timeoutHandler = DispatchWorkItem { [weak self] in
        self?.didTimeout()
    }
    private lazy var buffer = [UInt8](repeating: 0, count: windowSizeC)
    private lazy var outputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.NetSocket.output", qos: qualityOfService)

    public func connect(withName: String, port: Int) {
        inputQueue.async {
            Stream.getStreamsToHost(
                withName: withName,
                port: port,
                inputStream: &self.inputStream,
                outputStream: &self.outputStream
            )
            self.initConnection()
        }
    }

    @discardableResult
    public func doOutput(data: Data, locked: UnsafeMutablePointer<UInt32>? = nil) -> Int {
        OSAtomicAdd64(Int64(data.count), &queueBytesOut)
        outputQueue.async {
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Void in
                self.doOutputProcess(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), maxLength: data.count)
            }
            if locked != nil {
                OSAtomicAnd32Barrier(0, locked!)
            }
        }
        return data.count
    }

    open func close() {
        close(isDisconnected: false)
    }

    open func listen() {
    }

    final func doOutputFromURL(_ url: URL, length: Int) {
        outputQueue.async {
            do {
                let fileHandle: FileHandle = try FileHandle(forReadingFrom: url)
                defer {
                    fileHandle.closeFile()
                }
                let endOfFile = Int(fileHandle.seekToEndOfFile())
                for i in 0..<Int(endOfFile / length) {
                    fileHandle.seek(toFileOffset: UInt64(i * length))
                    self.doOutputProcess(fileHandle.readData(ofLength: length))
                }
                let remain: Int = endOfFile % length
                if 0 < remain {
                    self.doOutputProcess(fileHandle.readData(ofLength: remain))
                }
            } catch let error as NSError {
                logger.error("\(error)")
            }
        }
    }

    final func doOutputProcess(_ data: Data) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Void in
            doOutputProcess(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), maxLength: data.count)
        }
    }

    final func doOutputProcess(_ buffer: UnsafePointer<UInt8>?, maxLength: Int) {
        guard let buffer = buffer else {
            return
        }
        var total: Int = 0
        while total < maxLength {
            guard let outputStream = outputStream, outputStream.streamStatus == .open else {
                return
            }
            if outputStream.hasSpaceAvailable {
                let length: Int = outputStream.write(buffer.advanced(by: total), maxLength: maxLength - total)
                if length <= 0 {
                    break
                }
                total += length
                totalBytesOut += Int64(length)
                OSAtomicAdd64(-Int64(length), &queueBytesOut)
            } else {
                sleep(1)
                continue
            }
        }
    }

    func close(isDisconnected: Bool) {
        outputQueue.async {
            guard let runloop: RunLoop = self.runloop else {
                return
            }
            self.deinitConnection(isDisconnected: isDisconnected)
            self.runloop = nil
            CFRunLoopStop(runloop.getCFRunLoop())
            logger.trace("isDisconnected: \(isDisconnected)")
        }
    }

    func initConnection() {
        totalBytesIn = 0
        totalBytesOut = 0
        queueBytesOut = 0
        inputBuffer.removeAll(keepingCapacity: false)

        guard let inputStream: InputStream = inputStream, let outputStream: OutputStream = outputStream else {
            return
        }

        runloop = .current

        inputStream.delegate = self
        inputStream.schedule(in: runloop!, forMode: .default)
        inputStream.setProperty(securityLevel.rawValue, forKey: .socketSecurityLevelKey)

        outputStream.delegate = self
        outputStream.schedule(in: runloop!, forMode: .default)
        outputStream.setProperty(securityLevel.rawValue, forKey: .socketSecurityLevelKey)

        inputStream.open()
        outputStream.open()

        if 0 < timeout {
            outputQueue.asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutHandler)
        }

        runloop?.run()
        connected = false
    }

    func deinitConnection(isDisconnected: Bool) {
        timeoutHandler.cancel()
        outputQueue = .init(label: "com.haishinkit.HaishinKit.NetSocket.output", qos: qualityOfService)
        inputStream?.close()
        inputStream?.remove(from: runloop!, forMode: .default)
        inputStream?.delegate = nil
        inputStream = nil
        outputStream?.close()
        outputStream?.remove(from: runloop!, forMode: .default)
        outputStream?.delegate = nil
        outputStream = nil
    }

    func didTimeout() {
    }

    private func doInput() {
        guard let inputStream: InputStream = inputStream else {
            return
        }
        let length: Int = inputStream.read(&buffer, maxLength: windowSizeC)
        if 0 < length {
            totalBytesIn += Int64(length)
            inputBuffer.append(buffer, count: length)
            listen()
        }
    }
}

extension NetSocket: StreamDelegate {
    // MARK: StreamDelegate
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        //  1 = 1 << 0
        case .openCompleted:
            guard let inputStream = inputStream, let outputStream = outputStream,
                inputStream.streamStatus == .open && outputStream.streamStatus == .open else {
                    break
            }
            if aStream == inputStream {
                timeoutHandler.cancel()
                connected = true
            }
        //  2 = 1 << 1
        case .hasBytesAvailable:
            if aStream == inputStream {
                doInput()
            }
        //  4 = 1 << 2
        case .hasSpaceAvailable:
            break
        //  8 = 1 << 3
        case .errorOccurred:
            guard aStream == inputStream else {
                return
            }
            close(isDisconnected: true)
        // 16 = 1 << 4
        case .endEncountered:
            guard aStream == inputStream else {
                return
            }
            close(isDisconnected: true)
        default:
            break
        }
    }
}
