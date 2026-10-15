import SwiftUI

/// The list of top-level destinations.
struct SidebarView: View {
    @Binding var selection: SidebarDestination?

    var body: some View {
        List(SidebarDestination.allCases, selection: $selection) { destination in
            Label {
                Text(destination.titleKey, bundle: .module)
            } icon: {
                Image(systemName: destination.systemImage)
                    .accessibilityHidden(true)
            }
            .tag(destination)
            .accessibilityIdentifier("sidebar.\(destination.rawValue)")
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }
}

extension SidebarDestination {
    var titleKey: LocalizedStringKey {
        switch self {
        case .devices: "sidebar.devices"
        case .profiles: "sidebar.profiles"
        case .permissions: "sidebar.permissions"
        }
    }

    var systemImage: String {
        switch self {
        case .devices: "computermouse"
        case .profiles: "person.crop.rectangle.stack"
        case .permissions: "lock.shield"
        }
    }
}
