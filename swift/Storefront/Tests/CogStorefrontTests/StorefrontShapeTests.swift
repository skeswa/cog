import Foundation
import Testing

@testable import CogStorefront

/// The workload's shape, asserted rather than described.
///
/// A macrobenchmark is only representative of anything if its size is known, so
/// these tests replace every "approximately" in the design with an exact
/// constant or a mechanically checked range. They are cheap and they run in the
/// package's ordinary suite, because a workload that silently grew a
/// declaration would otherwise make every recorded number incomparable with the
/// one before it.
@Suite("Storefront workload shape")
struct StorefrontShapeTests {
  /// The declaration census, hand-written here and mechanically checked below.
  ///
  /// These are the numbers `impl/benchmarks.md` quotes. If a declaration is added or
  /// removed, this test fails first and the record is updated deliberately
  /// rather than drifting.
  static let expectedDeclarationCounts: [String: Int] = [
    "Cog.Manual": 12,
    "CogBox.Manual": 5,
    "Cog": 18,
    "CogBox": 8,
    "Cog.Async": 7,
    "CogBox.Async": 3,
  ]

  /// The directory holding the module's sources, derived from this file's path.
  static var sourcesDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // CogStorefrontTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Storefront
      .appendingPathComponent("Sources")
      .appendingPathComponent("CogStorefront")
  }

  /// Counts file-scope declarations of each Cog kind across the module.
  ///
  /// Syntax-only, deliberately: a census that resolved types would need a
  /// compiler, and a census that trusted a hand-maintained list would not be a
  /// census. A declaration is counted when a `let` binding at column zero is
  /// initialized with one of the six nominal spellings.
  static func declarationCounts() throws -> [String: Int] {
    var counts: [String: Int] = [:]
    let files = try FileManager.default.contentsOfDirectory(
      at: sourcesDirectory,
      includingPropertiesForKeys: nil
    )
    for file in files where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        // File scope only: a declaration inside a type or a function is
        // indented, and a local Cog is invisible to this census exactly as it
        // is to CogLint's own classifier.
        guard line.first != " ", line.contains("let ") else { continue }
        guard
          let family = line.contains("= CogBox<") ? "CogBox" : line.contains("= Cog<") ? "Cog" : nil
        else { continue }
        let member =
          line.contains(">.Manual") ? ".Manual" : line.contains(">.Async") ? ".Async" : ""
        counts[family + member, default: 0] += 1
      }
    }
    return counts
  }

  @Test("the declaration census is exactly what benchmarks.md records")
  func declarationCensus() throws {
    let counts = try Self.declarationCounts()
    for (kind, expected) in Self.expectedDeclarationCounts {
      #expect(counts[kind, default: 0] == expected, "\(kind) count drifted")
    }
  }

  @Test("the standard profile is the representative workload v1")
  func standardProfileShape() {
    let profile = StorefrontProfile.standard
    #expect(profile.productCount == 1_200)
    #expect(profile.categoryCount == 24)
    #expect(profile.visitedRowCount == 120)
    #expect(profile.viewportRowCount == 30)
    #expect(profile.pricingPolicyCount == 16)
    #expect(profile.priceBookCount == 1)
    #expect(profile.pricingStageCount == 16)
  }

  @Test("every profile's policy prefix is a real prefix of the ladder")
  func policyPrefixIsReal() {
    for profile in StorefrontProfile.all {
      #expect(profile.pricingPolicyCount <= StorefrontPricing.ladder.count)
      #expect(profile.pricingPolicyCount > 0)
      #expect(profile.priceBookCount <= StorefrontPricing.PriceBook.allCases.count)
    }
  }

  @Test("the stress profile is a substantially deeper pipeline")
  func stressIsDeeper() {
    #expect(StorefrontProfile.stress.pricingStageCount == 48)
    #expect(
      StorefrontProfile.stress.pricingStageCount
        > StorefrontProfile.standard.pricingStageCount * 2
    )
  }

  @Test("the standard catalog has the size and even category spread it claims")
  func catalogShape() {
    let profile = StorefrontProfile.standard
    let catalog = StorefrontFixtures.catalog(for: profile)
    #expect(catalog.products.count == profile.productCount)
    #expect(catalog.categories.count == profile.categoryCount)
    var perCategory: [CategoryID: Int] = [:]
    for product in catalog.products { perCategory[product.category, default: 0] += 1 }
    #expect(perCategory.count == profile.categoryCount)
    let sizes = Set(perCategory.values)
    #expect(sizes.count == 1, "products should be spread evenly across categories")
  }

  @Test("the search phase types one character per operation")
  func searchPlanShape() {
    #expect(StorefrontSession.searchTarget == "trail shoes")
    #expect(StorefrontSession.searchPrefixes.count == StorefrontSession.searchTarget.count)
    // "trail " and "trail" normalize the same way, so one prefix starts no new
    // generation. The expectation is derived, not observed.
    #expect(
      StorefrontSession.distinctNormalizedQueries.count
        == StorefrontSession.searchPrefixes.count - 1
    )
  }

  @Test("steady interactions keep changing retained per-product state")
  func steadyInteractionSequence() throws {
    let products = [ProductID(7), ProductID(11), ProductID(13)]
    let first = try #require(
      StorefrontSession.steadyInteraction(at: 0, products: products, variantCount: 4)
    )
    let nextLap = try #require(
      StorefrontSession.steadyInteraction(at: products.count, products: products, variantCount: 4)
    )
    let thirdLap = try #require(
      StorefrontSession.steadyInteraction(
        at: products.count * 2,
        products: products,
        variantCount: 4
      )
    )

    #expect(first.productID == nextLap.productID)
    #expect(first.quantity == 1)
    #expect(nextLap.quantity == 2)
    #expect(thirdLap.quantity == 1)
    #expect(first.variantIndex == 1)
    #expect(nextLap.variantIndex == 2)
    #expect(thirdLap.variantIndex == 3)
    #expect(first.viewRank == 1)
    #expect(nextLap.viewRank == 4)
    #expect(thirdLap.viewRank == 7)
  }

  @Test("the standard compute control has a stable semantic signature")
  func computeControlSignature() {
    let profile = StorefrontProfile.standard
    let catalog = StorefrontFixtures.catalog(for: profile)
    let shopper = StorefrontFixtures.shopper(for: profile)
    let index = StorefrontKernels.buildSearchIndex(products: catalog.products)
    let candidates = Set(
      StorefrontKernels.candidates(
        in: index,
        tokens: StorefrontKernels.tokenize(StorefrontSession.searchTarget),
        productCount: catalog.products.count
      ).map(ProductID.init)
    )
    let cartIDs = StorefrontSession.cartProductIDs(for: profile, catalog: catalog)
    #expect(candidates.isDisjoint(with: cartIDs))
    #expect(
      cartIDs.enumerated().contains { position, id in
        let product = catalog.products[id.raw]
        return StorefrontPricing.effectivePriceWithoutGraph(
          product: product,
          variantIndex: 0,
          profile: profile,
          shopper: shopper,
          address: StorefrontFixtures.startingAddress,
          inventory: StorefrontFixtures.inventory(
            for: id,
            generation: 0,
            profile: profile
          ),
          offer: StorefrontFixtures.offer(for: id, shopper: shopper),
          coupon: StorefrontFixtures.sessionCoupon,
          cartQuantity: position + 1
        ) != product.listPriceCents
      }
    )
    let result = StorefrontKernels.computeControl(for: profile, catalog: catalog)

    // This covers the search index, ranking, directly priced cart lines,
    // promotion plan, and recommendations. Change it deliberately when the
    // representative workload changes; a mere implementation change should
    // preserve it.
    #expect(result.checksum == 1_907_130_560_780_147_234)
  }
}
