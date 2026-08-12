import Cog
import CogTesting
import Testing

@MainActor
@Test func weatherStateStartsWithoutACurrentLocation() {
  let cogs = Cogtext.forTesting()

  #expect(cogs.read(currentZipCode) == nil)
}
