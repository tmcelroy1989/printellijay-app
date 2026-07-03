import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

const String API_BASE = 'https://www.printellijay.net/api/orders';
const String APP_SECRET = 'ellijay2026';

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await notificationsPlugin.initialize(
    const InitializationSettings(android: androidInit),
  );
  runApp(const PrintEllijayApp());
}

class PrintEllijayApp extends StatelessWidget {
  const PrintEllijayApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Print Ellijay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2D6A4F),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const OrderBoardScreen(),
    );
  }
}

class PrintItem {
  final String size;
  final String colorMode;
  final int pages;
  final double price;
  PrintItem({required this.size, required this.colorMode, required this.pages, required this.price});
  factory PrintItem.fromJson(Map<String, dynamic> j) => PrintItem(
    size: j['size'] ?? '',
    colorMode: j['colorMode'] ?? j['color'] ?? '',
    pages: (j['pages'] ?? j['quantity'] ?? 1) is int ? (j['pages'] ?? j['quantity'] ?? 1) : int.tryParse('${j['pages'] ?? j['quantity'] ?? 1}') ?? 1,
    price: (j['price'] ?? 0).toDouble(),
  );
}

class Order {
  final String id;
  final int orderNumber;
  String status;
  final DateTime createdAt;
  final String name;
  final String email;
  final String phone;
  final String notes;
  final List<PrintItem> prints;
  final double subtotal;
  final double tax;
  final double total;
  Order({required this.id, required this.orderNumber, required this.status,
    required this.createdAt, required this.name, required this.email,
    required this.phone, required this.notes, required this.prints,
    required this.subtotal, required this.tax, required this.total});
  factory Order.fromJson(Map<String, dynamic> j) => Order(
    id: j['id'] ?? '',
    orderNumber: (j['orderNumber'] ?? 0) is int ? j['orderNumber'] : int.tryParse('${j['orderNumber']}') ?? 0,
    status: j['status'] ?? 'New',
    createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
    name: j['name'] ?? '',
    email: j['email'] ?? '',
    phone: j['phone'] ?? '',
    notes: j['notes'] ?? '',
    prints: (j['prints'] as List? ?? []).map((p) => PrintItem.fromJson(p as Map<String, dynamic>)).toList(),
    subtotal: (j['subtotal'] ?? 0).toDouble(),
    tax: (j['tax'] ?? 0).toDouble(),
    total: (j['total'] ?? 0).toDouble(),
  );
}
const List<String> STATUS_COLUMNS = ['New', 'Review', 'Printed', 'Paid', 'PickedUp'];
const Map<String, Color> STATUS_COLORS = {
  'New': Color(0xFF1565C0), 'Review': Color(0xFFF57F17),
  'Printed': Color(0xFF2E7D32), 'Paid': Color(0xFF6A1B9A), 'PickedUp': Color(0xFF757575),
};
const Map<String, IconData> STATUS_ICONS = {
  'New': Icons.fiber_new, 'Review': Icons.rate_review,
  'Printed': Icons.print, 'Paid': Icons.attach_money, 'PickedUp': Icons.check_circle,
};

class OrderBoardScreen extends StatefulWidget {
  const OrderBoardScreen({super.key});
  @override
  State<OrderBoardScreen> createState() => _OrderBoardScreenState();
}

class _OrderBoardScreenState extends State<OrderBoardScreen> {
  List<Order> _orders = [];
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  Set<String> _seenIds = {};

  @override
  void initState() {
    super.initState();
    _loadSeenIds().then((_) => _fetchOrders());
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) => _fetchOrders());
  }

  @override
  void dispose() { _pollTimer?.cancel(); super.dispose(); }

  Future<void> _loadSeenIds() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _seenIds = (prefs.getStringList('seen_order_ids') ?? []).toSet());
  }

  Future<void> _saveSeenIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('seen_order_ids', _seenIds.toList());
  }

  Future<void> _fetchOrders() async {
    try {
      final resp = await http.get(Uri.parse(API_BASE), headers: {'x-app-secret': APP_SECRET});
      if (resp.statusCode == 200) {
        final List data = json.decode(resp.body);
        final orders = data.map((j) => Order.fromJson(j)).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        for (final order in orders) {
          if (!_seenIds.contains(order.id)) {
            _notifyNewOrder(order);
            _seenIds.add(order.id);
          }
        }
        await _saveSeenIds();
        setState(() { _orders = orders; _loading = false; _error = null; });
      } else {
        setState(() { _error = 'Server error ${resp.statusCode}'; _loading = false; });
      }
    } catch (e) {
      setState(() { _error = 'Could not connect: $e'; _loading = false; });
    }
  }

  void _notifyNewOrder(Order order) async {
    await notificationsPlugin.show(
      order.orderNumber,
      'New Order #${order.orderNumber}',
      '${order.name} — $${order.total.toStringAsFixed(2)}',
      const NotificationDetails(android: AndroidNotificationDetails(
        'new_orders', 'New Orders',
        channelDescription: 'Notifications for new print orders',
        importance: Importance.high, priority: Priority.high,
      )),
    );
  }

  Future<void> _updateStatus(Order order, String newStatus) async {
    try {
      final resp = await http.patch(
        Uri.parse(API_BASE),
        headers: {'Content-Type': 'application/json', 'x-app-secret': APP_SECRET},
        body: json.encode({'id': order.id, 'status': newStatus}),
      );
      if (resp.statusCode == 200) await _fetchOrders();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  List<Order> _ordersForStatus(String status) => _orders.where((o) => o.status == status).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Print Ellijay', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF2D6A4F),
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () { setState(() => _loading = true); _fetchOrders(); })],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator())
          : _error != null ? _buildError() : _buildBoard(),
    );
  }

  Widget _buildError() => Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    const Icon(Icons.wifi_off, size: 64, color: Colors.grey),
    const SizedBox(height: 16), Text(_error!, textAlign: TextAlign.center),
    const SizedBox(height: 16), ElevatedButton(onPressed: _fetchOrders, child: const Text('Retry')),
  ]));

  Widget _buildBoard() {
    final activeStatuses = STATUS_COLUMNS.where((s) => s != 'PickedUp').toList();
    return Column(children: [
      Container(
        color: const Color(0xFF1B4332),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Text('${_orders.length} active order${_orders.length == 1 ? '' : 's'}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const Spacer(),
          ...activeStatuses.map((s) {
            final count = _ordersForStatus(s).length;
            if (count == 0) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: STATUS_COLORS[s]!.withOpacity(0.8), borderRadius: BorderRadius.circular(12)),
              child: Text('$count $s', style: const TextStyle(color: Colors.white, fontSize: 11)),
            );
          }),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: activeStatuses.length,
          itemBuilder: (ctx, i) => _buildStatusSection(activeStatuses[i], _ordersForStatus(activeStatuses[i])),
        ),
      ),
    ]);
  }

  Widget _buildStatusSection(String status, List<Order> orders) {
    final color = STATUS_COLORS[status]!;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withOpacity(0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12))),
          child: Row(children: [
            Icon(STATUS_ICONS[status], color: color, size: 20), const SizedBox(width: 8),
            Text(status, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
            const Spacer(),
            if (orders.isNotEmpty) Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
              child: Text('${orders.length}', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ]),
        ),
        if (orders.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No orders', style: TextStyle(color: Colors.grey)))
        else ...orders.map((o) => _buildOrderTile(o, color)),
      ]),
    );
  }

  Widget _buildOrderTile(Order order, Color statusColor) {
    final fmt = DateFormat('MMM d, h:mm a');
    final printSummary = order.prints.isEmpty ? 'No items' : order.prints.map((p) => '${p.pages}x ${p.size}').join(', ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: statusColor.withOpacity(0.2))),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OrderDetailScreen(order: order, onStatusChanged: (s) => _updateStatus(order, s)))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Container(
              width: 52, height: 52,
              decoration: BoxDecoration(color: statusColor.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: statusColor.withOpacity(0.3))),
              child: Center(child: Text('#${order.orderNumber}', style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 13))),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(order.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 2),
              Text(printSummary, style: TextStyle(color: Colors.grey.shade600, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(fmt.format(order.createdAt.toLocal()), style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
            ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$${order.total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const Icon(Icons.chevron_right, color: Colors.grey, size: 18),
            ]),
          ]),
        ),
      ),
    );
  }
}
class OrderDetailScreen extends StatelessWidget {
  final Order order;
  final Function(String) onStatusChanged;
  const OrderDetailScreen({super.key, required this.order, required this.onStatusChanged});

  @override
  Widget build(BuildContext context) {
    final color = STATUS_COLORS[order.status]!;
    final fmt = DateFormat("MMMM d, yyyy 'at' h:mm a");
    final currentIdx = STATUS_COLUMNS.indexOf(order.status);
    final nextStatuses = STATUS_COLUMNS.skip(currentIdx + 1).toList();
    final prevStatuses = STATUS_COLUMNS.take(currentIdx).toList();
    return Scaffold(
      appBar: AppBar(title: Text('Order #${order.orderNumber}'), backgroundColor: color, foregroundColor: Colors.white),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(20), border: Border.all(color: color.withOpacity(0.4))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(STATUS_ICONS[order.status], color: color, size: 18), const SizedBox(width: 6),
              Text(order.status, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
            ]),
          ),
          const SizedBox(height: 16),
          _card('Customer', [
            _row(Icons.person, 'Name', order.name),
            _row(Icons.email, 'Email', order.email),
            if (order.phone.isNotEmpty) _row(Icons.phone, 'Phone', order.phone),
            _row(Icons.schedule, 'Placed', fmt.format(order.createdAt.toLocal())),
          ]),
          const SizedBox(height: 12),
          _card('Print Items', order.prints.isEmpty ? [const Text('No items')] :
            order.prints.asMap().entries.map((e) {
              final p = e.value; final i = e.key + 1;
              return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
                Container(width: 24, height: 24, decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
                  child: Center(child: Text('$i', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)))),
                const SizedBox(width: 10),
                Expanded(child: Text('${p.pages} page${p.pages == 1 ? '' : 's'} · ${p.size} · ${p.colorMode}')),
                Text('$${p.price.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ]));
            }).toList()),
          const SizedBox(height: 12),
          _card('Order Total', [
            _total('Subtotal', order.subtotal), _total('Tax (7%)', order.tax),
            const Divider(), _total('Total', order.total, bold: true),
          ]),
          if (order.notes.isNotEmpty) ...[const SizedBox(height: 12), _card('Notes', [Text(order.notes)])],
          if (nextStatuses.isNotEmpty) ...[const SizedBox(height: 16),
            const Text('Move Forward', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: nextStatuses.map((s) => ElevatedButton.icon(
              icon: Icon(STATUS_ICONS[s], size: 18),
              label: Text(s == 'PickedUp' ? 'Mark Picked Up' : 'Move to $s'),
              style: ElevatedButton.styleFrom(backgroundColor: STATUS_COLORS[s], foregroundColor: Colors.white),
              onPressed: () async { await onStatusChanged(s); if (context.mounted) Navigator.pop(context); },
            )).toList()),
          ],
          if (prevStatuses.isNotEmpty) ...[const SizedBox(height: 12),
            const Text('Move Back', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: prevStatuses.reversed.take(1).map((s) => OutlinedButton.icon(
              icon: Icon(STATUS_ICONS[s], size: 16), label: Text('Back to $s'),
              onPressed: () async { await onStatusChanged(s); if (context.mounted) Navigator.pop(context); },
            )).toList()),
          ],
          const SizedBox(height: 32),
        ]),
      ),
    );
  }

  Widget _card(String title, List<Widget> children) => Card(
    elevation: 1, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey, letterSpacing: 0.5)),
      const SizedBox(height: 10), ...children,
    ])),
  );

  Widget _row(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16, color: Colors.grey), const SizedBox(width: 8),
      Text('$label: ', style: const TextStyle(color: Colors.grey, fontSize: 13)),
      Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
    ]),
  );

  Widget _total(String label, double amount, {bool bold = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(children: [
      Text(label, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: bold ? 16 : 14)),
      const Spacer(),
      Text('$${amount.toStringAsFixed(2)}', style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: bold ? 16 : 14)),
    ]),
  );
}
