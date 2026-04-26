import 'package:flutter_test/flutter_test.dart';
import 'package:bitchat_messenger/core/bounded_set.dart';

void main() {
  group('BoundedSet', () {
    test('contains returns false for missing item', () {
      final s = BoundedSet<String>(5);
      expect(s.contains('x'), isFalse);
    });

    test('contains returns true after add', () {
      final s = BoundedSet<String>(5);
      s.add('hello');
      expect(s.contains('hello'), isTrue);
    });

    test('length tracks item count', () {
      final s = BoundedSet<int>(10);
      s.add(1);
      s.add(2);
      s.add(3);
      expect(s.length, 3);
    });

    test('does not exceed maxSize', () {
      final s = BoundedSet<int>(3);
      for (int i = 0; i < 10; i++) {
        s.add(i);
      }
      expect(s.length, 3);
    });

    test('evicts oldest entries when full', () {
      final s = BoundedSet<int>(3);
      s.add(1);
      s.add(2);
      s.add(3);
      s.add(4); // should evict 1
      expect(s.contains(1), isFalse);
      expect(s.contains(4), isTrue);
    });

    test('retains newest entries after eviction', () {
      final s = BoundedSet<String>(3);
      s.add('a');
      s.add('b');
      s.add('c');
      s.add('d'); // evicts 'a'
      s.add('e'); // evicts 'b'
      expect(s.contains('a'), isFalse);
      expect(s.contains('b'), isFalse);
      expect(s.contains('c'), isTrue);
      expect(s.contains('d'), isTrue);
      expect(s.contains('e'), isTrue);
    });

    test('duplicate add does not increase length', () {
      final s = BoundedSet<String>(5);
      s.add('x');
      s.add('x');
      expect(s.length, 1);
    });

    test('remove returns true and removes item', () {
      final s = BoundedSet<String>(5);
      s.add('a');
      expect(s.remove('a'), isTrue);
      expect(s.contains('a'), isFalse);
    });

    test('remove returns false for missing item', () {
      final s = BoundedSet<String>(5);
      expect(s.remove('missing'), isFalse);
    });

    test('clear empties the set', () {
      final s = BoundedSet<int>(5);
      s.add(1);
      s.add(2);
      s.clear();
      expect(s.length, 0);
      expect(s.contains(1), isFalse);
    });

    test('maxSize of 1 keeps only the latest', () {
      final s = BoundedSet<int>(1);
      s.add(1);
      s.add(2);
      expect(s.contains(1), isFalse);
      expect(s.contains(2), isTrue);
      expect(s.length, 1);
    });
  });
}
