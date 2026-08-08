import XCTest
@testable import OpenCodeRemote

// MARK: - RecentModelsStoreTests
//
// Store LRU dei modelli recenti: aggiunta, dedup, ordine, limite e
// persistenza su UserDefaults (suite isolata, mai `.standard`).
// Include anche `ModelVariantResolver`, che vive nello stesso file sorgente.

final class RecentModelsStoreTests: XCTestCase {

    private var suites: [String] = []

    override func tearDown() async throws {
        for name in suites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suites.removeAll()
        try await super.tearDown()
    }

    /// Crea una UserDefaults isolata per test e ne ricorda la suite per la pulizia.
    private func makeDefaults() throws -> UserDefaults {
        let name = "test.recentModels.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw XCTSkip("UserDefaults suite non creabile")
        }
        suites.append(name)
        return defaults
    }

    private func makeStore(
        limit: Int = CoreConstants.recentModelsLimit,
        defaults: UserDefaults,
        storageKey: String = "opencode.recentModels"
    ) -> RecentModelsStore {
        RecentModelsStore(limit: limit, defaults: defaults, storageKey: storageKey)
    }

    // MARK: - RecentModelsStore

    func testRecent_whenEmptyStore_shouldReturnEmptyList() async throws {
        let store = makeStore(defaults: try makeDefaults())
        let recent = await store.recent()
        XCTAssertEqual(recent, [])
    }

    func testRecord_addsNewModelToFront_shouldReturnNewestFirst() async throws {
        let store = makeStore(defaults: try makeDefaults())
        await store.record(modelID: "a")
        await store.record(modelID: "b")
        await store.record(modelID: "c")

        let recent = await store.recent()
        XCTAssertEqual(recent, ["c", "b", "a"], "l'ordine deve essere dal più recente al più vecchio")
    }

    func testRecord_whenDuplicateModel_shouldMoveToFrontAndDeduplicate() async throws {
        let store = makeStore(defaults: try makeDefaults())
        await store.record(modelID: "a")
        await store.record(modelID: "b")
        await store.record(modelID: "a")

        let recent = await store.recent()
        XCTAssertEqual(recent, ["a", "b"], "il duplicato deve essere spostato in testa, non duplicato")
    }

    func testRecord_whenOverLimit_shouldTrimKeepingNewest() async throws {
        let store = makeStore(limit: 3, defaults: try makeDefaults())
        for id in ["a", "b", "c", "d", "e"] {
            await store.record(modelID: id)
        }

        let recent = await store.recent()
        XCTAssertEqual(recent.count, 3, "oltre il limite la lista deve essere tagliata")
        XCTAssertEqual(recent, ["e", "d", "c"], "i più vecchi devono essere scartati")
    }

    func testRecord_withEmptyStringModelID_shouldStillKeepEntry() async throws {
        let store = makeStore(defaults: try makeDefaults())
        await store.record(modelID: "")

        let recent = await store.recent()
        XCTAssertEqual(recent, [""])
    }

    func testRemove_removesModel_shouldKeepOthersOrdered() async throws {
        let store = makeStore(defaults: try makeDefaults())
        await store.record(modelID: "a")
        await store.record(modelID: "b")
        await store.record(modelID: "c")
        await store.remove(modelID: "b")

        let recent = await store.recent()
        XCTAssertEqual(recent, ["c", "a"], "rimozione in mezzo deve preservare l'ordine relativo")
    }

    func testRemove_whenModelUnknown_shouldBeNoOp() async throws {
        let store = makeStore(defaults: try makeDefaults())
        await store.record(modelID: "a")
        await store.record(modelID: "b")
        await store.remove(modelID: "zzz")

        let recent = await store.recent()
        XCTAssertEqual(recent, ["b", "a"])
    }

    func testClear_shouldEmptyList() async throws {
        let store = makeStore(defaults: try makeDefaults())
        await store.record(modelID: "a")
        await store.record(modelID: "b")
        await store.clear()

        let recent = await store.recent()
        XCTAssertEqual(recent, [])
    }

    func testPersistence_whenReloaded_shouldRestoreRecentModels() async throws {
        let defaults = try makeDefaults()
        let first = makeStore(defaults: defaults)
        await first.record(modelID: "a")
        await first.record(modelID: "b")

        let second = makeStore(defaults: defaults)
        let recent = await second.recent()
        XCTAssertEqual(recent, ["b", "a"], "una nuova istanza sulla stessa suite deve leggere i dati persistiti")
    }

    func testPersistence_afterClear_shouldLoadEmptyOnReload() async throws {
        let defaults = try makeDefaults()
        let first = makeStore(defaults: defaults)
        await first.record(modelID: "a")
        await first.clear()

        let second = makeStore(defaults: defaults)
        let recent = await second.recent()
        XCTAssertEqual(recent, [])
    }

    // MARK: - ModelVariantResolver

    func testResolveVariant_whenConfiguredValid_shouldUseConfigured() {
        let models = [ModelV2(id: "m1", providerID: "p", name: "Model One", variants: ["default", "fast"])]
        let resolved = ModelVariantResolver.resolveVariant(models: models, base: "m1", configured: "fast")
        XCTAssertEqual(resolved, "fast")
    }

    func testResolveVariant_whenConfiguredInvalid_shouldFallbackToFirstVariant() {
        let models = [ModelV2(id: "m1", providerID: "p", name: "Model One", variants: ["default", "fast"])]
        let resolved = ModelVariantResolver.resolveVariant(models: models, base: "m1", configured: "nope")
        XCTAssertEqual(resolved, "default")
    }

    func testResolveVariant_whenBaseIsVariant_shouldUseBase() {
        let models = [ModelV2(id: "m1", providerID: "p", name: "Model One", variants: ["m1", "fast"])]
        let resolved = ModelVariantResolver.resolveVariant(models: models, base: "m1")
        XCTAssertEqual(resolved, "m1")
    }

    func testResolveVariant_whenBaseMatchesName_shouldUseModelVariants() {
        let models = [ModelV2(id: "m1", providerID: "p", name: "Model One", variants: ["default"])]
        let resolved = ModelVariantResolver.resolveVariant(models: models, base: "Model One")
        XCTAssertEqual(resolved, "default")
    }

    func testResolveVariant_whenModelMissingOrNoVariants_shouldReturnNil() {
        let noVariants = [ModelV2(id: "m1", providerID: "p", name: "Model One", variants: nil)]
        XCTAssertNil(ModelVariantResolver.resolveVariant(models: [], base: "m1"))
        XCTAssertNil(ModelVariantResolver.resolveVariant(models: noVariants, base: "m1"))
    }

    func testResolveVariant_whenBaseMatchesAnotherVariant_shouldUseBase() {
        let models = [ModelV2(id: "m1", providerID: "p", name: "Model One", variants: ["a", "b"])]
        let resolved = ModelVariantResolver.resolveVariant(models: models, base: "b")
        XCTAssertEqual(resolved, "b", "la base è una variante valida → si usa la base (non la prima della lista)")
    }

    func testCycleVariant_whenNotLast_shouldReturnNext() {
        let models = [ModelV2(id: "m1", providerID: "p", name: "Model One", variants: ["a", "b", "c"])]
        XCTAssertEqual(ModelVariantResolver.cycleVariant(models: models, current: "b"), "c")
    }

    func testCycleVariant_whenLast_shouldReturnNil() {
        let models = [ModelV2(id: "m1", providerID: "p", name: "Model One", variants: ["a", "b"])]
        XCTAssertNil(ModelVariantResolver.cycleVariant(models: models, current: "b"))
    }

    func testCycleVariant_whenCurrentUnknown_shouldReturnNil() {
        let models = [ModelV2(id: "m1", providerID: "p", name: "Model One", variants: ["a", "b"])]
        XCTAssertNil(ModelVariantResolver.cycleVariant(models: models, current: "zzz"))
    }
}
