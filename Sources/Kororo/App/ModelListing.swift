import Foundation

/// Which registered providers the app lists. The built-in embedder is an implementation detail of
/// search and indexing, so it stays registered but is never shown; embedding providers the user adds
/// themselves are still listed.
public enum ModelListing {
    public static func visible(_ infos: [ModelInfo]) -> [ModelInfo] {
        infos.filter { $0.id != LocalEmbedder.defaultID }
    }
}
