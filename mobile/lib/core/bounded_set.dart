import 'dart:collection';

/// A Set that automatically evicts the oldest entries when it exceeds [maxSize].
class BoundedSet<T> {
  final int maxSize;
  final LinkedHashSet<T> _set = LinkedHashSet<T>();

  BoundedSet(this.maxSize);

  bool contains(T value) => _set.contains(value);

  void add(T value) {
    _set.add(value);
    while (_set.length > maxSize) {
      _set.remove(_set.first);
    }
  }

  void clear() => _set.clear();

  int get length => _set.length;
}
