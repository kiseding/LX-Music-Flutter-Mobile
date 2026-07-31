import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/pagination/page_range.dart';

void main() {
  group('PageRange', () {
    test('splits collections into 100-item pages', () {
      final range = PageRange(itemCount: 201, pageIndex: 2);

      expect(range.pageCount, 3);
      expect(range.start, 200);
      expect(range.end, 201);
      expect(range.length, 1);
    });

    test('clamps a requested page to the available page range', () {
      expect(PageRange(itemCount: 201, pageIndex: -1).pageIndex, 0);
      expect(PageRange(itemCount: 201, pageIndex: 9).pageIndex, 2);
      expect(PageRange(itemCount: 0, pageIndex: 9).pageIndex, 0);
    });

    test('finds the page that contains an item index', () {
      expect(PageRange.pageForItem(index: 0), 0);
      expect(PageRange.pageForItem(index: 99), 0);
      expect(PageRange.pageForItem(index: 100), 1);
      expect(PageRange.pageForItem(index: 250), 2);
    });

    test('returns only the items in the selected page', () {
      final items = List.generate(205, (index) => index);
      final range = PageRange(itemCount: items.length, pageIndex: 1);

      expect(pageSlice(items, range), List.generate(100, (index) => index + 100));
    });
  });
}
