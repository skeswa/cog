/// The pre-0.5 spelling for a keyless manual Cog declaration.
@available(*, deprecated, renamed: "Cog.Manual")
public typealias ManualCog<Value> = Cog<Value>.Manual

/// The pre-0.5 spelling for a keyless async Cog declaration.
@available(*, deprecated, renamed: "Cog.Async")
public typealias AsyncCog<Value> = Cog<Value>.Async

/// The pre-0.5 spelling for a keyed manual Cog declaration.
@available(*, deprecated, renamed: "CogBox.Manual")
public typealias ManualCogBox<Value, Key: Hashable> = CogBox<Value, Key>.Manual

/// The pre-0.5 spelling for a keyed async Cog declaration.
@available(*, deprecated, renamed: "CogBox.Async")
public typealias AsyncCogBox<Value, Key: Hashable> = CogBox<Value, Key>.Async

/// The pre-0.5 spelling for a keyless read-only source projection.
@available(*, deprecated, renamed: "Cog.Projection")
public typealias CogProjection<Value> = Cog<Value>.Projection

/// The pre-0.5 spelling for a keyed read-only source projection.
@available(*, deprecated, renamed: "CogBox.Projection")
public typealias CogBoxProjection<Value, Key: Hashable> = CogBox<Value, Key>.Projection
