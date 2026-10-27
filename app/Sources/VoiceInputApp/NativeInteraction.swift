import AppKit
import ApplicationServices

@MainActor
final class NativeHotkeys {
    var action: ((String) -> Void)?
    var isRecording: (() -> Bool)?
    var doubleControl = true
    var shortcut: RecordingShortcut = .controlOptionV
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var gesture = ControlGesture()
    private var heldControl = Set<Int64>()
    func start() -> Bool {
        if globalMonitor != nil && localMonitor != nil { return true }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        // AppKit delivers copies asynchronously. A busy App cannot hold up typing
        // in another application, and these callbacks cannot consume its events.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.observeLocal(event) }
            return event
        }
        guard globalMonitor != nil && localMonitor != nil else { stop(); return false }
        return true
    }
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        gesture = ControlGesture(); heldControl.removeAll()
    }
    func observeLocal(_ event: NSEvent) -> NSEvent {
        observe(event)
        return event
    }
    private func observe(_ event: NSEvent) {
        // Discard queued gestures after a stall instead of starting a late recording.
        guard ProcessInfo.processInfo.systemUptime - event.timestamp < 1.5 else {
            gesture = ControlGesture(); heldControl.removeAll(); return
        }
        let key = Int64(event.keyCode)
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        if event.type == .flagsChanged, key == 59 || key == 62 {
            let time = event.timestamp
            if !heldControl.contains(key), flags.contains(.maskControl) {
                heldControl.insert(key)
                _ = gesture.down(at: time)
                if !flags.intersection([.maskShift, .maskCommand, .maskAlternate]).isEmpty { gesture.otherKey() }
            } else {
                heldControl.remove(key)
                if doubleControl, let a = gesture.up(at: time, recording: isRecording?() ?? false) {
                    action?(a == .start ? "start" : "stop")
                }
            }
        } else if event.type == .flagsChanged {
            gesture.otherKey()
        } else if event.type == .keyDown {
            gesture.otherKey()
            if key == 53, isRecording?() == true { action?("cancel"); return }
            if shortcut.matches(key: key, modifiers: flags), !event.isARepeat {
                action?("toggle"); return
            }
            if key == 35, flags.contains([.maskControl, .maskAlternate]) { action?("panel") }
        }
    }
}

@MainActor
enum NativePaste {
    struct Target {
        let pid: pid_t
        let window: AXUIElement?
        let field: AXUIElement?
        let selection: CFRange?
    }
    static func element(_ owner: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, attr, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func capture() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let field = element(ax, kAXFocusedUIElementAttribute as CFString)
        return Target(pid: app.processIdentifier, window: element(ax, kAXFocusedWindowAttribute as CFString),
                      field: field, selection: field.flatMap(selectedRange))
    }
    static func selectedRange(_ field: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
    static func sameFocus(_ target: Target, requireSelection: Bool = false) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let captured = target.window,
              let current = capture(), let currentWindow = current.window,
              CFEqual(captured, currentWindow) else { return false }
        if let field = target.field { guard let currentField = current.field, CFEqual(field, currentField) else { return false } }
        if requireSelection, let original = target.selection {
            guard let currentRange = current.selection, original.location == currentRange.location,
                  original.length == currentRange.length else { return false }
        }
        return true
    }
    static func value(_ field: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, text.count < 20_000 else { return nil }
        return text
    }
    // 下面三個數字都是舊版（bin/voice-input-mac.sh 的 emit／send_cmd_v）踩過才定下來的，
    // 原生 App 改寫時漏掉了，症狀是「辨識好了、文字也在剪貼簿，但輸入框沒東西」。
    /// 送 Cmd+V 前最多等使用者放開修飾鍵多久。停止錄音是按 Ctrl，還沒放開就送出去會變成 Ctrl+Cmd+V。
    static let modifierWait: Duration = .milliseconds(1500)
    /// 按下和放開之間的間隔。完全沒間隔的話，部分 App 會把這組事件當雜訊丟掉。
    static let keyGap: Duration = .milliseconds(10)
    /// 輸入框一直沒來讀剪貼簿時，最晚多久還原（正常情況讀走就還，見 NativeInsert.swift）。
    static let restoreDelay: Duration = .seconds(5)

    static func modifiersHeld() -> Bool {
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        return !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty
    }

}
