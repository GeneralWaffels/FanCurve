import AppKit
import SwiftUI
import SMCKit

/// Profile picker used in the Fans tab and the menu bar. Saving and deleting live on the Fans page.
struct ProfileMenu: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Menu(model.activeProfile ?? "Custom (unsaved)") {
            Section("Noctua") {
                ForEach(FanConfig.presetOrder, id: \.self) { name in item(name) }
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

/// Save / Delete buttons for the Fans page. Delete removes the selected saved profile; built-in
/// Noctua presets can't be deleted, so the button is disabled for them.
struct ProfileButtons: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let active = model.activeProfile
        let deletable = active.map { !model.isBuiltIn($0) } ?? false
        HStack(spacing: 8) {
            Button { ProfileDialogs.save(model) } label: { Label("Save as Profile…", systemImage: "square.and.arrow.down") }
                .help("Save the current curve as a named profile")
            Button(role: .destructive) { if let a = active { ProfileDialogs.delete(a, model) } } label: {
                Label("Delete Profile", systemImage: "trash")
            }
            .disabled(!deletable)
            .help(deletable ? "Delete \u{201C}\(active!)\u{201D}" : active == nil ? "Select a saved profile to delete it" : "Built-in profiles can't be deleted")
        }
        .labelStyle(.titleAndIcon)
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
