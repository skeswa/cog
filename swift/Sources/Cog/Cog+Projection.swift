extension Cog {
  /// A read-only value reference for one ``Cog/Manual`` declaration.
  ///
  /// Keep a source `private`, then publish its `.readOnly` projection under the
  /// source's name without the leading underscore:
  ///
  /// ```swift
  /// // WeatherRig+Cogs.swift
  /// private let _currentZipCog = Cog<ZipCode?>.Manual { nil }
  /// let currentZipCog = _currentZipCog.readOnly
  /// ```
  ///
  /// The projection creates no descriptor or state and stores no value. It keeps
  /// the source identity and behavior, so both references perform the same graph
  /// read.
  ///
  /// ``Writer`` accepts only ``Cog/Manual``, so passing this projection is a
  /// compile-time error. Keep the source private in its state file; the
  /// projection removes write capability but does not replace access control.
  @MainActor
  public struct Projection {
    /// The source this value reference reads.
    ///
    /// Internal so callers cannot recover or construct a writable source.
    internal let sourceCog: Cog<Value>.Manual
  }
}

// MARK: - Projecting a source

extension Cog.Manual {
  /// A read-only reference to this source's state.
  ///
  /// Publish it beside the private source. Give the source a leading underscore
  /// and give this projection the plain domain name:
  ///
  /// ```swift
  /// private let _weatherServiceCog = Cog<WeatherService>.Manual { .live }
  /// let weatherServiceCog = _weatherServiceCog.readOnly
  /// ```
  ///
  /// The source and projection name the same state in every context. Accessing
  /// this property allocates no new descriptor and does not create state.
  public var readOnly: Cog<Value>.Projection {
    Cog.Projection(sourceCog: self)
  }
}

// MARK: - Reading

extension Cogs {
  /// Reads a read-only value reference's current value without creating a dependency edge.
  ///
  /// This one-shot read observes the latest completed turn and never sees a
  /// value staged by an in-progress turn. Use a ``Reader`` or
  /// ``ReactionReader`` subscript when later writes should retrigger work.
  ///
  /// - Parameter valueReference: The read-only value reference to read.
  /// - Returns: The value the source it names holds in this context.
  public func peek<Value>(_ valueReference: Cog<Value>.Projection) -> Value {
    peek(valueReference.sourceCog)
  }
}
