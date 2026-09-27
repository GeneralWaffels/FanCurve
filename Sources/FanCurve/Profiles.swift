import AppKit
import SwiftUI
import SMCKit

/// Profile picker used in the Fans tab and the menu bar. Saving and deleting live on the Fans page.
struct ProfileMenu: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Menu(model.activeProfile ?? "Custom (unsaved)") {
            Section("Noctua") {
                ForEach(FanConfig.presetOrder.filter { $0.hasPrefix("Noctua") }, id: \.self) { name in item(name) }
            }
            Section("Puget Systems") {
                ForEach(FanConfig.presetOrder.filter { !$0.hasPrefix("Noctua") }, id: \.self) { name in item(name) }
            }
            if !model.customProfileNames.isEmpty {
                Section("Your profiles") {
                    ForEach(model.customProfileNames, id: \.self) { name in item(name) }
                }
            }
        }
    }

    private func item(_ name: String) -> some View {
        Button { model.applyPreset(name) } label: {
            if model.activeProfile == name { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }
}

/// Save / Rename / Delete buttons shown above the fan curve. Rename and Delete act on the
/// selected saved profile; built-in Noctua presets and unsaved curves can't be renamed or deleted.
struct ProfileButtons: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let active = model.activeProfile
        let editable = active.map { !model.isBuiltIn($0) } ?? false
        let why = active == nil ? "Save this curve as a profile first" : "Built-in profiles can't be changed"
        HStack(spacing: 8) {
            Button { ProfileDialogs.save(model) } label: { Label("Save as…", systemImage: "square.and.arrow.down") }
                .help("Save the current curve as a named profile")
            Button { if let a = active { ProfileDialogs.rename(a, model) } } label: { Label("Rename…", systemImage: "pencil") }
                .disabled(!editable)
                .help(editable ? "Rename \u{201C}\(active!)\u{201D}" : why)
            Button(role: .destructive) { if let a = active { ProfileDialogs.delete(a, model) } } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!editable)
            .help(editable ? "Delete \u{201C}\(active!)\u{201D}" : why)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
    }
}

/// Native dialogs (NSAlert) for naming and confirming — they work from the menu bar menu too,
/// where SwiftUI sheets have no window to attach to.
@MainActor
enum ProfileDialogs {
    static func save(_ model: Model) {
        NSApp.activate(ignoringOtherApps: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Profile name"
        field.stringValue = model.activeProfile.flatMap { model.isBuiltIn($0) ? nil : $0 } ?? ""

        let alert = NSAlert()
        alert.messageText = "Save fan profile"
        alert.informativeText = "Saves the current curve so you can switch back to it later."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if model.isBuiltIn(name) {
            info("“\(name)” is a built-in profile", "Pick a different name.")
            return
        }
        if model.customProfiles[name] != nil,
           !confirm("Replace “\(name)”?", "A profile with this name already exists.", button: "Replace") { return }
        model.saveProfile(named: name)
    }

    static func rename(_ name: String, _ model: Model) {
        NSApp.activate(ignoringOtherApps: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = name
        let alert = NSAlert()
        alert.messageText = "Rename \u{201C}\(name)\u{201D}"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != name else { return }
        if model.isBuiltIn(new) { info("\u{201C}\(new)\u{201D} is a built-in profile", "Pick a different name."); return }
        if model.customProfiles[new] != nil,
           !confirm("Replace \u{201C}\(new)\u{201D}?", "A profile with this name already exists.", button: "Replace") { return }
        model.renameProfile(name, to: new)
    }

    static func delete(_ name: String, _ model: Model) {
        NSApp.activate(ignoringOtherApps: true)
        guard confirm("Delete “\(name)”?", "This can't be undone. Your current fan curve stays as it is.", button: "Delete") else { return }
        model.deleteProfile(named: name)
    }

    private static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if button == "Delete" { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
