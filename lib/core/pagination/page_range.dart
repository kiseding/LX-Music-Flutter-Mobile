class PageRange {
  PageRange({
    required this.itemCount,
    required int pageIndex,
    this.pageSize = defaultPageSize,
  })  : assert(itemCount >= 0),
        assert(pageSize > 0),
        pageIndex = _clampPageIndex(
          pageIndex: pageIndex,
          itemCount: itemCount,
          pageSize: pageSize,
        );

  static const defaultPageSize = 100;

  final int itemCount;
  final int pageIndex;
  final int pageSize;

  int get pageCount => (itemCount + pageSize - 1) ~/ pageSize;

  int get start => pageIndex * pageSize;

  int get end => (start + pageSize).clamp(0, itemCount).toInt();

  int get length => end - start;

  static int pageForItem({required int index, int pageSize = defaultPageSize}) {
    assert(index >= 0);
    assert(pageSize > 0);
    return index ~/ pageSize;
  }

  static int _clampPageIndex({
    required int pageIndex,
    required int itemCount,
    required int pageSize,
  }) {
    final pageCount = (itemCount + pageSize - 1) ~/ pageSize;
    if (pageCount == 0) return 0;
    return pageIndex.clamp(0, pageCount - 1).toInt();
  }
}

List<T> pageSlice<T>(List<T> items, PageRange range) {
  assert(items.length == range.itemCount);
  return items.sublist(range.start, range.end);
}
