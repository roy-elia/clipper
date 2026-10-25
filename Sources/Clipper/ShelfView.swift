import SwiftUI
import DropCore

@MainActor
final class ShelfModel: ObservableObject {
    @Published var query = ""
    @Published var kind: ClipKind?
    @Published var items: [ClipItem] = []
    let store: HistoryStore
    var onPick: ((ClipItem) -> Void)?
    init(store: HistoryStore) { self.store = store; refresh() }
    func refresh() { items = store.search(query, kind: kind) }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search clips", text: $model.query)
                    .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.quaternary, in: Capsule())
                    .accessibilityIdentifier("shelf.search")
                chip("All", nil)
                ForEach(ClipKind.allCases, id: \.self) { chip($0.rawValue.capitalized, $0) }
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(model.items) { item in
                        Card(item: item).onTapGesture { model.onPick?(item) }
                            .accessibilityIdentifier("shelf.card.\(item.id)")
                    }
                }.padding(.vertical, 2)
            }
        }
        .padding(14).frame(width: 760, height: 190)
        .onChange(of: model.query) { model.refresh() }
        .onChange(of: model.kind) { model.refresh() }
    }

    func chip(_ title: String, _ k: ClipKind?) -> some View {
        Button(title) { model.kind = k }
            .buttonStyle(.plain).font(.callout).padding(.horizontal, 10).padding(.vertical, 5)
            .background(model.kind == k ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.quaternary), in: Capsule())
    }
}

struct Card: View {
    let item: ClipItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.kind.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(item.text ?? item.title).font(.callout).lineLimit(4)
            Spacer(minLength: 0)
            Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(width: 150, height: 110, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
