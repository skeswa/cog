/// A ref that reads one source's state and cannot write it.
///
/// `.readOnly` is the second half of the write-ownership rule (§4). A source is
/// declared `fileprivate` so that only its own file can name it, and that file
/// then publishes this projection so the rest of the app can read the state
/// without being able to change it:
///
/// ```swift
/// // WeatherState.swift
/// fileprivate let currentZipSource = ManualCog<ZipCode?>(nil)
/// let currentZipCode = currentZipSource.readOnly
/// ```
///
/// A read-only ref is still a ref, and still names the same one piece of state:
/// it creates no second node, holds no copy of the value, and reading it in a
/// context always gives exactly what reading the source in that context would
/// give. Projecting is free — the same descriptor and key wearing a different
/// type — so a file may publish one at declaration time and never think about
/// it again.
///
/// What a read-only ref does not have is a way back. It stores the source
/// internally, so no code outside Cog can recover a writable ref from one, and
/// ``Writer``'s subscript takes a ``ManualCog``. Handing it a `ReadOnlyCog` is a
/// type error, not a runtime trap: a write nobody can spell is a write nobody
/// can ship.
@MainActor
public struct ReadOnlyCog<Value> {
  /// The source this ref reads.
  ///
  /// Deliberately the only stored property, and deliberately internal. Storing
  /// the source rather than re-deriving a descriptor and key is what makes the
  /// projection free and keeps "same ref, same state" true by construction;
  /// keeping it internal is what makes the projection one-way.
  ///
  /// Its memberwise initializer is internal for the same reason: the spelling
  /// users get is ``ManualCog/readOnly``, which reads as a property of the
  /// source rather than as a wrapper someone could also build around a source
  /// they were handed.
  internal let source: ManualCog<Value>
}

// MARK: - Projecting a source

extension ManualCog {
  /// A ref naming this source's state that cannot be used to write it.
  ///
  /// Publish this next to the source, in the file that owns it, and keep the
  /// source itself `fileprivate` (§4):
  ///
  /// ```swift
  /// fileprivate let weatherServiceSource = ManualCog<WeatherService>(.live)
  /// let weatherService = weatherServiceSource.readOnly
  /// ```
  ///
  /// Both refs name one node, so a write made through the source in that file
  /// is immediately what every reader of the projection sees.
  public var readOnly: ReadOnlyCog<Value> {
    ReadOnlyCog(source: self)
  }
}

// MARK: - Reading

extension Cogtext {
  /// Reads a read-only ref's current value without creating a dependency edge.
  ///
  /// The same one-shot untracked read as the one for a source (§2.4), on the
  /// same node — projecting a source changes who may write it, never how it is
  /// read or what a read means.
  ///
  /// This is an overload rather than one read generic over a "readable ref"
  /// protocol. Such a protocol would have to be public to appear in a public
  /// signature, and so would its witness, which would publish the read
  /// mechanism as API before §10's open question 1 has even settled the read
  /// *spelling*. Unifying the readable ref kinds belongs with derived cogs
  /// (`M1-05a`), which is where a second readable kind first exists to unify.
  ///
  /// - Parameter ref: The read-only ref to read.
  /// - Returns: The value the source it names holds in this context.
  public func read<Value>(_ ref: ReadOnlyCog<Value>) -> Value {
    read(ref.source)
  }
}
