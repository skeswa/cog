import 'dart:async';

final class FakeObservable<T> {
  final bool isSync;

  var _hasListeners = false;
  late final _streamController = StreamController<T>.broadcast(
    sync: isSync,
    onCancel: () => _hasListeners = false,
    onListen: () => _hasListeners = true,
  );
  T _value;

  FakeObservable(this._value, {this.isSync = false});

  bool get hasListeners => _hasListeners;

  Stream<T> get stream => _streamController.stream;

  T get value => _value;

  set value(T value) {
    _value = value;

    _streamController.add(value);
  }
}
