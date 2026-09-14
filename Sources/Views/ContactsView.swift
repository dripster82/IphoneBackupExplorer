import SwiftUI

struct ContactsListView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if model.isLoadingData && model.contacts.isEmpty {
                ProgressView("Reading Address Book…")
            } else if let err = model.dataError {
                ContentUnavailableView("Can't Read Contacts", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(err))
            } else if model.contacts.isEmpty {
                ContentUnavailableView("No Contacts", systemImage: "person.crop.circle", description: Text("This backup has no Address Book entries."))
            } else {
                List(selection: $model.selectedContactID) {
                    ForEach(model.filteredContacts) { contact in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(Color.accentColor.opacity(0.2)).frame(width: 34, height: 34)
                                Text(contact.initials).font(.caption).fontWeight(.semibold).foregroundStyle(.tint)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(contact.fullName).lineLimit(1)
                                let sub = contact.phones.first ?? contact.emails.first ?? contact.organization
                                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                        .tag(contact.id)
                    }
                }
            }
        }
        .navigationTitle("Contacts")
        .navigationSubtitle(model.contacts.isEmpty ? "" : "\(model.contacts.count) contacts")
        .searchable(text: $model.contactSearch, placement: .toolbar, prompt: "Search contacts")
        .toolbar {
            ToolbarItem {
                Button { model.exportContacts() } label: { Label("Export vCard", systemImage: "square.and.arrow.up") }
                    .disabled(model.contacts.isEmpty)
                    .help("Export all contacts as a .vcf file")
            }
        }
    }
}

struct ContactDetailView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let c = model.selectedContact {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Color.accentColor.opacity(0.2)).frame(width: 64, height: 64)
                            Text(c.initials).font(.title2).fontWeight(.semibold).foregroundStyle(.tint)
                        }
                        VStack(alignment: .leading) {
                            Text(c.fullName).font(.title2).bold().textSelection(.enabled)
                            if !c.organization.isEmpty { Text(c.organization).foregroundStyle(.secondary) }
                        }
                    }
                    if !c.phones.isEmpty { DetailSection(title: "Phone", values: c.phones, icon: "phone") }
                    if !c.emails.isEmpty { DetailSection(title: "Email", values: c.emails, icon: "envelope") }
                    if !c.nickname.isEmpty { DetailSection(title: "Nickname", values: [c.nickname], icon: "person") }
                    if !c.note.isEmpty { DetailSection(title: "Note", values: [c.note], icon: "note.text") }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No Contact Selected", systemImage: "person.crop.circle")
        }
    }
}

private struct DetailSection: View {
    let title: String
    let values: [String]
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
            ForEach(values, id: \.self) { v in
                Text(v).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
