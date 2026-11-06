import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'calendar_days.dart';

String tradingDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime shanghaiDate(DateTime instant) {
  final local = instant.toUtc().add(const Duration(hours: 8));
  return DateTime(local.year, local.month, local.day);
}

/// 完整年度日历，未公布、缺日期或字段异常的年份不视为已缓存。
class TradingCalendarYear {
  TradingCalendarYear(this.year, Map<String, bool> days)
    : days = Map.unmodifiable(days) {
    final count = DateTime(year, 3, 0).day == 29 ? 366 : 365;
    if (year < 2000 || year > 2200 || days.length != count) {
      throw const FormatException('Incomplete trading calendar');
    }
    var open = 0;
    for (
      var day = DateTime(year);
      day.year == year;
      day = addCalendarDays(day, 1)
    ) {
      final value = days[tradingDateKey(day)];
      if (value == null || (day.weekday >= DateTime.saturday && value)) {
        throw const FormatException('Invalid trading day');
      }
      if (value) open++;
    }
    if (open < 180 || open > 270) {
      throw const FormatException('Unpublished trading calendar');
    }
  }

  final int year;
  final Map<String, bool> days;
}

typedef TradingCalendarFetcher = Future<String> Function(Uri uri);

/// 只读取深交所公开日历，不发送资产或交易；缓存为可重新下载的私有文件。
class TradingCalendarService {
  TradingCalendarService({
    this.cacheFile,
    this.fetchMonth,
    this.onFailure,
    Iterable<TradingCalendarYear> initialCalendars = const [],
  }) : _years = {
         for (final calendar in initialCalendars) calendar.year: calendar,
       };

  factory TradingCalendarService.production(
    File file, {
    void Function(String)? onFailure,
  }) => TradingCalendarService(
    cacheFile: file,
    fetchMonth: _download,
    onFailure: onFailure,
  );

  final File? cacheFile;
  final TradingCalendarFetcher? fetchMonth;
  final void Function(String)? onFailure;
  final Map<int, TradingCalendarYear> _years;
  final Map<int, DateTime> _lastAttempt = {};
  Future<void> _syncing = Future<void>.value();

  List<int> get years => _years.keys.toList()..sort();
  bool? isTradingDay(DateTime day) =>
      _years[day.year]?.days[tradingDateKey(day)];

  DateTime? nextTradingDay(DateTime from) {
    var day = DateTime(from.year, from.month, from.day);
    for (var i = 0; i < 370; i++) {
      final open = isTradingDay(day);
      if (open == null) return null;
      if (open) return day;
      day = addCalendarDays(day, 1);
    }
    return null;
  }

  Future<void> load() async {
    final file = cacheFile;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      if (await file.length() > 2000000) return;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['version'] != 1) return;
      final calendars = data['years'] as Map<String, dynamic>;
      for (final entry in calendars.entries) {
        final days = (entry.value as Map<String, dynamic>).cast<String, bool>();
        final calendar = TradingCalendarYear(int.parse(entry.key), days);
        _years[calendar.year] = calendar;
      }
    } catch (error) {
      onFailure?.call('Calendar cache rejected: ${error.runtimeType}');
    }
  }

  Future<void> ensureYears(
    Set<int> requested,
    DateTime now, {
    bool force = false,
  }) {
    final task = _syncing.then(
      (_) => _fetchYears(requested, now, force: force),
    );
    _syncing = task;
    return task;
  }

  Future<void> _fetchYears(
    Set<int> requested,
    DateTime now, {
    required bool force,
  }) async {
    final fetch = fetchMonth;
    if (fetch == null) return;
    for (final year in requested.toList()..sort()) {
      if (!force && _years.containsKey(year)) continue;
      final last = _lastAttempt[year];
      if (!force &&
          last != null &&
          now.difference(last) < const Duration(minutes: 5)) {
        continue;
      }
      _lastAttempt[year] = now;
      try {
        final months = await Future.wait([
          for (var month = 1; month <= 12; month++)
            fetch(
              Uri.https(
                'www.szse.cn',
                '/api/report/exchange/onepersistenthour/monthList',
                {'month': '$year-${month.toString().padLeft(2, '0')}'},
              ),
            ).timeout(const Duration(seconds: 6)),
        ]);
        final days = <String, bool>{};
        for (var index = 0; index < months.length; index++) {
          final payload = jsonDecode(months[index]) as Map<String, dynamic>;
          final rows = payload['data'] as List;
          final month = index + 1;
          if (rows.length != DateTime(year, month + 1, 0).day) {
            throw const FormatException('Incomplete calendar month');
          }
          for (final row in rows.cast<Map<String, dynamic>>()) {
            final key = row['jyrq'] as String;
            final date = DateTime.tryParse(key);
            final flag = row['jybz'];
            if (date == null ||
                date.year != year ||
                date.month != month ||
                tradingDateKey(date) != key ||
                days.containsKey(key) ||
                (flag != '0' && flag != '1')) {
              throw const FormatException('Invalid calendar response');
            }
            days[key] = flag == '1';
          }
        }
        final calendar = TradingCalendarYear(year, days);
        final file = cacheFile;
        if (file != null) {
          await file.parent.create(recursive: true);
          final temp = File('${file.path}.tmp');
          await temp.writeAsString(
            jsonEncode({
              'version': 1,
              'years': {
                for (final cached in _years.values)
                  '${cached.year}': cached.days,
                '$year': calendar.days,
              },
            }),
            flush: true,
          );
          await temp.rename(file.path);
        }
        _years[year] = calendar;
      } catch (error) {
        onFailure?.call('Calendar $year unavailable: ${error.runtimeType}');
      }
    }
  }

  static Future<String> _download(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != 200) {
        throw const HttpException('Calendar unavailable');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        bytes.addAll(chunk);
        if (bytes.length > 128000) {
          throw const FormatException('Calendar too large');
        }
      }
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
  }
}
