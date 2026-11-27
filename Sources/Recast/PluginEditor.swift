import AVFoundation
import AppKit
import CoreAudioKit
import RecastCore
import SwiftUI

/// The windows that show plugins' own controls. Each holds a live copy of the plugin; its settings go back into
/// the app's settings when the window closes, and before converting or saving a preset.
@MainActor
final class PluginEditors: NSObject, NSWindowDelegate {
    static let shared = PluginEditors()

    private struct Editor {
        let window: NSWindow
        let unit: AUAudioUnit
    }

    private var editors: [UUID: Editor] = [:]
    private var loading: Set<UUID> = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PluginEditors.shared.saveAll() }
        }
    }

    func edit(_ effect: PluginEffect) {
        if let editor = editors[effect.id] {
            editor.window.makeKeyAndOrderFront(nil)
            return
        }
        guard !loading.contains(effect.id) else { return }
        loading.insert(effect.id)
        let id = effect.id
        AUAudioUnit.instantiate(with: effect.componentDescription, options: .loadOutOfProcess) { unit, error in
            // Hand the plugin to the main actor; it isn't used on this thread again.
            nonisolated(unsafe) let unit = unit
            let message = error?.localizedDescription
            Task { @MainActor in
                PluginEditors.shared.loading.remove(id)
                guard let unit else {
                    PluginEditors.shared.fail(effect, message ?? "It didn't load.")
                    return
                }
                PluginEditors.shared.open(effect, unit)
            }
        }
    }

    private func open(_ effect: PluginEffect, _ unit: AUAudioUnit) {
        if let data = effect.state, let state = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            unit.fullStateForDocument = state
        }
        nonisolated(unsafe) let unit = unit
        unit.requestViewController { controller in

            Task { @MainActor in
                PluginEditors.shared.show(effect, unit, controller ?? NSHostingController(rootView: GenericPluginView(unit: unit)))
            }
        }
    }

    private func show(_ effect: PluginEffect, _ unit: AUAudioUnit, _ controller: NSViewController) {
        var size = controller.preferredContentSize
        if size.width < 50 || size.height < 50 { size = controller.view.frame.size }
        if size.width < 50 || size.height < 50 { size = controller.view.fittingSize }
        if size.width < 50 || size.height < 50 { size = NSSize(width: 420, height: 320) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
        window.title = effect.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(effect.id.uuidString)
        window.center()
        window.makeKeyAndOrderFront(nil)
        editors[effect.id] = Editor(window: window, unit: unit)
    }

    private func fail(_ effect: PluginEffect, _ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open “\(effect.name)”"
        alert.informativeText = message
        alert.runModal()
    }

    /// The open window for a plugin, if any (snapshot mode captures it).
    func window(for id: UUID) -> NSWindow? { editors[id]?.window }

    /// Copies every open plugin's settings into the app's settings.
    func saveAll() {
        for id in editors.keys { save(id) }
    }

    private func save(_ id: UUID) {
        guard let editor = editors[id], let state = PluginHost.state(of: editor.unit) else { return }
        let model = AppModel.shared
        guard let index = model.settings.plugins.firstIndex(where: { $0.id == id }), model.settings.plugins[index].state != state else { return }
        model.settings.plugins[index].state = state
    }

    func close(_ id: UUID) {
        guard let editor = editors.removeValue(forKey: id) else { return }
        editor.window.delegate = nil
        editor.window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let name = window.identifier?.rawValue, let id = UUID(uuidString: name) else { return }
        save(id)
        editors.removeValue(forKey: id)
    }
}

/// Controls built from a plugin's parameters, for plugins without a window of their own.
struct GenericPluginView: View {
    let unit: AUAudioUnit

    var body: some View {
        let parameters = (unit.parameterTree?.allParameters ?? []).filter { $0.flags.contains(.flag_IsWritable) }
        Form {
            if parameters.isEmpty {
                Text("This plugin has no settings to show.")
                    .foregroundStyle(.secondary)
            }
            ForEach(parameters, id: \.address) { ParameterRow(parameter: $0) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 200)
    }
}

private struct ParameterRow: View {
    let parameter: AUParameter
    @State private var value: AUValue = 0

    var body: some View {
        Group {
            if let names = parameter.valueStrings, !names.isEmpty {
                Picker(parameter.displayName, selection: $value) {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(parameter.minValue + AUValue(index))
                    }
                }
            } else if parameter.unit == .boolean {
                Toggle(parameter.displayName, isOn: Binding(get: { value >= 0.5 }, set: { value = $0 ? 1 : 0 }))
            } else {
                LabeledContent(parameter.displayName) {
                    HStack {
                        Slider(value: $value, in: parameter.minValue...max(parameter.maxValue, parameter.minValue + 0.0001))
                        Text(text)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .trailing)
                    }
                }
            }
        }
        .onAppear { value = parameter.value }
        .onChange(of: value) { _, newValue in
            if parameter.value != newValue { parameter.value = newValue }
        }
    }

    private var text: String {
        var current = value
        let shown = parameter.string(fromValue: &current)
        let unit = parameter.unitName ?? ""
        return unit.isEmpty || shown.hasSuffix(unit) ? shown : "\(shown) \(unit)"
    }
}
