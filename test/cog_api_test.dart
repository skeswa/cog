import 'dart:async';
import 'dart:math';

import 'package:cog/cog.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/helpers.dart';

void main() {
  group('Cog API', () {
    late Cogtext cogtext;
    late TestingCogStateRuntimeLogger logging;

    setUpLogging();

    setUp(() {
      logging = TestingCogStateRuntimeLogger();
    });

    group('Auxilliary details', () {
      test('automatic Cogs should be stringifiable', () {
        final fourCog = Cog((c) => 4, spin: Spin<bool>());
        final falseCog = Cog(
          (c) => false,
          debugLabel: 'falseCog',
          ttl: 1.seconds,
        );
        final helloCog = Cog(
          (c) => 'hello',
          debugLabel: 'helloCog',
          async: Async.latestOnly,
          eq: (a, b) => a.length == b.length,
        );

        expect('$fourCog', 'AutomaticCog<int, bool>()');
        expect(
          '$falseCog',
          'AutomaticCog<bool>(debugLabel: "falseCog", ttl: 0:00:01.000000)',
        );
        expect(
          '$helloCog',
          'AutomaticCog<String>('
              'async: Async.latestOnly, debugLabel: "helloCog", eq: overridden'
              ')',
        );
      });

      test('manual Cogs should be stringifiable', () {
        final fourCog = Cog.man(null.init<int>(), spin: Spin<bool>());
        final falseCog = Cog.man(() => false, debugLabel: 'falseCog');
        final helloCog = Cog.man(
          () => '',
          debugLabel: 'helloCog',
          eq: (a, b) => a.length == b.length,
        );

        expect('$fourCog', 'ManualCog<int?, bool>()');
        expect(
          '$falseCog',
          'ManualCog<bool>(debugLabel: "falseCog")',
        );
        expect(
          '$helloCog',
          'ManualCog<String>(debugLabel: "helloCog", eq: overridden)',
        );
      });

      test('Priority should be stringifiable', () {
        expect('${Priority.asap}', 'asap');
        expect('${Priority.low}', 'low');
        expect('${Priority.high}', 'high');
        expect('${Priority.normal}', 'normal');
      });

      test('Spin<T> requires T', () {
        expect(() => Spin<dynamic>(), throwsArgumentError);
        expect(() => Spin(), throwsArgumentError);
      });

      test('null.of<T>() returns a function that returns null', () {
        expect(null.init<int>(), isA<int? Function()>());
        expect(null.init<int>()(), isNull);
      });

      test('null.of<T>() requires T', () {
        expect(() => null.init<dynamic>(), throwsArgumentError);
        expect(() => null.init(), throwsArgumentError);
      });

      test('int.duration should work as expected', () {
        expect(3.days, equals(3.days));
        expect(3.hours, equals(3.hours));
        expect(3.microseconds, equals(3.microseconds));
        expect(3.milliseconds, equals(3.milliseconds));
        expect(3.minutes, equals(3.minutes));
        expect(3.seconds, equals(3.seconds));
      });

      test('Cogtext cog state runtime should be optionally replaceable', () {
        expect(
          () => Cogtext(),
          isNot(throwsA(anything)),
        );
        expect(
          () => Cogtext(cogStateRuntime: const NoOpCogStateRuntime()),
          isNot(throwsA(anything)),
        );
      });
    });

    group('Simple reading', () {
      setUp(() {
        cogtext = Cogtext();
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('reading from a spun automatic Cog without specifying spin throws',
          () {
        final numberCog = Cog((c) {
          return 4;
        }, spin: Spin<bool>());

        expect(() => numberCog.read(cogtext), throwsArgumentError);
      });

      test('reading from a spun manual Cog without specifying spin throws', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(() => numberCog.read(cogtext), throwsArgumentError);
      });

      test(
          'reading from an unspun automatic Cog without specifying spin throws',
          () {
        final numberCog = Cog((c) {
          return 4;
        });

        expect(() => numberCog.read(cogtext, spin: false), throwsArgumentError);
      });

      test('reading from an unspun manual Cog without specifying spin throws',
          () {
        final numberCog = Cog.man(() => 4);

        expect(() => numberCog.read(cogtext, spin: false), throwsArgumentError);
      });

      test('reading from a spun manual Cog returns its current value', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(numberCog.read(cogtext, spin: false), equals(4));
      });

      test('reading from a spun automatic Cog returns its value', () {
        final numberCog = Cog((c) {
          return 4;
        }, spin: Spin<bool>());

        expect(numberCog.read(cogtext, spin: false), equals(4));
      });

      test('reading from an unspun manual Cog returns its value', () {
        final numberCog = Cog.man(() => 4);

        expect(numberCog.read(cogtext), equals(4));
      });

      test('reading from an unspun automatic Cog returns its value', () {
        final numberCog = Cog((c) {
          return 4;
        });

        expect(numberCog.read(cogtext), equals(4));
      });

      test(
          'reading from an automatic Cog that did not initialize '
          'correctly throws', () {
        final numberCog = Cog((c) {
          throw Error();
        }, spin: Spin<bool>());

        expect(
          () => numberCog.read(cogtext, spin: false),
          throwsA(isA<Error>()),
        );
      });

      test(
          'reading from an async spun automatic Cog without '
          'specifying init throws', () {
        final numberCog = Cog((c) async {
          return 4;
        }, spin: Spin<bool>());

        expect(() => numberCog.read(cogtext), throwsArgumentError);
      });

      test(
          'reading from an async unspun automatic Cog without '
          'specifying init throws', () {
        final numberCog = Cog((c) async {
          return 4;
        });

        expect(() => numberCog.read(cogtext), throwsArgumentError);
      });

      test(
          'reading from an async spun automatic Cog that has not resolved yet '
          'returns the init value', () {
        final completer = Completer<void>.sync();

        final numberCog = Cog((c) async {
          await completer.future;

          return 4;
        }, init: () => 3, spin: Spin<bool>());

        expect(numberCog.read(cogtext, spin: false), 3);

        completer.complete();

        expect(numberCog.read(cogtext, spin: false), 4);
      });

      test(
          'reading from an async unspun automatic Cog that has not resolved '
          'yet returns the init value', () {
        final completer = Completer<void>.sync();

        final numberCog = Cog((c) async {
          await completer.future;

          return 4;
        }, init: () => 3);

        expect(numberCog.read(cogtext), 3);

        completer.complete();

        expect(numberCog.read(cogtext), 4);
      });

      test(
          'reading from an automatic Cog that oscillates between async '
          'and sync emits an error', () async {
        final errors = [];

        cogtext = Cogtext(cogStateRuntime: StandardCogStateRuntime(
          onError: ({
            required Cog cog,
            required Object error,
            required Object? spin,
            required StackTrace stackTrace,
          }) {
            errors.add(error);
          },
        ));

        final isAsyncCog = Cog.man(() => true);

        final numberCog = Cog((c) {
          final isAsync = c.link(isAsyncCog);

          if (isAsync) {
            return Future.value(4);
          }

          return 5;
        }, init: () => 3);

        expect(numberCog.read(cogtext), 3);

        await Future.delayed(Duration.zero);

        expect(numberCog.read(cogtext), 4);

        isAsyncCog.write(cogtext, false);

        expect(errors, isNotEmpty);

        expect(numberCog.read(cogtext), 4);
      });

      test(
          'reading from an automatic Cog that oscillates between sync '
          'and async emits an error', () async {
        final errors = [];

        cogtext = Cogtext(cogStateRuntime: StandardCogStateRuntime(
          onError: ({
            required Cog cog,
            required Object error,
            required Object? spin,
            required StackTrace stackTrace,
          }) {
            errors.add(error);
          },
        ));

        final isAsyncCog = Cog.man(() => false);

        final numberCog = Cog((c) {
          final isAsync = c.link(isAsyncCog);

          if (isAsync) {
            return Future.value(4);
          }

          return 5;
        }, init: () => 3);

        expect(numberCog.read(cogtext), 5);

        isAsyncCog.write(cogtext, true);

        await Future.delayed(Duration.zero);

        expect(numberCog.read(cogtext), 5);

        expect(errors, isNotEmpty);
      });

      test(
          'reading from an automatic Cog and referencing c.curr without '
          'providing an init throws', () {
        final numberCog = Cog<int, dynamic>((c) {
          return c.curr + 1;
        });

        expect(() => numberCog.read(cogtext), throwsStateError);
      });

      test(
          'reading from an automatic Cog that links to a non-Cog correctly '
          'reads the non-Cog\'s initial value', () {
        final numberFakeObservable = FakeObservable(1);

        final numberPlusOneCog = Cog((c) {
          final number = c.linkNonCog(
            numberFakeObservable,
            init: (nonCog) => nonCog.value,
            subscribe: (nonCog, onNextValue) =>
                nonCog.stream.listen(onNextValue),
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );

          return number + 1;
        });

        expect(numberPlusOneCog.read(cogtext), 2);
        expect(numberFakeObservable.hasListeners, isTrue);
      });

      test(
          'reading from an automatic Cog that links to a non-Cog correctly '
          'reads the non-Cog\'s current value if that value is emitted '
          'synchronosuly upon subscription', () {
        final numberFakeObservable = FakeObservable(1);

        final numberPlusOneCog = Cog((c) {
          final number = c.linkNonCog(
            numberFakeObservable,
            init: (nonCog) => -100,
            subscribe: (nonCog, onNextValue) {
              final subscription = nonCog.stream.listen(onNextValue);

              onNextValue(100);

              return subscription;
            },
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );

          return number + 1;
        });

        expect(numberPlusOneCog.read(cogtext), 101);
        expect(numberFakeObservable.hasListeners, isTrue);
      });

      test(
          'reading from an automatic Cog that links to a non-Cog correctly '
          'reads the non-Cog\'s latest value', () async {
        cogtext = Cogtext(
          cogStateRuntime: StandardCogStateRuntime(
            logging: logging,
            scheduler: NaiveCogStateRuntimeScheduler(
              logging: logging,
              highPriorityBackgroundTaskDelay: Duration.zero,
              lowPriorityBackgroundTaskDelay: Duration.zero,
            ),
          ),
        );

        final numberFakeObservable = FakeObservable(1, isSync: true);

        final numberPlusOneCog = Cog((c) {
          final number = c.linkNonCog(
            numberFakeObservable,
            init: (nonCog) => nonCog.value,
            subscribe: (nonCog, onNextValue) =>
                nonCog.stream.listen(onNextValue),
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );

          return number + 1;
        });

        expect(numberPlusOneCog.read(cogtext), 2);
        expect(numberFakeObservable.hasListeners, isTrue);

        numberFakeObservable.value = 2;

        await Future.delayed(Duration.zero);

        expect(numberPlusOneCog.read(cogtext), 3);
        expect(numberFakeObservable.hasListeners, isTrue);
      });
    });

    group('Simple watching', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('watching a spun automatic Cog without specifying spin throws', () {
        final numberCog = Cog((c) {
          return 4;
        }, spin: Spin<bool>());

        expect(() => numberCog.watch(cogtext), throwsArgumentError);
      });

      test('watching a spun manual Cog without specifying spin throws', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(() => numberCog.watch(cogtext), throwsArgumentError);
      });

      test(
          'watching an unspun automatic Cog '
          'without specifying spin throws', () {
        final numberCog = Cog((c) {
          return 4;
        });

        expect(
            () => numberCog.watch(cogtext, spin: false), throwsArgumentError);
      });

      test('watching an unspun manual Cog without specifying spin throws', () {
        final numberCog = Cog.man(() => 4);

        expect(
            () => numberCog.watch(cogtext, spin: false), throwsArgumentError);
      });

      test('watching from a spun manual Cog does not throw', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(numberCog.watch(cogtext, spin: false).isBroadcast, isTrue);
      });

      test('watching a spun automatic Cog does not throw', () {
        final numberCog = Cog((c) {
          return 4;
        }, spin: Spin<bool>());

        expect(numberCog.watch(cogtext, spin: false).isBroadcast, isTrue);
      });

      test('watching an unspun manual Cog does not throw', () {
        final numberCog = Cog.man(() => 4);

        expect(numberCog.watch(cogtext).isBroadcast, isTrue);
      });

      test('watching an unspun automatic Cog does not throw', () {
        final numberCog = Cog((c) {
          return 4;
        });

        expect(numberCog.watch(cogtext).isBroadcast, isTrue);
      });

      test(
          'watched automatic Cog with a TTL re-evaluates and '
          'emits on a fixed interval', () {
        fakeAsync((async) {
          final numberCog = Cog(
            (c) => c.currOr(0) < 4 ? c.currOr(0) + 1 : c.currOr(0),
            ttl: 5.seconds,
          );

          expect(numberCog.read(cogtext), 1);

          final emissions = [];

          numberCog.watch(cogtext).listen(emissions.add);

          async.elapse(5.seconds);

          expect(emissions, equals([2]));

          async.elapse(5.seconds);

          expect(emissions, equals([2, 3]));

          async.elapse(5.seconds);

          expect(emissions, equals([2, 3, 4]));

          async.elapse(5.seconds);

          expect(emissions, equals([2, 3, 4]));

          async.elapse(5.seconds);

          expect(emissions, equals([2, 3, 4]));
        });
      });

      test(
          'watching an async spun automatic Cog without '
          'specifying init throws', () {
        final numberCog = Cog((c) async {
          return 4;
        }, spin: Spin<bool>());

        expect(() => numberCog.watch(cogtext), throwsArgumentError);
      });

      test(
          'watching an async unspun automatic Cog without '
          'specifying init throws', () {
        final numberCog = Cog((c) async {
          return 4;
        });

        expect(() => numberCog.watch(cogtext), throwsArgumentError);
      });

      test(
          'watched async spun automatic Cog notifies listeners '
          'when its future resolves', () async {
        final completer = Completer<void>.sync();

        final numberCog = Cog((c) async {
          await completer.future;

          return 4;
        }, init: () => 3, spin: Spin<bool>());

        final emissions = [];

        numberCog.watch(cogtext, spin: false).listen(emissions.add);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        completer.complete();

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4]));
      });

      test(
          'watched async unspun automatic Cog notifies listeners '
          'when its future resolves', () async {
        final completer = Completer<void>.sync();

        final numberCog = Cog((c) async {
          await completer.future;

          return 4;
        }, init: () => 3);

        final emissions = [];

        numberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        completer.complete();

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4]));
      });

      test(
          'watched async automatic Cog with a TTL re-evaluates and '
          'emits on a fixed interval', () {
        fakeAsync((async) {
          final numberCog = Cog(
            (c) async {
              await Future.delayed(1.seconds);

              return c.curr < 4 ? c.curr + 1 : c.curr;
            },
            init: () => 0,
            ttl: 5.seconds,
          );

          expect(numberCog.read(cogtext), 0);

          final emissions = [];

          numberCog.watch(cogtext).listen(emissions.add);

          async.elapse(1.seconds);

          expect(emissions, equals([1]));

          async.elapse(5.seconds);

          expect(emissions, equals([1]));

          async.elapse(1.seconds);

          expect(emissions, equals([1, 2]));

          async.elapse(5.seconds);

          expect(emissions, equals([1, 2]));

          async.elapse(1.seconds);

          expect(emissions, equals([1, 2, 3]));

          async.elapse(5.seconds);

          expect(emissions, equals([1, 2, 3]));

          async.elapse(1.seconds);

          expect(emissions, equals([1, 2, 3, 4]));

          async.elapse(5.seconds);

          expect(emissions, equals([1, 2, 3, 4]));

          async.elapse(1.seconds);

          expect(emissions, equals([1, 2, 3, 4]));

          async.elapse(30.seconds);

          expect(emissions, equals([1, 2, 3, 4]));
        });
      });

      test(
          'watched async automatic Cog with queued scheduling and a TTL '
          're-evaluates and emits on a fixed interval', () {
        fakeAsync((async) {
          final durationCog = Cog.man(() => 0, debugLabel: 'durationCog');

          var times = 0;

          final waitingCog = Cog(
            (c) async {
              final duration = c.link(durationCog);

              await Future.delayed(duration.seconds);

              return 'waited $duration seconds ${times++} times';
            },
            async: Async.queued,
            debugLabel: 'waitingCog',
            init: () => '',
            ttl: 5.seconds,
          );

          expect(waitingCog.read(cogtext), '');

          final emissions = [];

          waitingCog.watch(cogtext).listen(emissions.add);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0 seconds 0 times']));

          durationCog.write(cogtext, 8);

          async.elapse(5.seconds);

          expect(emissions, equals(['waited 0 seconds 0 times']));

          async.elapse(3.seconds);

          expect(
            emissions,
            equals([
              'waited 0 seconds 0 times',
              'waited 8 seconds 1 times',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0 seconds 0 times',
              'waited 8 seconds 1 times',
              'waited 8 seconds 2 times',
              'waited 8 seconds 3 times',
              'waited 8 seconds 4 times',
              'waited 8 seconds 5 times'
            ]),
          );
        });
      });

      test(
          'watched automatic Cog that links to a non-Cog correctly '
          'subscribes to changes in the non-Cog\'s value', () async {
        final numberFakeObservable = FakeObservable(1, isSync: true);

        final numberPlusOneCog = Cog((c) {
          final number = c.linkNonCog(
            numberFakeObservable,
            init: (nonCog) => nonCog.value,
            subscribe: (nonCog, onNextValue) =>
                nonCog.stream.listen(onNextValue),
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );

          return number + 1;
        });

        final emissions = [];

        numberPlusOneCog.watch(cogtext).listen(emissions.add);

        expect(numberFakeObservable.hasListeners, isTrue);

        numberFakeObservable.value = 2;

        await Future.delayed(Duration.zero);

        expect(emissions, equals([3]));
        expect(numberFakeObservable.hasListeners, isTrue);

        numberFakeObservable.value = 3;

        await Future.delayed(Duration.zero);

        expect(emissions, equals([3, 4]));
        expect(numberFakeObservable.hasListeners, isTrue);
      });

      test(
          'watched automatic Cog that links to a non-Cog more than once '
          'correctly subscribes to changes in the non-Cog\'s value', () async {
        final numberFakeObservable = FakeObservable(1, isSync: true);

        var invocationCount = 0;

        final numberPlusOneCog = Cog((c) {
          final number = c.linkNonCog(
            numberFakeObservable,
            init: (nonCog) => nonCog.value,
            subscribe: (nonCog, onNextValue) =>
                nonCog.stream.listen(onNextValue),
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );
          final sameNumber = c.linkNonCog(
            numberFakeObservable,
            init: (nonCog) => nonCog.value,
            subscribe: (nonCog, onNextValue) =>
                nonCog.stream.listen(onNextValue),
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );
          final hereWeGoAgain = c.linkNonCog(
            numberFakeObservable,
            init: (nonCog) => nonCog.value,
            subscribe: (nonCog, onNextValue) =>
                nonCog.stream.listen(onNextValue),
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );

          invocationCount++;

          return number + sameNumber + hereWeGoAgain + 1;
        });

        final emissions = [];

        numberPlusOneCog.watch(cogtext).listen(emissions.add);

        expect(numberFakeObservable.hasListeners, isTrue);

        numberFakeObservable.value = 2;

        await Future.delayed(Duration.zero);

        expect(emissions, equals([7]));
        expect(invocationCount, 2);
        expect(numberFakeObservable.hasListeners, isTrue);

        numberFakeObservable.value = 3;

        await Future.delayed(Duration.zero);

        expect(emissions, equals([7, 10]));
        expect(invocationCount, 3);
        expect(numberFakeObservable.hasListeners, isTrue);
      });

      test(
          'watched automatic Cog that unlinks from a non-Cog correctly '
          'unsubscribes from changes in the non-Cog\'s value', () async {
        final isPositiveFakeObservable = FakeObservable(true,
            debugLabel: 'isPositiveFakeObservable', isSync: true);
        final negativeFakeObservable = FakeObservable(-1,
            debugLabel: 'negativeFakeObservable', isSync: true);
        final positiveFakeObservable = FakeObservable(1,
            debugLabel: 'positiveFakeObservable', isSync: true);

        final alternatingNumberCog = Cog((c) {
          final isPositive = c.linkNonCog(
            isPositiveFakeObservable,
            init: (nonCog) => nonCog.value,
            subscribe: (nonCog, onNextValue) =>
                nonCog.stream.listen(onNextValue),
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );

          final value = c.linkNonCog(
            isPositive ? positiveFakeObservable : negativeFakeObservable,
            init: (nonCog) => nonCog.value,
            subscribe: (nonCog, onNextValue) =>
                nonCog.stream.listen(onNextValue),
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );

          return 'value is $value';
        }, debugLabel: 'alternatingNumberCog');

        final emissions = [];

        alternatingNumberCog.watch(cogtext).listen(emissions.add);

        expect(isPositiveFakeObservable.hasListeners, isTrue);
        expect(negativeFakeObservable.hasListeners, isFalse);
        expect(positiveFakeObservable.hasListeners, isTrue);

        isPositiveFakeObservable.value = false;

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['value is -1']));
        expect(isPositiveFakeObservable.hasListeners, isTrue);
        expect(negativeFakeObservable.hasListeners, isTrue);
        expect(positiveFakeObservable.hasListeners, isFalse);

        negativeFakeObservable.value = -2;

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['value is -1', 'value is -2']));
        expect(isPositiveFakeObservable.hasListeners, isTrue);
        expect(negativeFakeObservable.hasListeners, isTrue);
        expect(positiveFakeObservable.hasListeners, isFalse);

        isPositiveFakeObservable.value = true;

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['value is -1', 'value is -2', 'value is 1']));
        expect(isPositiveFakeObservable.hasListeners, isTrue);
        expect(negativeFakeObservable.hasListeners, isFalse);
        expect(positiveFakeObservable.hasListeners, isTrue);

        negativeFakeObservable.value = -3;

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['value is -1', 'value is -2', 'value is 1']));
        expect(isPositiveFakeObservable.hasListeners, isTrue);
        expect(negativeFakeObservable.hasListeners, isFalse);
        expect(positiveFakeObservable.hasListeners, isTrue);

        positiveFakeObservable.value = 2;

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            'value is -1',
            'value is -2',
            'value is 1',
            'value is 2',
          ]),
        );
        expect(isPositiveFakeObservable.hasListeners, isTrue);
        expect(negativeFakeObservable.hasListeners, isFalse);
        expect(positiveFakeObservable.hasListeners, isTrue);
      });
    });

    group('Simple reading and writing', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('writing to a spun manual Cog without specifying spin throws', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(() => numberCog.write(cogtext, 5), throwsArgumentError);
      });

      test('writing to an unspun manual Cog and specifying spin throws', () {
        final numberCog = Cog.man(() => 4);

        expect(
          () => numberCog.write(cogtext, 5, spin: false),
          throwsArgumentError,
        );
      });

      test('writing to a spun manual Cog changes its value', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(numberCog.read(cogtext, spin: false), equals(4));
        expect(numberCog.read(cogtext, spin: true), equals(4));

        numberCog.write(cogtext, 5, spin: false);

        expect(numberCog.read(cogtext, spin: false), equals(5));
        expect(numberCog.read(cogtext, spin: true), equals(4));

        numberCog.write(cogtext, 6, spin: true);

        expect(numberCog.read(cogtext, spin: false), equals(5));
        expect(numberCog.read(cogtext, spin: true), equals(6));
      });

      test('writing to an unspun manual Cog changes its value', () {
        final numberCog = Cog.man(() => 4);

        expect(numberCog.read(cogtext), equals(4));

        numberCog.write(cogtext, 5);

        expect(numberCog.read(cogtext), equals(5));

        numberCog.write(cogtext, 6);

        expect(numberCog.read(cogtext), equals(6));
      });

      test(
          'writing to a manual Cog with a dependent automatic spun Cog '
          'changes the automatic Cog\'s value', () {
        final numberCog = Cog.man(() => 4);

        final smallerNumberCog = Cog(
          (c) => c.link(numberCog) - (c.spin ? 1 : 2),
          spin: Spin<bool>(),
        );

        expect(smallerNumberCog.read(cogtext, spin: false), equals(2));
        expect(smallerNumberCog.read(cogtext, spin: true), equals(3));

        numberCog.write(cogtext, 5);

        expect(smallerNumberCog.read(cogtext, spin: false), equals(3));
        expect(smallerNumberCog.read(cogtext, spin: true), equals(4));

        numberCog.write(cogtext, 6);

        expect(smallerNumberCog.read(cogtext, spin: false), equals(4));
        expect(smallerNumberCog.read(cogtext, spin: true), equals(5));
      });

      test(
          'writing to a manual Cog with a dependent automatic unspun Cog '
          'changes the automatic Cog\'s value', () {
        final numberCog = Cog.man(() => 4);

        final smallerNumberCog = Cog((c) => c.link(numberCog) - 1);

        expect(smallerNumberCog.read(cogtext), equals(3));

        numberCog.write(cogtext, 5);

        expect(smallerNumberCog.read(cogtext), equals(4));

        numberCog.write(cogtext, 6);

        expect(smallerNumberCog.read(cogtext), equals(5));
      });
    });

    group('Simple watching and writing', () {
      setUp(() {
        cogtext = Cogtext(
          cogStateRuntime: StandardCogStateRuntime(
            logging: logging,
            scheduler: NaiveCogStateRuntimeScheduler(
              logging: logging,
              highPriorityBackgroundTaskDelay: Duration.zero,
              lowPriorityBackgroundTaskDelay: Duration.zero,
            ),
          ),
        );
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('writing to a watched, spun manual Cog triggers a notification',
          () async {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        final emissions = [];
        final subscription =
            numberCog.watch(cogtext, spin: false).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test('writing to a watched, unspun manual Cog triggers a notification',
          () async {
        final numberCog = Cog.man(() => 4);

        final emissions = [];
        final subscription = numberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test(
          'watched manual Cog with a custom eq only emits '
          'when the custom eq allows', () async {
        final numberCog = Cog.man(
          () => 4,
          eq: (a, b) => b - a <= 5,
        );

        final emissions = [];

        numberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 8);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 20);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([20]));

        numberCog.write(cogtext, 30);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([20, 30]));
      });

      test(
          'writing to a manual Cog depended on by a watched, spun '
          'automatic Cog triggers a notification', () async {
        final numberCog =
            Cog.man(() => 4, debugLabel: 'numberCog', spin: Spin<bool>());

        final squaredNumberCog = Cog((c) {
          final number = c.link(numberCog, spin: c.spin);

          return number * number;
        }, debugLabel: 'squaredNumberCog', spin: Spin<bool>());

        final emissions = [];
        final subscription =
            squaredNumberCog.watch(cogtext, spin: false).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([25]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([25]));
      });

      test(
          'writing to a manual Cog depended on by a watched, unspun '
          'automatic Cog triggers a notification', () async {
        final numberCog =
            Cog.man(() => 4, debugLabel: 'numberCog', spin: Spin<bool>());

        final squaredNumberCog = Cog((c) {
          final number = c.link(numberCog, spin: false);

          return number * number;
        }, debugLabel: 'squaredNumberCog');

        final emissions = [];
        final subscription =
            squaredNumberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([25]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([25]));
      });

      test(
          'writing to a watched manual Cog with asap priority '
          'triggers a notification synchronously', () async {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        final emissions = [];
        final subscription = numberCog
            .watch(
              cogtext,
              priority: Priority.asap,
              spin: false,
            )
            .listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(emissions, equals([5]));

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test(
          'writing to multiple unrelated watched, spun manual Cogs triggers '
          'the right notifications in the right order', () async {
        final boolCog =
            Cog.man(() => true, debugLabel: 'boolCog', spin: Spin<bool>());
        final numberCog =
            Cog.man(() => 4, debugLabel: 'numberCog', spin: Spin<bool>());
        final textCog =
            Cog.man(() => 'hello', debugLabel: 'textCog', spin: Spin<bool>());

        final emissions = [];
        final subscriptions = [
          boolCog
              .watch(
                cogtext,
                priority: Priority.low,
                spin: false,
              )
              .listen(emissions.add),
          numberCog
              .watch(
                cogtext,
                priority: Priority.normal,
                spin: false,
              )
              .listen(emissions.add),
          numberCog
              .watch(
                cogtext,
                priority: Priority.normal,
                spin: true,
              )
              .listen(emissions.add),
          textCog
              .watch(
                cogtext,
                priority: Priority.high,
                spin: false,
              )
              .listen(emissions.add),
        ];

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        boolCog.write(cogtext, false, spin: false);
        boolCog.write(cogtext, true, spin: false);
        numberCog.write(cogtext, 5, spin: false);
        numberCog.write(cogtext, 6, spin: false);
        numberCog.write(cogtext, 66, spin: true);
        numberCog.write(cogtext, 7, spin: false);
        numberCog.write(cogtext, 7, spin: false);
        numberCog.write(cogtext, 77, spin: true);
        numberCog.write(cogtext, 77, spin: true);
        textCog.write(cogtext, 'world', spin: false);
        textCog.write(cogtext, 'mars', spin: false);
        textCog.write(cogtext, 'jupiter', spin: false);
        textCog.write(cogtext, 'saturn', spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['saturn', 77, 7, true]));

        numberCog.write(cogtext, 8, spin: false);
        numberCog.write(cogtext, 8, spin: false);
        numberCog.write(cogtext, 8, spin: false);
        textCog.write(cogtext, 'saturn', spin: false);
        textCog.write(cogtext, 'neptune', spin: false);
        boolCog.write(cogtext, false, spin: false);

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['saturn', 77, 7, true, 'neptune', 8, false]));

        for (final subscription in subscriptions) {
          subscription.cancel();
        }

        numberCog.write(cogtext, 9, spin: false);

        expect(emissions, equals(['saturn', 77, 7, true, 'neptune', 8, false]));

        await Future.delayed(Duration.zero);
      });

      test(
          'writing to multiple unrelated watched, unspun manual Cogs triggers '
          'the right notifications in the right order', () async {
        final boolCog = Cog.man(() => true, debugLabel: 'boolCog');
        final numberCog = Cog.man(() => 4, debugLabel: 'numberCog');
        final textCog = Cog.man(() => 'hello', debugLabel: 'textCog');

        final emissions = [];
        final subscriptions = [
          boolCog
              .watch(
                cogtext,
                priority: Priority.low,
              )
              .listen(emissions.add),
          numberCog
              .watch(
                cogtext,
                priority: Priority.normal,
              )
              .listen(emissions.add),
          textCog
              .watch(
                cogtext,
                priority: Priority.high,
              )
              .listen(emissions.add),
        ];

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        boolCog.write(cogtext, false);
        boolCog.write(cogtext, true);
        numberCog.write(cogtext, 5);
        numberCog.write(cogtext, 6);
        numberCog.write(cogtext, 66);
        numberCog.write(cogtext, 7);
        numberCog.write(cogtext, 7);
        numberCog.write(cogtext, 77);
        numberCog.write(cogtext, 77);
        textCog.write(cogtext, 'world');
        textCog.write(cogtext, 'mars');
        textCog.write(cogtext, 'jupiter');
        textCog.write(cogtext, 'saturn');

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['saturn', 77, true]));

        numberCog.write(cogtext, 8);
        numberCog.write(cogtext, 8);
        numberCog.write(cogtext, 8);
        textCog.write(cogtext, 'saturn');
        textCog.write(cogtext, 'neptune');
        boolCog.write(cogtext, false);

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['saturn', 77, true, 'neptune', 8, false]));

        for (final subscription in subscriptions) {
          subscription.cancel();
        }

        numberCog.write(cogtext, 9);

        expect(emissions, equals(['saturn', 77, true, 'neptune', 8, false]));
      });

      test(
          'writing to multiple unrelated watched, spun automatic Cogs '
          'triggers the right notifications in the right order', () async {
        final aCog = Cog.man(() => 1, debugLabel: 'aCog', spin: Spin<bool>());
        final bCog = Cog.man(() => 2, debugLabel: 'bCog', spin: Spin<bool>());
        final cCog = Cog.man(() => 3, debugLabel: 'cCog', spin: Spin<bool>());

        final negativeBCog = Cog((c) {
          final b = c.link(bCog, spin: c.spin);

          return -b;
        }, debugLabel: 'negativeBCog', spin: Spin<bool>());
        final twoACog = Cog((c) {
          final a = c.link(aCog, spin: c.spin);

          return 2 * a;
        }, debugLabel: 'twoACog', spin: Spin<bool>());

        final discriminantCog = Cog((c) {
          final a = c.link(aCog, spin: c.spin);
          final b = c.link(bCog, spin: c.spin);
          final cVal = c.link(cCog, spin: c.spin);

          return b * b - 4 * a * cVal;
        }, debugLabel: 'discriminantCog', spin: Spin<bool>());

        final sqrtDiscriminantCog = Cog(
          (c) {
            final discriminant = c.link(discriminantCog, spin: c.spin);

            return sqrt(discriminant);
          },
          debugLabel: 'sqrtDiscriminantCog',
          spin: Spin<bool>(),
        );

        final answerCog = Cog(
          (c) {
            final negativeB = c.link(negativeBCog, spin: c.spin);
            final sqrtDiscriminant = c.link(sqrtDiscriminantCog, spin: c.spin);
            final twoA = c.link(twoACog, spin: c.spin);

            return (
              (negativeB + sqrtDiscriminant) / twoA,
              (negativeB - sqrtDiscriminant) / twoA
            );
          },
          debugLabel: 'sqrtDiscriminantCog',
          spin: Spin<bool>(),
        );

        final emissions = [];
        final subscriptions = [
          answerCog
              .watch(
                cogtext,
                priority: Priority.low,
                spin: false,
              )
              .listen(emissions.add),
          discriminantCog
              .watch(
                cogtext,
                priority: Priority.high,
                spin: false,
              )
              .listen(emissions.add),
        ];

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        aCog.write(cogtext, 6, spin: false);
        bCog.write(cogtext, 11, spin: false);
        cCog.write(cogtext, -35, spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([961, (5.0 / 3.0, -3.5)]));

        cCog.write(cogtext, 0, spin: false);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              961,
              (5.0 / 3.0, -3.5),
              121,
              (0.0, -11 / 6),
            ]));

        aCog.write(cogtext, -4, spin: false);
        bCog.write(cogtext, 7, spin: false);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              961,
              (5.0 / 3.0, -3.5),
              121,
              (0.0, -11 / 6),
              49,
              (0.0, 1.75),
            ]));

        aCog.write(cogtext, -4, spin: true);
        bCog.write(cogtext, 7, spin: true);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            961,
            (5.0 / 3.0, -3.5),
            121,
            (0.0, -11 / 6),
            49,
            (0.0, 1.75),
          ]),
        );

        for (final subscription in subscriptions) {
          subscription.cancel();
        }

        aCog.write(cogtext, 11, spin: false);

        expect(
          emissions,
          equals([
            961,
            (5.0 / 3.0, -3.5),
            121,
            (0.0, -11 / 6),
            49,
            (0.0, 1.75),
          ]),
        );
      });

      test(
          'writing to multiple unrelated watched, unspun automatic Cogs '
          'triggers the right notifications in the right order', () async {
        final aCog = Cog.man(() => 1, debugLabel: 'aCog');
        final bCog = Cog.man(() => 2, debugLabel: 'bCog');
        final cCog = Cog.man(() => 3, debugLabel: 'cCog');

        final negativeBCog = Cog((c) {
          final b = c.link(bCog);

          return -b;
        }, debugLabel: 'negativeBCog');
        final twoACog = Cog((c) {
          final a = c.link(aCog);

          return 2 * a;
        }, debugLabel: 'twoACog');

        final discriminantCog = Cog((c) {
          final a = c.link(aCog);
          final b = c.link(bCog);
          final cVal = c.link(cCog);

          return b * b - 4 * a * cVal;
        }, debugLabel: 'discriminantCog');

        final sqrtDiscriminantCog = Cog(
          (c) {
            final discriminant = c.link(discriminantCog);

            return sqrt(discriminant);
          },
          debugLabel: 'sqrtDiscriminantCog',
        );

        final answerCog = Cog(
          (c) {
            final negativeB = c.link(negativeBCog);
            final sqrtDiscriminant = c.link(sqrtDiscriminantCog);
            final twoA = c.link(twoACog);

            return (
              (negativeB + sqrtDiscriminant) / twoA,
              (negativeB - sqrtDiscriminant) / twoA
            );
          },
          debugLabel: 'sqrtDiscriminantCog',
        );

        final emissions = [];
        final subscriptions = [
          answerCog
              .watch(
                cogtext,
                priority: Priority.low,
              )
              .listen(emissions.add),
          discriminantCog
              .watch(
                cogtext,
                priority: Priority.high,
              )
              .listen(emissions.add),
        ];

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        aCog.write(cogtext, 6);
        bCog.write(cogtext, 11);
        cCog.write(cogtext, -35);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([961, (5.0 / 3.0, -3.5)]));

        cCog.write(cogtext, 0);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              961,
              (5.0 / 3.0, -3.5),
              121,
              (0.0, -11 / 6),
            ]));

        aCog.write(cogtext, -4);
        bCog.write(cogtext, 7);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              961,
              (5.0 / 3.0, -3.5),
              121,
              (0.0, -11 / 6),
              49,
              (0.0, 1.75),
            ]));

        for (final subscription in subscriptions) {
          subscription.cancel();
        }

        aCog.write(cogtext, 11);

        expect(
          emissions,
          equals([
            961,
            (5.0 / 3.0, -3.5),
            121,
            (0.0, -11 / 6),
            49,
            (0.0, 1.75),
          ]),
        );
      });

      test(
          'writing to a watched manual Cogs triggers notifications in '
          'the correct order, even after priority is changed', () async {
        final boolCog = Cog.man(() => false);
        final numberCog = Cog.man(() => 4);
        final stringCog = Cog.man(() => '');

        final emissions = [];

        boolCog.watch(cogtext, priority: Priority.high).listen(emissions.add);
        numberCog
            .watch(cogtext, priority: Priority.normal)
            .listen(emissions.add);
        stringCog.watch(cogtext, priority: Priority.low).listen(emissions.add);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        boolCog.write(cogtext, true);
        numberCog.write(cogtext, 5);
        stringCog.write(cogtext, '123');

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            true,
            5,
            '123',
          ]),
        );

        stringCog.watch(cogtext, priority: Priority.high);

        boolCog.write(cogtext, false);
        numberCog.write(cogtext, 6);
        stringCog.write(cogtext, '456');

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            true,
            5,
            '123',
            '456',
            false,
            6,
          ]),
        );
      });

      test('automatic Cogs can mimick a "flatMap"-like behavior', () async {
        final numberedCogs = [
          for (var i = 1; i <= 20; i++)
            Cog.man(() => i, debugLabel: 'numberedCog$i'),
        ];

        final numberedListLengthCog =
            Cog.man(() => 5, debugLabel: 'numberedListLengthCog');
        final numberedListOffsetCog =
            Cog.man(() => 0, debugLabel: 'numberedListOffsetCog');

        final numberedListCog = Cog((c) {
          final numberedListLength = c.link(numberedListLengthCog);
          final numberedListOffset = c.link(numberedListOffsetCog);

          return [
            for (var i = numberedListOffset;
                i < numberedListOffset + numberedListLength;
                i++)
              c.link(numberedCogs[i]),
          ];
        }, debugLabel: 'numberedListCog');

        final emissions = [];

        numberedListCog.watch(cogtext).listen(emissions.add);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberedCogs[1].write(cogtext, -2);
        numberedCogs[3].write(cogtext, -4);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
          ]),
        );

        numberedCogs[11].write(cogtext, -12);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
          ]),
        );

        numberedListOffsetCog.write(cogtext, 4);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
            [5, 6, 7, 8, 9],
          ]),
        );

        numberedListLengthCog.write(cogtext, 10);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
            [5, 6, 7, 8, 9],
            [5, 6, 7, 8, 9, 10, 11, -12, 13, 14],
          ]),
        );

        numberedCogs[2].write(cogtext, -3);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
            [5, 6, 7, 8, 9],
            [5, 6, 7, 8, 9, 10, 11, -12, 13, 14],
          ]),
        );

        numberedListOffsetCog.write(cogtext, 17);
        numberedListLengthCog.write(cogtext, 1);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
            [5, 6, 7, 8, 9],
            [5, 6, 7, 8, 9, 10, 11, -12, 13, 14],
            [18],
          ]),
        );
      });

      test('automatic Cogs can drop dependencies over time', () async {
        final numberCog = Cog.man(() => 1);

        final aCog = Cog((c) => 'a${c.link(numberCog)}');
        final bCog = Cog((c) => 'b${c.link(numberCog)}');
        final cCog = Cog((c) => 'c${c.link(numberCog)}');

        final subscriptionCountCog = Cog.man(() => 3);

        final subscribingCog = Cog((c) {
          final subscriptionCount = c.link(subscriptionCountCog);

          return [
            if (subscriptionCount > 0) c.link(aCog),
            if (subscriptionCount > 1) c.link(bCog),
            if (subscriptionCount > 2) c.link(cCog),
          ].join(', ');
        });

        final emissions = [];

        subscribingCog.watch(cogtext).listen(emissions.add);

        numberCog.write(cogtext, 2);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            'a2, b2, c2',
          ]),
        );

        subscriptionCountCog.write(cogtext, 1);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            'a2, b2, c2',
            'a2',
          ]),
        );

        numberCog.write(cogtext, 17);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            'a2, b2, c2',
            'a2',
            'a17',
          ]),
        );

        subscriptionCountCog.write(cogtext, 0);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            'a2, b2, c2',
            'a2',
            'a17',
            '',
          ]),
        );
      });

      test('automatic Cogs can mimick a "switchMap"-like behavior', () async {
        final evenCog = Cog.man(() => 2);
        final oddCog = Cog.man(() => 3);
        final isEvenCog = Cog.man(() => true);

        final numberCog = Cog((c) {
          final isEven = c.link(isEvenCog);

          final number = isEven ? c.link(evenCog) : c.link(oddCog);

          return number;
        });

        final emissions = [];

        numberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        evenCog.write(cogtext, 4);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4]));

        isEvenCog.write(cogtext, false);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4, 3]));

        await Future.delayed(Duration.zero);

        oddCog.write(cogtext, 5);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4, 3, 5]));

        evenCog.write(cogtext, 6);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4, 3, 5]));
      });

      test(
          'watched async automatic Cogs with latest only scheduling emit '
          'correctly when their dependencies change', () {
        fakeAsync((async) {
          final durationCog = Cog.man(() => 0, debugLabel: 'durationCog');

          final waitingCog = Cog(
            (c) async {
              final duration = c.link(durationCog);

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.latestOnly,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog.watch(cogtext).listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 8);

          async.elapse(7.seconds);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 1);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 1']));

          durationCog.write(cogtext, 2);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 1']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 1', 'waited 2']));

          durationCog.write(cogtext, 1);
          durationCog.write(cogtext, 5);
          durationCog.write(cogtext, 7);

          async.elapse(5.seconds);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 1',
              'waited 2',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 1',
              'waited 2',
              'waited 7',
            ]),
          );
        });
      });

      test(
          'watched async automatic Cogs with latest only scheduling and asap '
          'priority correctly when their dependencies change', () {
        fakeAsync((async) {
          final durationCog = Cog.man(() => 0, debugLabel: 'durationCog');

          final waitingCog = Cog(
            (c) async {
              final duration = c.link(durationCog);

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.latestOnly,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog
              .watch(cogtext, priority: Priority.asap)
              .listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 8);

          async.elapse(7.seconds);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 1);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 1']));

          durationCog.write(cogtext, 2);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 1']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 1', 'waited 2']));

          durationCog.write(cogtext, 1);
          durationCog.write(cogtext, 5);
          durationCog.write(cogtext, 7);

          async.elapse(5.seconds);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 1',
              'waited 2',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 1',
              'waited 2',
              'waited 7',
            ]),
          );
        });
      });

      test(
          'watched async automatic Cogs with latest only scheduling and a '
          'non-cog dependency emit correctly when their dependencies change',
          () {
        fakeAsync((async) {
          final durationFakeObservable = FakeObservable(
            0,
            debugLabel: 'durationFakeObservable',
          );

          final waitingCog = Cog(
            (c) async {
              final duration = c.linkNonCog(
                durationFakeObservable,
                init: (nonCog) => nonCog.value,
                subscribe: (nonCog, onNextValue) =>
                    nonCog.stream.listen(onNextValue),
                unsubscribe: (nonCog, onNextValue, subscription) =>
                    subscription.cancel(),
              );

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.latestOnly,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog
              .watch(cogtext, priority: Priority.asap)
              .listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationFakeObservable.value = 8;

          async.elapse(7.seconds);

          expect(emissions, equals(['waited 0']));

          durationFakeObservable.value = 1;

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 1']));

          durationFakeObservable.value = 2;

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 1']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 1', 'waited 2']));

          durationFakeObservable.value = 1;
          durationFakeObservable.value = 5;
          durationFakeObservable.value = 7;

          async.elapse(5.seconds);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 1',
              'waited 2',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 1',
              'waited 2',
              'waited 7',
            ]),
          );
        });
      });

      test(
          'watched async automatic Cogs with one-at-a-time scheduling '
          'emit correctly when their dependencies change', () {
        fakeAsync((async) {
          final durationCog = Cog.man(() => 0, debugLabel: 'durationCog');

          final waitingCog = Cog(
            (c) async {
              final duration = c.link(durationCog);

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.oneAtATime,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog.watch(cogtext).listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 8);

          async.elapse(7.seconds);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 1);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          durationCog.write(cogtext, 2);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8', 'waited 2']));

          durationCog.write(cogtext, 1);
          durationCog.write(cogtext, 5);
          durationCog.write(cogtext, 7);

          async.elapse(5.seconds);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
            ]),
          );
        });
      });

      test(
          'watched async automatic Cogs with one-at-a-time scheduling and asap '
          'priority emit correctly when their dependencies change', () {
        fakeAsync((async) {
          final durationCog = Cog.man(() => 0, debugLabel: 'durationCog');

          final waitingCog = Cog(
            (c) async {
              final duration = c.link(durationCog);

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.oneAtATime,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog
              .watch(cogtext, priority: Priority.asap)
              .listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 8);

          async.elapse(7.seconds);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 1);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          durationCog.write(cogtext, 2);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8', 'waited 2']));

          durationCog.write(cogtext, 1);
          durationCog.write(cogtext, 5);
          durationCog.write(cogtext, 7);

          async.elapse(5.seconds);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
            ]),
          );
        });
      });

      test(
          'watched async automatic Cogs with one-at-a-time scheduling and a '
          'non-cog dependency emit correctly when their dependencies change',
          () {
        fakeAsync((async) {
          final durationFakeObservable = FakeObservable(
            0,
            debugLabel: 'durationFakeObservable',
          );

          final waitingCog = Cog(
            (c) async {
              final duration = c.linkNonCog(
                durationFakeObservable,
                init: (nonCog) => nonCog.value,
                subscribe: (nonCog, onNextValue) =>
                    nonCog.stream.listen(onNextValue),
                unsubscribe: (nonCog, onNextValue, subscription) =>
                    subscription.cancel(),
              );

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.oneAtATime,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog
              .watch(cogtext, priority: Priority.asap)
              .listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationFakeObservable.value = 8;

          async.elapse(7.seconds);

          expect(emissions, equals(['waited 0']));

          durationFakeObservable.value = 1;

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          durationFakeObservable.value = 2;

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8', 'waited 2']));

          durationFakeObservable.value = 1;
          durationFakeObservable.value = 5;
          durationFakeObservable.value = 7;

          async.elapse(5.seconds);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
            ]),
          );
        });
      });

      test(
          'watched async automatic Cogs with parallel scheduling '
          'emit correctly when their dependencies change', () {
        fakeAsync((async) {
          final durationCog = Cog.man(() => 0, debugLabel: 'durationCog');

          final waitingCog = Cog(
            (c) async {
              final duration = c.link(durationCog);

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.parallel,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog.watch(cogtext).listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 8);

          async.elapse(7.seconds);

          expect(emissions, equals(['waited 0']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          durationCog.write(cogtext, 2);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8', 'waited 2']));

          durationCog.write(cogtext, 1);
          durationCog.write(cogtext, 5);
          durationCog.write(cogtext, 7);

          async.elapse(5.seconds);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
              'waited 5',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
              'waited 5',
              'waited 7',
            ]),
          );
        });
      });

      test(
          'watched async automatic Cogs with parallel scheduling and asap '
          'priority emit correctly when their dependencies change', () {
        fakeAsync((async) {
          final durationCog = Cog.man(() => 0, debugLabel: 'durationCog');

          final waitingCog = Cog(
            (c) async {
              final duration = c.link(durationCog);

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.parallel,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog
              .watch(cogtext, priority: Priority.asap)
              .listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 8);

          async.elapse(7.seconds);

          expect(emissions, equals(['waited 0']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          durationCog.write(cogtext, 2);

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8', 'waited 2']));

          durationCog.write(cogtext, 1);
          durationCog.write(cogtext, 5);
          durationCog.write(cogtext, 7);

          async.elapse(5.seconds);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
              'waited 5',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
              'waited 5',
              'waited 7',
            ]),
          );
        });
      });

      test(
          'watched async automatic Cogs with parallel scheduling and a '
          'non-cog dependency emit correctly when their dependencies change',
          () {
        fakeAsync((async) {
          final durationFakeObservable = FakeObservable(
            0,
            debugLabel: 'durationFakeObservable',
          );

          final waitingCog = Cog(
            (c) async {
              final duration = c.linkNonCog(
                durationFakeObservable,
                init: (nonCog) => nonCog.value,
                subscribe: (nonCog, onNextValue) =>
                    nonCog.stream.listen(onNextValue),
                unsubscribe: (nonCog, onNextValue, subscription) =>
                    subscription.cancel(),
              );

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.parallel,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog
              .watch(cogtext, priority: Priority.asap)
              .listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationFakeObservable.value = 8;

          async.elapse(7.seconds);

          expect(emissions, equals(['waited 0']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          durationFakeObservable.value = 2;

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(1.seconds);

          expect(emissions, equals(['waited 0', 'waited 8', 'waited 2']));

          durationFakeObservable.value = 1;
          durationFakeObservable.value = 5;
          durationFakeObservable.value = 7;

          async.elapse(5.seconds);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
              'waited 5',
            ]),
          );

          async.elapse(1.minutes);

          expect(
            emissions,
            equals([
              'waited 0',
              'waited 8',
              'waited 2',
              'waited 1',
              'waited 5',
              'waited 7',
            ]),
          );
        });
      });

      test(
          'watched async automatic Cogs with queued scheduling '
          'emit correctly when their dependencies change', () {
        fakeAsync((async) {
          final durationCog = Cog.man(() => 0, debugLabel: 'durationCog');

          final waitingCog = Cog(
            (c) async {
              final duration = c.link(durationCog);

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.queued,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog.watch(cogtext).listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 8);

          async.elapse(4.seconds);

          durationCog.write(cogtext, 2);
          durationCog.write(cogtext, 4);

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0']));

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0', 'waited 8', 'waited 4']));
        });
      });

      test(
          'watched async automatic Cogs with queued scheduling and asap'
          'priority emit correctly when their dependencies change', () {
        fakeAsync((async) {
          final durationCog = Cog.man(() => 0, debugLabel: 'durationCog');

          final waitingCog = Cog(
            (c) async {
              final duration = c.link(durationCog);

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.queued,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog
              .watch(cogtext, priority: Priority.asap)
              .listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationCog.write(cogtext, 8);

          async.elapse(4.seconds);

          durationCog.write(cogtext, 2);
          durationCog.write(cogtext, 4);

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0']));

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0', 'waited 8', 'waited 4']));
        });
      });

      test(
          'watched async automatic Cogs with queued scheduling and a '
          'non-cog dependency emit correctly when their dependencies change',
          () {
        fakeAsync((async) {
          final durationFakeObservable = FakeObservable(
            0,
            debugLabel: 'durationFakeObservable',
          );

          final waitingCog = Cog(
            (c) async {
              final duration = c.linkNonCog(
                durationFakeObservable,
                init: (nonCog) => nonCog.value,
                subscribe: (nonCog, onNextValue) =>
                    nonCog.stream.listen(onNextValue),
                unsubscribe: (nonCog, onNextValue, subscription) =>
                    subscription.cancel(),
              );

              await Future.delayed(duration.seconds);

              return 'waited $duration';
            },
            async: Async.queued,
            debugLabel: 'waitingCog',
            init: () => '',
          );

          final emissions = [];

          waitingCog.watch(cogtext).listen(emissions.add);

          expect(emissions, isEmpty);

          async.elapse(Duration.zero);

          expect(emissions, equals(['waited 0']));

          durationFakeObservable.value = 8;

          async.elapse(4.seconds);

          durationFakeObservable.value = 2;
          durationFakeObservable.value = 4;

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0']));

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0', 'waited 8']));

          async.elapse(2.seconds);

          expect(emissions, equals(['waited 0', 'waited 8', 'waited 4']));
        });
      });

      test(
          'watched automatic Cog that links to both a Cog and non-Cog '
          'correctly subscribes to changes in both', () async {
        final numberFakeObservable = FakeObservable(17, isSync: true);
        final otherNumberCog = Cog.man(() => 4, debugLabel: 'otherNumberCog');

        final sumCog = Cog((c) {
          final number = c.linkNonCog(
            numberFakeObservable,
            init: (nonCog) => nonCog.value,
            subscribe: (nonCog, onNextValue) =>
                nonCog.stream.listen(onNextValue),
            unsubscribe: (nonCog, onNextValue, subscription) =>
                subscription.cancel(),
          );
          final otherNumber = c.link(otherNumberCog);

          return number + otherNumber;
        }, debugLabel: 'sumCog');

        final emissions = [];

        sumCog.watch(cogtext).listen(emissions.add);

        expect(numberFakeObservable.hasListeners, isTrue);

        numberFakeObservable.value = 18;

        await Future.delayed(Duration.zero);

        expect(emissions, equals([22]));
        expect(numberFakeObservable.hasListeners, isTrue);

        otherNumberCog.write(cogtext, 5);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([22, 23]));
        expect(numberFakeObservable.hasListeners, isTrue);

        otherNumberCog.write(cogtext, 6);
        numberFakeObservable.value = 17;

        await Future.delayed(Duration.zero);

        expect(emissions, equals([22, 23]));
        expect(numberFakeObservable.hasListeners, isTrue);

        otherNumberCog.write(cogtext, 6);
        otherNumberCog.write(cogtext, 7);
        otherNumberCog.write(cogtext, 8);
        otherNumberCog.write(cogtext, 9);
        otherNumberCog.write(cogtext, 10);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([22, 23, 27]));
        expect(numberFakeObservable.hasListeners, isTrue);
      });
    });

    group('Simple reading, watching and writing', () {
      setUp(() {
        cogtext = Cogtext(
          cogStateRuntime: StandardCogStateRuntime(
            logging: logging,
            scheduler: NaiveCogStateRuntimeScheduler(
              highPriorityBackgroundTaskDelay: Duration.zero,
              logging: logging,
              lowPriorityBackgroundTaskDelay: Duration.zero,
            ),
          ),
        );
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test(
          'reading from the end of a chain of watched automatic '
          'Cogs triggers notifications all the way up the chain', () async {
        final firstCog = Cog.man(() => 1, debugLabel: 'firstCog');

        final secondCog = Cog(
          (c) => 2 * c.link(firstCog),
          debugLabel: 'secondCog',
        );

        final thirdCog = Cog(
          (c) => 3 * c.link(secondCog),
          debugLabel: 'thirdCog',
        );

        final fourthCog = Cog(
          (c) => 5 * c.link(thirdCog),
          debugLabel: 'fourthCog',
        );

        final emissions = [];

        expect(emissions, isEmpty);

        firstCog.read(cogtext);
        secondCog.read(cogtext);
        thirdCog.read(cogtext);
        fourthCog.read(cogtext);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        firstCog.write(cogtext, 2);

        firstCog
            .watch(
              cogtext,
              priority: Priority.low,
            )
            .listen(emissions.add);
        secondCog
            .watch(
              cogtext,
              priority: Priority.high,
            )
            .listen(emissions.add);
        thirdCog
            .watch(
              cogtext,
              priority: Priority.normal,
            )
            .listen(emissions.add);
        fourthCog
            .watch(
              cogtext,
              priority: Priority.low,
            )
            .listen(emissions.add);

        fourthCog.read(cogtext);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, [4, 12, 60]);
      });

      test(
          'writing to a watched and spun manual Cog triggers a notification, '
          'even while intermittently reading', () async {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        final emissions = [];
        final subscription =
            numberCog.watch(cogtext, spin: false).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(numberCog.read(cogtext, spin: false), 5);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test(
          'writing to a watched and spun automatic Cog triggers a '
          'notification, even while intermittently reading', () async {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        final numberPlusOneCog = Cog(
          (c) => c.link(numberCog, spin: c.spin) + 1,
          spin: Spin<bool>(),
        );

        final emissions = [];
        final subscription =
            numberPlusOneCog.watch(cogtext, spin: false).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(numberPlusOneCog.read(cogtext, spin: false), 6);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([6]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([6]));
      });

      test(
          'writing to a watched and unspun manual Cog triggers a notification, '
          'even while intermittently reading', () async {
        final numberCog = Cog.man(() => 4);

        final emissions = [];
        final subscription = numberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5);

        expect(numberCog.read(cogtext), 5);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test(
          'writing to a watched and unspun automatic Cog triggers a '
          'notification, even while intermittently reading', () async {
        final numberCog = Cog.man(() => 4);

        final numberPlusOneCog = Cog(
          (c) => c.link(numberCog) + 1,
        );

        final emissions = [];
        final subscription =
            numberPlusOneCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5);

        expect(numberPlusOneCog.read(cogtext), 6);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([6]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([6]));
      });
    });

    group('Complex reading', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('you can read from a chain of unspun automatic Cogs', () {
        final isWindyCog = Cog((c) => false, debugLabel: 'isWindyCog');

        final temperatureCog = Cog((c) => 12.0, debugLabel: 'temperatureCog');

        final isNiceOutsideCog = Cog((c) {
          final isWindy = c.link(isWindyCog);
          final temperature = c.link(temperatureCog);

          return !isWindy && temperature > 22.0;
        }, debugLabel: 'isNiceOutsideCog');

        final dayOfTheWeekCog =
            Cog((c) => Day.sunday, debugLabel: 'dayOfTheWeekCog');

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog');

        final shouldGoToTheBeachCog = Cog((c) {
          final isNiceOutside = c.link(isNiceOutsideCog);
          final isWeekend = c.link(isWeekendCog);

          return isNiceOutside && isWeekend;
        }, debugLabel: 'shouldGoToTheBeachCog');

        expect(shouldGoToTheBeachCog.read(cogtext), isFalse);
      });

      test('you can read from a chain of spun automatic Cogs', () {
        final isWindyCog =
            Cog((c) => false, debugLabel: 'isWindyCog', spin: Spin<City>());

        final temperatureCog =
            Cog((c) => 12.0, debugLabel: 'temperatureCog', spin: Spin<City>());

        final isNiceOutsideCog = Cog(
          (c) {
            final isWindy = c.link(isWindyCog, spin: c.spin);
            final temperature = c.link(temperatureCog, spin: c.spin);

            return !isWindy && temperature > 22.0;
          },
          debugLabel: 'isNiceOutsideCog',
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog(
          (c) => Day.sunday,
          debugLabel: 'dayOfTheWeekCog',
          spin: Spin<City>(),
        );

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog, spin: c.spin);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog', spin: Spin<City>());

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog, spin: c.spin);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          spin: Spin<City>(),
        );

        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
        expect(
            shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn), isFalse);
        expect(
            shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge), isFalse);
      });

      test(
          'you can read from a chain of Cogs where some are manual, '
          'some are spun, and some are both', () {
        final isWindyCog =
            Cog.man(() => false, debugLabel: 'isWindyCog', spin: Spin<City>());

        final temperatureCog = Cog.man(
          () => 12.0,
          debugLabel: 'temperatureCog',
          spin: Spin<City>(),
        );

        final isNiceOutsideCog = Cog(
          (c) {
            final isWindy = c.link(isWindyCog, spin: c.spin);
            final temperature = c.link(temperatureCog, spin: c.spin);

            return !isWindy && temperature > 22.0;
          },
          debugLabel: 'isNiceOutsideCog',
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog((c) => Day.sunday,
            debugLabel: 'dayOfTheWeekCog', spin: Spin<City>());

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog, spin: c.spin);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog', spin: Spin<City>());

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog, spin: c.spin);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          spin: Spin<City>(),
        );

        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
        expect(
            shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn), isFalse);
        expect(
            shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge), isFalse);
      });
    });

    group('Complex reading and writing', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test(
          'you can read from and write to a chain of Cogs where some are '
          'manual, some are spun, and some are both', () {
        final isWindyCog =
            Cog.man(() => false, debugLabel: 'isWindyCog', spin: Spin<City>());

        final temperatureCog = Cog.man(
          () => 12.0,
          debugLabel: 'temperatureCog',
          spin: Spin<City>(),
        );

        final isNiceOutsideCog = Cog(
          (c) {
            final isWindy = c.link(isWindyCog, spin: c.spin);
            final temperature = c.link(temperatureCog, spin: c.spin);

            return !isWindy && temperature > 22.0;
          },
          debugLabel: 'isNiceOutsideCog',
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog.man(
          () => Day.wednesday,
          debugLabel: 'dayOfTheWeekCog',
          spin: Spin<City>(),
        );

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog, spin: c.spin);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog', spin: Spin<City>());

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog, spin: c.spin);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          spin: Spin<City>(),
        );

        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
        expect(
          shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn),
          isFalse,
        );
        expect(
          shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge),
          isFalse,
        );

        temperatureCog
          ..write(cogtext, 24.0, spin: City.austin)
          ..write(cogtext, 18.0, spin: City.brooklyn)
          ..write(cogtext, 12.0, spin: City.cambridge);

        expect(isNiceOutsideCog.read(cogtext, spin: City.austin), isTrue);
        expect(isNiceOutsideCog.read(cogtext, spin: City.brooklyn), isFalse);
        expect(isNiceOutsideCog.read(cogtext, spin: City.cambridge), isFalse);
        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
        expect(
          shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge),
          isFalse,
        );

        dayOfTheWeekCog.write(cogtext, Day.saturday, spin: City.austin);

        expect(isNiceOutsideCog.read(cogtext, spin: City.austin), isTrue);
        expect(isNiceOutsideCog.read(cogtext, spin: City.brooklyn), isFalse);
        expect(isNiceOutsideCog.read(cogtext, spin: City.cambridge), isFalse);
        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isTrue);
        expect(
          shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn),
          isFalse,
        );

        isWindyCog.write(cogtext, true, spin: City.austin);

        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
      });
    });

    group('Complex watching and writing', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test(
          'you can read from and write to a chain of Cogs where some are '
          'manual, some are spun, and some are both', () async {
        final isWindyCog =
            Cog.man(() => false, debugLabel: 'isWindyCog', spin: Spin<City>());

        final temperatureCog = Cog.man(
          () => 12.0,
          debugLabel: 'temperatureCog',
          spin: Spin<City>(),
        );

        final isNiceOutsideCog = Cog(
          (c) {
            final isWindy = c.link(isWindyCog, spin: c.spin);
            final temperature = c.link(temperatureCog, spin: c.spin);

            return !isWindy && temperature > 22.0;
          },
          debugLabel: 'isNiceOutsideCog',
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog.man(
          () => Day.wednesday,
          debugLabel: 'dayOfTheWeekCog',
        );

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog');

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          spin: Spin<City>(),
        );

        final emissions = [];
        final subscriptions = [
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.austin)
              .map((shouldGoToTheBeach) =>
                  'shouldGoToTheBeach austin $shouldGoToTheBeach')
              .listen(emissions.add),
          shouldGoToTheBeachCog
              .watch(
                cogtext,
                spin: City.brooklyn,
                priority: Priority.low,
              )
              .map((shouldGoToTheBeach) =>
                  'shouldGoToTheBeach brooklyn $shouldGoToTheBeach')
              .listen(emissions.add),
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.cambridge)
              .map((shouldGoToTheBeach) =>
                  'shouldGoToTheBeach cambridge $shouldGoToTheBeach')
              .listen(emissions.add),
          isNiceOutsideCog
              .watch(cogtext, spin: City.brooklyn)
              .map((isNiceOutside) => 'isNiceOutside brooklyn $isNiceOutside')
              .listen(emissions.add),
          isNiceOutsideCog
              .watch(
                cogtext,
                spin: City.austin,
                priority: Priority.high,
              )
              .map((isNiceOutside) => 'isNiceOutside austin $isNiceOutside')
              .listen(emissions.add),
        ];

        temperatureCog
          ..write(cogtext, 24.0, spin: City.austin)
          ..write(cogtext, 18.0, spin: City.brooklyn)
          ..write(cogtext, 12.0, spin: City.cambridge);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            'isNiceOutside austin true',
            'isNiceOutside brooklyn false',
            'shouldGoToTheBeach brooklyn false',
            'shouldGoToTheBeach austin false',
          ]),
        );

        subscriptions.addAll([
          isWeekendCog
              .watch(cogtext, priority: Priority.asap)
              .map((isWeekend) => 'isWeekendCog $isWeekend')
              .listen(emissions.add),
          temperatureCog
              .watch(cogtext, spin: City.austin)
              .map((temperature) => 'temperature austin $temperature')
              .listen(emissions.add),
        ]);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            'isNiceOutside austin true',
            'isNiceOutside brooklyn false',
            'shouldGoToTheBeach brooklyn false',
            'shouldGoToTheBeach austin false',
          ]),
        );

        dayOfTheWeekCog.write(cogtext, Day.saturday);
        isWindyCog.write(cogtext, true, spin: City.austin);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              'isNiceOutside austin true',
              'isNiceOutside brooklyn false',
              'shouldGoToTheBeach brooklyn false',
              'shouldGoToTheBeach austin false',
              'isWeekendCog true',
              'isNiceOutside austin false',
              'shouldGoToTheBeach cambridge false',
            ]));
      });

      test(
          'you can watch from a deep chain of automatic Cogs where some are '
          'async and some are sync', () {
        fakeAsync((async) {
          final timeOfDayCog = Cog(
            (c) => DateTime(
              2024,
              2,
              26,
              7 + async.elapsed.inHours,
              async.elapsed.inMinutes,
            ),
            ttl: 1.hours + 30.minutes,
            debugLabel: 'timeOfDayCog',
          );

          final zipCodeCog = Cog(
            (c) => switch (c.spin) {
              City.austin => 78737,
              City.brooklyn => 11201,
              City.cambridge => 02138,
            },
            debugLabel: 'zipCodeCog',
            spin: Spin<City>(),
          );

          final weatherDataCog = Cog(
            (c) async {
              final timeOfDay = c.link(timeOfDayCog);
              final zipCode = c.link(zipCodeCog, spin: c.spin);

              final weatherData = await fetchWeatherData(
                timeOfDay: timeOfDay,
                zipCode: zipCode,
              );

              return weatherData;
            },
            async: Async.latestOnly,
            debugLabel: 'weatherDataCog',
            init: null.init<WeatherData>(),
            spin: Spin<City>(),
            ttl: 30.minutes,
          );

          final isSunnyCog = Cog(
            (c) {
              final weatherData = c.link(weatherDataCog, spin: c.spin);

              if (weatherData == null) {
                return false;
              }

              return weatherData.cloudCoverPercentage < .3;
            },
            debugLabel: 'isSunnyCog',
            spin: Spin<City>(),
          );

          final willRainLaterCog = Cog(
            (c) {
              final weatherData = c.link(weatherDataCog, spin: c.spin);

              if (weatherData == null) {
                return false;
              }

              return weatherData.percentChanceOfRain > .5;
            },
            debugLabel: 'willRainLaterCog',
            spin: Spin<City>(),
          );

          final tempInFahrenheitCog = Cog(
            (c) {
              final weatherData = c.link(weatherDataCog, spin: c.spin);

              if (weatherData == null) {
                return null;
              }

              return (weatherData.tempInCelsius * 9 / 5) + 32;
            },
            debugLabel: 'tempInFahrenheitCog',
            spin: Spin<City>(),
          );

          final isNiceOutsideCog = Cog(
            (c) {
              final isSunny = c.link(isSunnyCog, spin: c.spin);
              final tempInFahrenheit =
                  c.link(tempInFahrenheitCog, spin: c.spin);

              if (tempInFahrenheit == null) {
                return false;
              }

              return isSunny && tempInFahrenheit > 70.0;
            },
            debugLabel: 'isNiceOutsideCog',
            spin: Spin<City>(),
          );

          final shouldGoToTheBeachCog = Cog(
            (c) {
              final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
              final willRainLater = c.link(willRainLaterCog, spin: c.spin);

              return isNiceOutside && !willRainLater;
            },
            debugLabel: 'shouldGoToTheBeachCog',
            spin: Spin<City>(),
          );

          final emissions = [];

          isNiceOutsideCog
              .watch(cogtext, spin: City.austin)
              .listen((isNiceOutsideCog) {
            emissions.add(
              'isNiceOutsideCog in austin: $isNiceOutsideCog',
            );
          });
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.austin)
              .listen((shouldGoToTheBeachCog) {
            emissions.add(
              'shouldGoToTheBeachCog in austin: $shouldGoToTheBeachCog',
            );
          });
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.brooklyn)
              .listen((shouldGoToTheBeachCog) {
            emissions.add(
              'shouldGoToTheBeachCog in brooklyn: $shouldGoToTheBeachCog',
            );
          });
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.cambridge)
              .listen((shouldGoToTheBeachCog) {
            emissions.add(
              'shouldGoToTheBeachCog in cambridge: $shouldGoToTheBeachCog',
            );
          });

          async.elapse(2.hours);

          expect(
            emissions,
            equals([
              'shouldGoToTheBeachCog in austin: true',
              'isNiceOutsideCog in austin: true',
              'shouldGoToTheBeachCog in brooklyn: false',
              'shouldGoToTheBeachCog in cambridge: false',
            ]),
          );

          async.elapse(2.hours);

          expect(
            emissions,
            equals([
              'shouldGoToTheBeachCog in austin: true',
              'isNiceOutsideCog in austin: true',
              'shouldGoToTheBeachCog in brooklyn: false',
              'shouldGoToTheBeachCog in cambridge: false',
              'shouldGoToTheBeachCog in austin: false',
              'isNiceOutsideCog in austin: false',
              'shouldGoToTheBeachCog in cambridge: true',
            ]),
          );

          async.elapse(2.hours);

          expect(
            emissions,
            equals([
              'shouldGoToTheBeachCog in austin: true',
              'isNiceOutsideCog in austin: true',
              'shouldGoToTheBeachCog in brooklyn: false',
              'shouldGoToTheBeachCog in cambridge: false',
              'shouldGoToTheBeachCog in austin: false',
              'isNiceOutsideCog in austin: false',
              'shouldGoToTheBeachCog in cambridge: true',
            ]),
          );

          async.elapse(2.hours);

          expect(
            emissions,
            equals([
              'shouldGoToTheBeachCog in austin: true',
              'isNiceOutsideCog in austin: true',
              'shouldGoToTheBeachCog in brooklyn: false',
              'shouldGoToTheBeachCog in cambridge: false',
              'shouldGoToTheBeachCog in austin: false',
              'isNiceOutsideCog in austin: false',
              'shouldGoToTheBeachCog in cambridge: true',
              'shouldGoToTheBeachCog in cambridge: false',
              'shouldGoToTheBeachCog in austin: true',
              'isNiceOutsideCog in austin: true'
            ]),
          );
        });
      });
    });
  });
}
