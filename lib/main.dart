import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';

const String API_BASE = 'https://www.printellijay.net/api/orders';
const String APP_SECRET = 'ellijay2026';

final FlutterLocalNotificationsPlugin notificationsPlugin = FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final bgNotifications = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await bgNotifications.initialize(const InitializationSettings(android: androidInit));
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) { service.setAsForegroundService(); });
    service.on('setAsBackground').listen((event) { service.setAsBackgroundService(); });
  }
  service.on('stopService').listen((event) { service.stopSelf(); });
  await _checkNewOrdersBg(bgNotifications);
  Timer.periodic(const Duration(seconds: 60), (timer) async {
    await _checkNewOrdersBg(bgNotifications);
  });
}

Future<void> _checkNewOrdersBg(FlutterLocalNotificationsPlugin plugin) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final resp = await http.get(Uri.parse(API_BASE), headers: {'x-app-secret': APP_SECRET})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return;
    final List<dynamic> orders = json.decode(resp.body);
    final List<String> known = prefs.getStringList('known_order_ids') ?? [];
    final List<String> newKnown = List.from(known);
    int newCount = 0;
    String lastOrderNum = '';
    for (final o in orders) {
      final String id = o['id']?.toString() ?? '';
      if (id.isNotEmpty && !known.contains(id)) {
        newCount++;
        lastOrderNum = o['orderNumber']?.toString() ?? id;
        newKnown.add(id);
      }
    }
    if (newCount > 0) {
      await prefs.setStringList('known_order_ids', newKnown);
      final String title = newCount == 1 ? 'New Order #${lastOrderNum}' : '${newCount} New Orders';
      await plugin.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        'Tap to view in Print Ellijay',
        const NotificationDetails(android: AndroidNotificationDetails(
          'new_orders', 'New Orders',
          channelDescription: 'Alerts for new print orders',
          importance: Importance.max, priority: Priority.high,
          playSound: true, enableVibration: true,
          icon: '@mipmap/ic_launcher',
        )),
      );
    }
  } catch (_) {}
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart, autoStart: true, isForegroundMode: false,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
  service.startService();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await notificationsPlugin.initialize(const InitializationSettings(android: androidInit));
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'new_orders', 'New Orders',
    description: 'Alerts for new print orders',
    importance: Importance.max, playSound: true, enableVibration: true,
  );
  await notificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
  await initializeBackgroundService();
  runApp(const PrintEllijayApp());
}

class PrintEllijayApp extends StatelessWidget {
  const PrintEllijayApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Print Ellijay', debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple), useMaterial3: true),
      home: const OrdersScreen(),
    );
  }
}

class PrintItem {
  final String size, colorMode, instructions;
  final int pages;
  final double price;
  PrintItem({required this.size, required this.colorMode, required this.pages, required this.price, required this.instructions});
  factory PrintItem.fromJson(Map<String, dynamic> j) => PrintItem(
    size: j['size'] ?? '', colorMode: j['colorMode'] ?? '', pages: j['pages'] ?? 1,
    price: (j['lineSubtotal'] ?? 0).toDouble(), instructions: j['instructions'] ?? '');
}

class Order {
  final String id, name, email, notes;
  final int orderNumber;
  final List<PrintItem> items;
  final double subtotal, tax, total;
  final DateTime createdAt;
  String status;
  Order({required this.id, required this.name, required this.email, required this.notes,
    required this.orderNumber, required this.items, required this.subtotal,
    required this.tax, required this.total, required this.createdAt, required this.status});
  factory Order.fromJson(Map<String, dynamic> j) => Order(
    id: j['id'] ?? '', name: j['name'] ?? '', email: j['email'] ?? '', notes: j['notes'] ?? '',
    orderNumber: j['orderNumber'] ?? 0,
    items: (j['lineItems'] as List<dynamic>? ?? []).map((i) => PrintItem.fromJson(i as Map<String, dynamic>)).toList(),
    subtotal: (j['subtotal'] ?? 0).toDouble(), tax: (j['tax'] ?? 0).toDouble(), total: (j['total'] ?? 0).toDouble(),
    createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(), status: j['status'] ?? 'New');
}

const List<String> kStatuses = ['New', 'Review', 'Printed', 'Paid', 'PickedUp'];

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<Order> _orders = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;
  @override
  void initState() { super.initState(); _fetchOrders(); _timer = Timer.periodic(const Duration(seconds: 60), (_) => _fetchOrders()); }
  @override
  void dispose() { _timer?.cancel(); super.dispose(); }
  Future<void> _fetchOrders() async {
    try {
      final resp = await http.get(Uri.parse(API_BASE), headers: {'x-app-secret': APP_SECRET}).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final List<dynamic> data = json.decode(resp.body);
        final List<Order> fetched = data.map((j) => Order.fromJson(j as Map<String, dynamic>)).toList();
        fetched.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        if (mounted) setState(() { _orders = fetched; _loading = false; _error = null; });
      } else {
        if (mounted) setState(() { _error = 'Server error ${resp.statusCode}'; _loading = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'Could not connect: ${e}'; _loading = false; });
    }
  }
  Future<void> _updateStatus(Order order, String newStatus) async {
    try {
      await http.patch(Uri.parse('${API_BASE}/${order.id}'),
        headers: {'x-app-secret': APP_SECRET, 'Content-Type': 'application/json'},
        body: json.encode({'status': newStatus}));
      setState(() { order.status = newStatus; if (newStatus == 'PickedUp') _orders.remove(order); });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update failed: ${e}')));
    }
  }
  Color _statusColor(String s) {
    switch (s) {
      case 'New': return Colors.blue;
      case 'Review': return Colors.orange;
      case 'Printed': return Colors.green;
      case 'Paid': return Colors.teal;
      default: return Colors.grey;
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Print Ellijay Orders'),
        backgroundColor: Colors.deepPurple, foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.refresh),
          onPressed: () { setState(() { _loading = true; }); _fetchOrders(); })],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator())
          : _error != null ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red))),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: () { setState(() { _loading = true; }); _fetchOrders(); }, child: const Text('Retry')),
            ]))
          : _orders.isEmpty ? const Center(child: Text('No active orders', style: TextStyle(fontSize: 18)))
          : RefreshIndicator(
              onRefresh: _fetchOrders,
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _orders.length,
                itemBuilder: (ctx, i) => _OrderTile(
                  order: _orders[i], statusColor: _statusColor(_orders[i].status), onUpdateStatus: _updateStatus),
              )),
    );
  }
}

class _OrderTile extends StatelessWidget {
  final Order order;
  final Color statusColor;
  final Future<void> Function(Order, String) onUpdateStatus;
  const _OrderTile({required this.order, required this.statusColor, required this.onUpdateStatus});
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10), elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(width: 10, height: 60,
              decoration: BoxDecoration(color: statusColor, borderRadius: BorderRadius.circular(5))),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Order #${order.orderNumber}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              Text(order.name, style: const TextStyle(fontSize: 14)),
              Text('${order.items.length} item${order.items.length == 1 ? \"\" : \"s\"} \u00b7 \$${order.total.toStringAsFixed(2)}',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ])),
            Chip(label: Text(order.status, style: const TextStyle(color: Colors.white, fontSize: 11)),
              backgroundColor: statusColor, padding: EdgeInsets.zero),
          ]),
        ),
      ),
    );
  }
  void _showDetail(BuildContext context) {
    showModalBottomSheet(context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _OrderDetail(order: order, onUpdateStatus: onUpdateStatus));
  }
}

class _OrderDetail extends StatefulWidget {
  final Order order;
  final Future<void> Function(Order, String) onUpdateStatus;
  const _OrderDetail({required this.order, required this.onUpdateStatus});
  @override
  State<_OrderDetail> createState() => _OrderDetailState();
}

class _OrderDetailState extends State<_OrderDetail> {
  bool _updating = false;
  Future<void> _changeStatus(String s) async {
    setState(() => _updating = true);
    await widget.onUpdateStatus(widget.order, s);
    setState(() => _updating = false);
    if (mounted && s == 'PickedUp') Navigator.pop(context);
  }
  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final fmt = DateFormat('MMM d, y \u00b7 h:mm a');
    return DraggableScrollableSheet(
      expand: false, initialChildSize: 0.7, maxChildSize: 0.95,
      builder: (_, ctrl) => SingleChildScrollView(
        controller: ctrl,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 40, height: 4,
            decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Order #${o.orderNumber}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
            Text(fmt.format(o.createdAt), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ]),
          const SizedBox(height: 4),
          Text(o.name, style: const TextStyle(fontSize: 16)),
          Text(o.email, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          const Divider(height: 24),
          const Text('Items', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 8),
          ...o.items.map((p) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('${p.size} \u00b7 ${p.colorMode}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('\$${p.price.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
                Text('${p.pages} page${p.pages == 1 ? \"\" : \"s\"}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                if (p.instructions.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 4),
                    child: Text('Notes: ${p.instructions}', style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic))),
              ]),
            ),
          )),
          if (o.notes.isNotEmpty) ...[
            const Divider(height: 20),
            const Text('Order Notes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 4),
            Text(o.notes, style: const TextStyle(fontSize: 13)),
          ],
          const Divider(height: 24),
          _TotalRow('Subtotal', o.subtotal, bold: false),
          _TotalRow('Tax', o.tax, bold: false),
          _TotalRow('Total', o.total, bold: true),
          const SizedBox(height: 20),
          const Text('Update Status', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 10),
          if (_updating) const Center(child: CircularProgressIndicator())
          else Wrap(spacing: 8, runSpacing: 8,
            children: kStatuses.map((s) {
              final bool isCurrent = o.status == s;
              return ElevatedButton(
                onPressed: isCurrent ? null : () => _changeStatus(s),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isCurrent ? Colors.deepPurple : Colors.grey[200],
                  foregroundColor: isCurrent ? Colors.white : Colors.black87),
                child: Text(s == 'PickedUp' ? 'Picked Up' : s));
            }).toList()),
        ]),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  final String label;
  final double amount;
  final bool bold;
  const _TotalRow(this.label, this.amount, {required this.bold});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: bold ? 16 : 14)),
        Text('\$${amount.toStringAsFixed(2)}', style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: bold ? 16 : 14)),
      ]),
    );
  }
}
