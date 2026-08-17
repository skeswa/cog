public import Cog

extension Cogs {
  /// The value-reference layout the `Cog` library was compiled with, in the
  /// spelling `COG_TEST_VALUE_REFERENCE_LAYOUT` uses.
  ///
  /// The narrow seam behind the layout matrix, and the same shape as LEG-02's
  /// isolation defines: a build states which candidate it is, so a test can
  /// hold that against the candidate the environment asked for. Without it a
  /// manifest that quietly stopped reading the variable would compile every
  /// candidate identically, and every candidate would still pass.
  ///
  /// A name rather than the layout type itself, deliberately. `M5-09b` and
  /// `M5-09c` change what a key physically is; a test that could see the type
  /// would fail those swaps for reasons that have nothing to do with behavior.
  public static var valueReferenceLayoutName: String {
    valueReferenceLayoutNameForTesting
  }
}
