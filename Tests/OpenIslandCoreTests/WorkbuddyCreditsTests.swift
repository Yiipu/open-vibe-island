import Foundation
import Testing
@testable import OpenIslandCore

struct WorkbuddyCreditsTests {
    private func makeTempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-wb-credits-\(UUID().uuidString).json")
    }

    @Test
    func cacheRoundTripsSnapshot() throws {
        let url = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = WorkbuddyCreditsSnapshot(
            accounts: [
                WorkbuddyAccountCredits(uid: "a1", nickname: "alpha", credits: 12_110),
                WorkbuddyAccountCredits(uid: "a2", nickname: nil, credits: 3_930),
            ],
            fetchedAt: fetchedAt
        )

        WorkbuddyCreditsCache.save(snapshot, url: url)

        let loaded = WorkbuddyCreditsCache.load(url: url)
        #expect(loaded == snapshot)
        #expect(loaded?.totalCredits == 16_040)
    }

    @Test
    func cacheLoadReturnsNilForMissingFile() {
        #expect(WorkbuddyCreditsCache.load(url: makeTempCacheURL()) == nil)
    }

    @Test
    func cacheRemoveDeletesFile() {
        let url = makeTempCacheURL()
        WorkbuddyCreditsCache.save(
            WorkbuddyCreditsSnapshot(accounts: [], fetchedAt: Date()),
            url: url
        )
        WorkbuddyCreditsCache.remove(url: url)
        #expect(WorkbuddyCreditsCache.load(url: url) == nil)
    }

    @Test
    func snapshotTotalIgnoresEmptyAccounts() {
        let empty = WorkbuddyCreditsSnapshot(accounts: [], fetchedAt: Date())
        #expect(empty.isEmpty)
        #expect(empty.totalCredits == 0)
    }
}
