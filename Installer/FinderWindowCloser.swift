import AppKit

// Explicit process targets avoid Apple Events being routed to a second Finder instance.
enum FinderWindowCloser {
    static func object(
        _ want: UInt32, _ form: UInt32, _ selector: NSAppleEventDescriptor,
        _ container: NSAppleEventDescriptor = .null()
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: 0x7761_6e74)
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: 0x666f_726d)
        record.setDescriptor(selector, forKeyword: 0x7365_6c64)
        record.setDescriptor(container, forKeyword: 0x6672_6f6d)
        return record.coerce(toDescriptorType: 0x6f62_6a20)!
    }
    static func send(_ id: UInt32, _ object: NSAppleEventDescriptor, _ pid: pid_t)
        -> NSAppleEventDescriptor?
    {
        let event = NSAppleEventDescriptor(
            eventClass: 0x636f_7265, eventID: id,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid), returnID: -1,
            transactionID: 0)
        event.setParam(object, forKeyword: 0x2d2d_2d2d)
        return try? event.sendEvent(options: .waitForReply, timeout: 5)
    }
    static func close(container: URL, pids: [pid_t]) {
        let expected = container.resolvingSymlinksInPath().standardizedFileURL.path
        for pid in pids {
            var matches: [NSAppleEventDescriptor] = []
            for index in 1...100 {
                let window = object(
                    0x6377_696e, 0x696e_6478, NSAppleEventDescriptor(int32: Int32(index)))
                let target = object(
                    0x7072_6f70, 0x7072_6f70, NSAppleEventDescriptor(typeCode: 0x6676_7467), window)
                let urlProperty = object(
                    0x7072_6f70, 0x7072_6f70, NSAppleEventDescriptor(typeCode: 0x7055_524c), target)
                guard let reply = send(0x6765_7464, urlProperty, pid),
                    reply.paramDescriptor(forKeyword: 0x6572_726e)?.int32Value ?? 0 == 0,
                    let text = reply.paramDescriptor(forKeyword: 0x2d2d_2d2d)?.stringValue
                else { break }
                guard let url = URL(string: text), url.isFileURL else { continue }
                if url.resolvingSymlinksInPath().standardizedFileURL.path == expected {
                    matches.append(window)
                }
            }
            // Reverse order keeps remaining window indexes stable as matching windows close.
            for window in matches.reversed() { _ = send(0x636c_6f73, window, pid) }
        }
    }
}
