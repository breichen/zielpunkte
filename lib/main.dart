import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notifications.dart';

// ---------------------------------------------------------------------------
// Modell & Zustand
// ---------------------------------------------------------------------------

/// Zeitraum eines Ziels: 0 = täglich, 1 = pro Woche (Mo–So), 2 = pro Monat.
class Goal {
  Goal({
    required this.id,
    required this.name,
    required this.points,
    this.period = 0,
    this.times = 1,
  });
  final String id;
  String name;
  int points; // Punkte pro Abhaken
  int period;
  int times; // Zielanzahl pro Zeitraum (täglich: immer 1)

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'points': points,
        'period': period,
        'times': times,
      };
  factory Goal.fromJson(Map<String, dynamic> j) => Goal(
        id: j['id'],
        name: j['name'],
        points: j['points'],
        period: j['period'] ?? 0,
        times: j['times'] ?? 1,
      );

  String get periodWord => const ['Tag', 'Woche', 'Monat'][period];

  /// z. B. „+3 pro Mal · 2× pro Woche“ oder „+1 pro Tag“
  String get description => period == 0
      ? '+$points pro Tag'
      : '+$points pro Mal · $times× pro $periodWord';
}

DateTime periodStart(int period, DateTime d) {
  switch (period) {
    case 1:
      return DateTime(d.year, d.month, d.day - (d.weekday - 1));
    case 2:
      return DateTime(d.year, d.month, 1);
    default:
      return dayOnly(d);
  }
}

DateTime shiftPeriod(int period, DateTime start, int n) {
  switch (period) {
    case 1:
      return DateTime(start.year, start.month, start.day + 7 * n);
    case 2:
      return DateTime(start.year, start.month + n, 1);
    default:
      return DateTime(start.year, start.month, start.day + n);
  }
}

const _monate = [
  'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August',
  'September', 'Oktober', 'November', 'Dezember'
];
const _tage = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

String dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
int daysInMonth(DateTime m) => DateTime(m.year, m.month + 1, 0).day;

class AppState extends ChangeNotifier {
  List<Goal> goals = [];
  final Map<String, Set<String>> done = {}; // dateKey -> goalIds
  int targetPercent = 70;
  bool reminderOn = false;
  int reminderHour = 20;
  int reminderMinute = 30;
  bool loaded = false;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('data');
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      goals = (j['goals'] as List).map((e) => Goal.fromJson(e)).toList();
      (j['done'] as Map<String, dynamic>).forEach((k, v) {
        done[k] = Set<String>.from(v as List);
      });
      targetPercent = j['targetPercent'] ?? 70;
      reminderOn = j['reminderOn'] ?? false;
      reminderHour = j['reminderHour'] ?? 20;
      reminderMinute = j['reminderMinute'] ?? 30;
    } else {
      goals = [
        Goal(id: 'g1', name: 'Kein Schoko', points: 1),
        Goal(id: 'g2', name: 'Keine Chips', points: 1),
        Goal(id: 'g3', name: 'Sport', points: 3),
      ];
    }
    loaded = true;
    notifyListeners();
    refreshReminders();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      'data',
      jsonEncode({
        'goals': goals.map((g) => g.toJson()).toList(),
        'done': done.map((k, v) => MapEntry(k, v.toList())),
        'targetPercent': targetPercent,
        'reminderOn': reminderOn,
        'reminderHour': reminderHour,
        'reminderMinute': reminderMinute,
      }),
    );
  }

  void _changed() {
    notifyListeners();
    _save();
    refreshReminders();
  }

  /// Plant die Erinnerungen neu (heute entfällt, wenn schon etwas eingetragen ist).
  Future<void> refreshReminders() {
    final hasEntryToday =
        (done[dateKey(DateTime.now())]?.isNotEmpty) ?? false;
    return NotificationService.instance.sync(
      enabled: reminderOn,
      hour: reminderHour,
      minute: reminderMinute,
      hasEntryToday: hasEntryToday,
    );
  }

  void setReminder({bool? on, TimeOfDay? time}) {
    if (on != null) reminderOn = on;
    if (time != null) {
      reminderHour = time.hour;
      reminderMinute = time.minute;
    }
    _changed();
  }

  bool isDone(DateTime d, String goalId) =>
      done[dateKey(d)]?.contains(goalId) ?? false;

  void toggle(DateTime d, String goalId) {
    final s = done.putIfAbsent(dateKey(d), () => {});
    if (!s.remove(goalId)) s.add(goalId);
    _changed();
  }

  /// Anzahl Abhak-Tage eines Ziels im Zeitraum, der bei [start] beginnt.
  int countInPeriod(Goal g, DateTime start) {
    final end = shiftPeriod(g.period, start, 1);
    var n = 0;
    for (var d = start; d.isBefore(end); d = DateTime(d.year, d.month, d.day + 1)) {
      if (isDone(d, g.id)) n++;
    }
    return n;
  }

  /// Punkte eines Ziels an einem Tag. Bei Wochen-/Monatszielen zählen nur
  /// die ersten [times] Mal im Zeitraum, weitere bringen keine Punkte.
  int pointsForGoalOnDay(Goal g, DateTime d) {
    if (!isDone(d, g.id)) return 0;
    if (g.period == 0) return g.points;
    var before = 0;
    for (var x = periodStart(g.period, d);
        x.isBefore(dayOnly(d));
        x = DateTime(x.year, x.month, x.day + 1)) {
      if (isDone(x, g.id)) before++;
    }
    return before < g.times ? g.points : 0;
  }

  int pointsForDay(DateTime d) =>
      goals.fold(0, (a, g) => a + pointsForGoalOnDay(g, d));

  /// Summe der Punkte aller Ziele (Obergrenze für einen einzelnen Tag).
  int get maxSingleDay => goals.fold(0, (a, g) => a + g.points);

  int maxForGoalInMonth(Goal g, DateTime m) {
    final days = daysInMonth(m);
    switch (g.period) {
      case 1:
        return (g.points * g.times * days / 7).round();
      case 2:
        return g.points * g.times;
      default:
        return g.points * days;
    }
  }

  int maxForMonth(DateTime m) =>
      goals.fold(0, (a, g) => a + maxForGoalInMonth(g, m));
  int targetForMonth(DateTime m) =>
      (maxForMonth(m) * targetPercent / 100).round();

  /// Serie: aufeinanderfolgende Tage/Wochen/Monate mit erreichtem Ziel.
  int streak(Goal g) {
    var start = periodStart(g.period, DateTime.now());
    if (countInPeriod(g, start) < g.times) {
      start = shiftPeriod(g.period, start, -1); // laufender Zeitraum offen
    }
    var n = 0;
    while (countInPeriod(g, start) >= g.times) {
      n++;
      start = shiftPeriod(g.period, start, -1);
    }
    return n;
  }

  void addGoal(String name, int points, int period, int times) {
    goals.add(Goal(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        points: points,
        period: period,
        times: period == 0 ? 1 : times));
    _changed();
  }

  void editGoal(Goal g, String name, int points, int period, int times) {
    g.name = name;
    g.points = points;
    g.period = period;
    g.times = period == 0 ? 1 : times;
    _changed();
  }

  void deleteGoal(Goal g) {
    goals.remove(g);
    _changed();
  }

  void setTargetPercent(int v) {
    targetPercent = v;
    _changed();
  }
}

final appState = AppState();

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  appState.load();
  runApp(const ZielApp());
}

class ZielApp extends StatelessWidget {
  const ZielApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zielpunkte',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
          useMaterial3: true),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Beim Zurückkehren in die App den 14-Tage-Zeitraum auffrischen.
    if (state == AppLifecycleState.resumed && appState.loaded) {
      appState.refreshReminders();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (!appState.loaded) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        // Bewusst NICHT const: Konstante Widgets werden von Flutter beim Rebuild
        // übersprungen, dann würden sich die Seiten nicht aktualisieren.
        // ignore: prefer_const_constructors
        final pages = [TodayPage(), MonthPage(), GoalsPage()];
        return Scaffold(
          body: SafeArea(child: pages[_tab]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.check_circle_outline), label: 'Heute'),
              NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Monat'),
              NavigationDestination(icon: Icon(Icons.flag_outlined), label: 'Ziele'),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Heute
// ---------------------------------------------------------------------------

class TodayPage extends StatefulWidget {
  const TodayPage({super.key});
  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  DateTime _day = dayOnly(DateTime.now());

  String _label(DateTime d) {
    final today = dayOnly(DateTime.now());
    final diff = today.difference(d).inDays;
    final base = '${_tage[d.weekday - 1]}, ${d.day}. ${_monate[d.month - 1]}';
    if (diff == 0) return 'Heute · $base';
    if (diff == 1) return 'Gestern · $base';
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final today = dayOnly(DateTime.now());
    final canGoForward = _day.isBefore(today);
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(
                    () => _day = DateTime(_day.year, _day.month, _day.day - 1)),
              ),
              Expanded(
                child: Text(_label(_day),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: canGoForward
                    ? () => setState(() =>
                        _day = DateTime(_day.year, _day.month, _day.day + 1))
                    : null,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Text('${appState.pointsForDay(_day)}',
                  style: Theme.of(context)
                      .textTheme
                      .displayMedium
                      ?.copyWith(color: cs.primary, fontWeight: FontWeight.bold)),
              Text('Punkte an diesem Tag',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: appState.goals.isEmpty
              ? const Center(child: Text('Lege zuerst unter „Ziele“ ein Ziel an.'))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final g in appState.goals) _goalTile(g, cs),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _goalTile(Goal g, ColorScheme cs) {
    final checked = appState.isDone(_day, g.id);
    final streak = appState.streak(g);
    final count = g.period == 0
        ? 0
        : appState.countInPeriod(g, periodStart(g.period, _day));
    final reached = g.period != 0 && count >= g.times;
    final unit = const ['Tage', 'Wo.', 'Mon.'][g.period];
    final String sub;
    if (g.period == 0) {
      sub = '+${g.points} ${g.points == 1 ? 'Punkt' : 'Punkte'}';
    } else {
      final when = g.period == 1 ? 'diese Woche' : 'diesen Monat';
      final over = count > g.times ? ' ✨' : '';
      sub = '$count/${g.times} $when$over · +${g.points} pro Mal'
          '${reached && !checked ? ' (weitere ohne Punkte)' : ''}';
    }
    return Card(
      color: checked ? cs.primaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => appState.toggle(_day, g.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              Icon(checked ? Icons.check_circle : Icons.circle_outlined,
                  size: 32, color: checked ? cs.primary : cs.outline),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name, style: Theme.of(context).textTheme.titleMedium),
                    Text(sub, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (streak > 0)
                Chip(
                  label: Text('🔥 $streak $unit'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Monat
// ---------------------------------------------------------------------------

class MonthPage extends StatefulWidget {
  const MonthPage({super.key});
  @override
  State<MonthPage> createState() => _MonthPageState();
}

class _MonthPageState extends State<MonthPage> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  bool _showCumulative = false;

  @override
  Widget build(BuildContext context) {
    final now = dayOnly(DateTime.now());
    final n = daysInMonth(_month);
    final isCurrent = _month.year == now.year && _month.month == now.month;
    final isFuture = _month.isAfter(DateTime(now.year, now.month));
    final lastDay = isFuture ? 0 : (isCurrent ? now.day : n);

    final daily = <int>[];
    for (var d = 1; d <= n; d++) {
      daily.add(d <= lastDay
          ? appState.pointsForDay(DateTime(_month.year, _month.month, d))
          : 0);
    }
    final cumul = <FlSpot>[const FlSpot(0, 0)];
    var sum = 0;
    for (var d = 1; d <= lastDay; d++) {
      sum += daily[d - 1];
      cumul.add(FlSpot(d.toDouble(), sum.toDouble()));
    }

    final target = appState.targetForMonth(_month);
    final max = appState.maxForMonth(_month);
    final expected = lastDay == 0 ? 0 : target * lastDay / n;
    final progress = target == 0 ? 0.0 : (sum / target).clamp(0.0, 1.0);
    final cs = Theme.of(context).colorScheme;

    String status;
    if (target == 0) {
      status = 'Lege Ziele an, dann entsteht ein Monatsziel.';
    } else if (sum >= target) {
      status = 'Monatsziel erreicht 🎉';
    } else if (lastDay == 0) {
      status = 'Der Monat hat noch nicht begonnen.';
    } else if (sum >= expected) {
      status = 'Auf Kurs (+${(sum - expected).round()} Punkte Vorsprung)';
    } else {
      status = isCurrent
          ? 'Etwas hinter dem Plan (${(expected - sum).round()} Punkte), noch gut aufholbar'
          : 'Ziel knapp verfehlt: ${target - sum} Punkte fehlten';
    }

    final bestDay = daily.isEmpty ? 0 : daily.reduce((a, b) => a > b ? a : b);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(
                  () => _month = DateTime(_month.year, _month.month - 1)),
            ),
            Expanded(
              child: Text('${_monate[_month.month - 1]} ${_month.year}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(
                  () => _month = DateTime(_month.year, _month.month + 1)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('$sum',
                        style: Theme.of(context).textTheme.displaySmall?.copyWith(
                            color: cs.primary, fontWeight: FontWeight.bold)),
                    Text('  / $target Ziel  ·  max. $max',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress, minHeight: 8),
                const SizedBox(height: 8),
                Text(status),
                if (bestDay > 0)
                  Text('Bester Tag: $bestDay Punkte',
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
        SizedBox(
          height: 260,
          child: _showCumulative
              ? _cumulChart(cumul, n, target, sum, cs)
              : _dailyChart(daily, n, cs),
        ),
        // Feste Höhe, damit nichts springt, wenn der Hinweis erscheint/verschwindet.
        SizedBox(
          height: 28,
          child: Center(
            child: _showCumulative
                ? Text('Gestrichelte Linie = Zielpfad',
                    style: Theme.of(context).textTheme.bodySmall)
                : null,
          ),
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Pro Tag')),
            ButtonSegment(value: true, label: Text('Kumuliert')),
          ],
          selected: {_showCumulative},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _showCumulative = v.first),
        ),
      ],
    );
  }

  /// Schöner Achsenabstand (1, 2, 5, 10, 20, 50 ...) für ca. 4 Beschriftungen.
  double _niceInterval(double max) {
    final raw = max <= 4 ? 1.0 : max / 4;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (final m in [1, 2, 5, 10]) {
      if (m * mag >= raw) return m * mag;
    }
    return 10 * mag;
  }

  /// Rundet das Maximum auf ein Vielfaches des Achsenabstands auf.
  double _niceMax(double max, double interval) =>
      (max / interval).ceil() * interval;

  FlTitlesData _titles(int n, double yInterval) => FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            interval: yInterval,
            getTitlesWidget: (v, meta) {
              if (v != v.roundToDouble()) return const SizedBox.shrink();
              return Text(v.toInt().toString(),
                  style: const TextStyle(fontSize: 11),
                  textAlign: TextAlign.right);
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 24,
            interval: 1,
            getTitlesWidget: (v, meta) {
              // In beiden Diagrammen gleich: Tag 1, 5, 10, 15, ...
              final d = v.round();
              if (v != d.toDouble() || d < 1 || !(d == 1 || d % 5 == 0)) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('$d', style: const TextStyle(fontSize: 11)),
              );
            },
          ),
        ),
      );

  Widget _dailyChart(List<int> daily, int n, ColorScheme cs) {
    final rawMax = [appState.maxSingleDay, ...daily, 1].reduce((a, b) => a > b ? a : b).toDouble();
    final interval = _niceInterval(rawMax);
    final maxY = _niceMax(rawMax, interval);
    return BarChart(
      BarChartData(
        maxY: maxY,
        minY: 0,
        titlesData: _titles(n, interval),
        borderData: FlBorderData(show: false),
        gridData: FlGridData(drawVerticalLine: false, horizontalInterval: interval),
        barGroups: [
          for (var d = 1; d <= n; d++)
            BarChartGroupData(x: d, barRods: [
              BarChartRodData(
                toY: daily[d - 1].toDouble(),
                width: 5,
                color: cs.primary,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
              ),
            ]),
        ],
      ),
    );
  }

  Widget _cumulChart(
      List<FlSpot> cumul, int n, int target, int sum, ColorScheme cs) {
    final rawTop =
        [target, sum, 1].reduce((a, b) => a > b ? a : b).toDouble();
    final interval = _niceInterval(rawTop);
    final top = _niceMax(rawTop, interval);
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: n.toDouble(),
        minY: 0,
        maxY: top,
        titlesData: _titles(n, interval),
        borderData: FlBorderData(show: false),
        gridData: FlGridData(drawVerticalLine: false, horizontalInterval: interval),
        lineBarsData: [
          LineChartBarData(
            spots: [const FlSpot(0, 0), FlSpot(n.toDouble(), target.toDouble())],
            isCurved: false,
            barWidth: 2,
            color: cs.outline,
            dashArray: [6, 4],
            dotData: const FlDotData(show: false),
          ),
          LineChartBarData(
            spots: cumul,
            isCurved: false,
            barWidth: 3,
            color: cs.primary,
            dotData: const FlDotData(show: false),
            belowBarData:
                BarAreaData(show: true, color: cs.primary.withOpacity(0.15)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ziele
// ---------------------------------------------------------------------------

class GoalsPage extends StatelessWidget {
  const GoalsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);
    final max = appState.maxForMonth(month);
    final target = appState.targetForMonth(month);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editDialog(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Ziel'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Monatsziel',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                      '${appState.targetPercent} % der möglichen Punkte = $target von $max '
                      '(${_monate[month.month - 1]}, ${daysInMonth(month)} Tage)'),
                  Slider(
                    value: appState.targetPercent.toDouble(),
                    min: 30,
                    max: 100,
                    divisions: 14,
                    label: '${appState.targetPercent} %',
                    onChanged: (v) => appState.setTargetPercent(v.round()),
                  ),
                  Text(
                    'Tipp: 100 % hieße, jeden Tag jedes Ziel zu schaffen. '
                    '60–80 % ist meist ambitioniert, aber realistisch.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (NotificationService.instance.supported) _reminderCard(context),
          const SizedBox(height: 8),
          for (final g in appState.goals)
            Card(
              child: ListTile(
                title: Text(g.name),
                subtitle: Text(g.description),
                onTap: () => _editDialog(context, g),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDelete(context, g),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _reminderCard(BuildContext context) {
    final time = TimeOfDay(
        hour: appState.reminderHour, minute: appState.reminderMinute);
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Tägliche Erinnerung'),
            subtitle: const Text(
                'Entfällt, sobald du an dem Tag schon etwas eingetragen hast.'),
            value: appState.reminderOn,
            onChanged: (v) async {
              if (v) {
                final ok = await NotificationService.instance.requestPermission();
                if (!ok) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            'Benachrichtigungen sind nicht erlaubt. Bitte in den Systemeinstellungen aktivieren.')));
                  }
                  return;
                }
              }
              appState.setReminder(on: v);
            },
          ),
          ListTile(
            enabled: appState.reminderOn,
            title: const Text('Uhrzeit'),
            trailing: Text(time.format(context),
                style: Theme.of(context).textTheme.titleMedium),
            onTap: !appState.reminderOn
                ? null
                : () async {
                    final picked = await showTimePicker(
                        context: context, initialTime: time);
                    if (picked != null) appState.setReminder(time: picked);
                  },
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, Goal g) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('„${g.name}“ löschen?'),
        content: const Text('Die Punkte dieses Ziels fließen dann nicht mehr in die Auswertung ein.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () {
              appState.deleteGoal(g);
              Navigator.pop(ctx);
            },
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
  }

  void _editDialog(BuildContext context, Goal? goal) {
    final ctrl = TextEditingController(text: goal?.name ?? '');
    var pts = (goal?.points ?? 1).toDouble();
    var period = goal?.period ?? 0;
    var times = (goal?.times ?? 1).toDouble();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(goal == null ? 'Neues Ziel' : 'Ziel bearbeiten'),
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Name', hintText: 'z. B. Kein Schoko'),
              ),
              const SizedBox(height: 16),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Täglich')),
                  ButtonSegment(value: 1, label: Text('Woche')),
                  ButtonSegment(value: 2, label: Text('Monat')),
                ],
                selected: {period},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setLocal(() {
                  period = v.first;
                  final maxT = period == 1 ? 6.0 : 28.0;
                  if (times > maxT) times = maxT;
                }),
              ),
              if (period != 0) ...[
                const SizedBox(height: 12),
                Text('Ziel: ${times.round()}× pro ${period == 1 ? 'Woche' : 'Monat'}'),
                Slider(
                  value: times,
                  min: 1,
                  max: period == 1 ? 6 : 28,
                  divisions: period == 1 ? 5 : 27,
                  label: '${times.round()}',
                  onChanged: (v) => setLocal(() => times = v),
                ),
                Text('Punkte gibt es nur für die ersten ${times.round()} Mal.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              Text(period == 0
                  ? 'Punkte pro Tag: ${pts.round()}'
                  : 'Punkte pro Mal: ${pts.round()}'),
              Slider(
                value: pts,
                min: 1,
                max: 5,
                divisions: 4,
                label: '${pts.round()}',
                onChanged: (v) => setLocal(() => pts = v),
              ),
            ],
          ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
            FilledButton(
              onPressed: () {
                final name = ctrl.text.trim();
                if (name.isEmpty) return;
                if (goal == null) {
                  appState.addGoal(name, pts.round(), period, times.round());
                } else {
                  appState.editGoal(goal, name, pts.round(), period, times.round());
                }
                Navigator.pop(ctx);
              },
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
  }
}
