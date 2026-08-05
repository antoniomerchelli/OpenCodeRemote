import Foundation

// MARK: - RecentModelsStore

/// Store LRU dei modelli usati di recente (persistito su `UserDefaults`),
/// analogo a `context/models.tsx` del web (`RECENT_LIMIT = 5`).
public actor RecentModelsStore {
    private let limit: Int
    private let defaults: UserDefaults
    private let storageKey: String

    /// Modelli ordinati dal più recente al più vecchio.
    private var models: [String]

    public init(
        limit: Int = CoreConstants.recentModelsLimit,
        defaults: UserDefaults = .standard,
        storageKey: String = "opencode.recentModels"
    ) {
        self.limit = limit
        self.defaults = defaults
        self.storageKey = storageKey
        self.models = Self.load(from: defaults, key: storageKey)
    }

    /// Registra un modello come usato (move-to-front + persist).
    public func record(modelID: String) {
        models.removeAll { $0 == modelID }
        models.insert(modelID, at: 0)
        if models.count > limit {
            models = Array(models.prefix(limit))
        }
        save()
    }

    /// Modelli recenti (dal più recente al più vecchio).
    public func recent() -> [String] {
        models
    }

    /// Rimuove un modello dalla lista recenti (es. rimosso dai provider).
    public func remove(modelID: String) {
        models.removeAll { $0 == modelID }
        save()
    }

    /// Svuota la lista.
    public func clear() {
        models = []
        save()
    }

    // MARK: - Persistenza

    private func save() {
        if let data = try? JSONEncoder().encode(models) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> [String] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }
}

// MARK: - ModelVariantResolver

/// Risoluzione statistica della *variant* di un modello, analoga a
/// `resolveModelVariant` / `cycleModelVariant` di `context/model-variant.ts`.
///
/// La variante vive dentro `model.variants` (lista ordinata, in genere
/// `["default", ...altre]`); `resolveVariant` sceglie quella da usare per una
/// base, `cycleVariant` passa alla successiva ciclando.
public enum ModelVariantResolver {
    /// Risolve la variante da usare per il modello di riferimento `base`
    /// (un `modelID` o un nome).
    ///
    /// - Preferenza: `configured` se valida → `base` se valida → prima della lista.
    /// - `nil` se il modello non esiste o non dichiara varianti.
    public static func resolveVariant(models: [ModelV2], base: String, configured: String? = nil) -> String? {
        let variants = variants(for: base, in: models)
        guard !variants.isEmpty else { return nil }

        if let configured, variants.contains(configured) {
            return configured
        }
        if variants.contains(base) {
            return base
        }
        return variants.first
    }

    /// Cicla alla variante successiva del modello a cui appartiene `current`.
    /// Dall'ultima tornare a `nil` (variante disattivata → default del modello).
    public static func cycleVariant(models: [ModelV2], current: String) -> String? {
        for model in models {
            guard let variants = model.variants, variants.contains(current),
                  let index = variants.firstIndex(of: current) else { continue }
            let next = variants.index(after: index)
            return next < variants.endIndex ? variants[next] : nil
        }
        return nil
    }

    /// Varianti dichiarate dal modello che corrisponde a `reference`
    /// (per `id`, `name` o contenente `reference` tra le proprie varianti).
    private static func variants(for reference: String, in models: [ModelV2]) -> [String] {
        let matching = models.first {
            $0.id == reference || $0.name == reference || $0.variants?.contains(reference) == true
        }
        return matching?.variants ?? []
    }
}
