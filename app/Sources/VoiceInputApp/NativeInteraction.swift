import AppKit
import ApplicationServices

@MainActor
final class NativeHotkeys {
    var action: ((String) -> Void)?
    var isRecording: (() -> Bool)?
    var doubleControl = true
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = ControlGesture()
    private var heldControl = Set<Int64>()
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let drop: Bool = MainActor.assumeIsolated {
                let owner = Unmanaged<NativeHotkeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return false
                }
                return owner.handle(type, event)
            }
            return drop ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                         callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil; heldControl.removeAll()
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, key == 59 || key == 62 {
            let time = ProcessInfo.processInfo.systemUptime
            if !heldControl.contains(key), event.flags.contains(.maskControl) {
                heldControl.insert(key)
                _ = gesture.down(at: time)
                if !event.flags.intersection([.maskShift, .maskCommand, .maskAlternate]).isEmpty { gesture.otherKey() }
            } else {
                heldControl.remove(key)
                if doubleControl, let a = gesture.up(at: time, recording: isRecording?() ?? false) {
                    action?(a == .start ? "start" : "stop")
                }
            }
        } else if type == .flagsChanged {
            gesture.otherKey()
        } else if type == .keyDown {
            gesture.otherKey()
            if key == 53, isRecording?() == true { action?("cancel"); return true }
            if key == 9, event.flags.contains([.maskControl, .maskAlternate]),
               !event.flags.contains(.maskCommand), event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                action?("toggle"); return true
            }
            if key == 35, event.flags.contains([.maskControl, .maskAlternate]) { action?("panel"); return true }
        }
        return false
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
    static func paste(_ text: String, to target: Target) -> Bool {
        guard sameFocus(target, requireSelection: true) else { return false }
        let board = NSPasteboard.general
        let old = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        board.clearContents(); board.setString(text, forType: .string)
        let count = board.changeCount
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        let stillFocused = sameFocus(target, requireSelection: true)
        if stillFocused { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if board.changeCount == count { board.clearContents(); if !old.isEmpty { board.writeObjects(old) } }
        }
        return stillFocused
    }
}
