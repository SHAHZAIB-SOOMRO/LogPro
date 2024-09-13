import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'app_config.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  await initializeNotificationService();
  runApp(const MyApp());
}
Future<void> initializeNotificationService() async {
  await _initializeNotifications();
  await _requestPermissions();
}
Future<void> _initializeNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
}
Future<void> _requestPermissions() async {
  if (!await Permission.notification.isGranted) {
    await Permission.notification.request();
  }
}
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: false,
    ),
    iosConfiguration: IosConfiguration(
      onForeground: onStart,
      autoStart: true,
    ),
  );

  service.startService();
}
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  SharedPreferences prefs = await SharedPreferences.getInstance();
  // Reload thresholds every 10 seconds
  Timer.periodic(const Duration(seconds: 10), (timer) async {
    await ThresholdManager().loadThresholds();
  });

  Timer.periodic(const Duration(seconds: 10), (timer) async { // Check for new thresholds every 30 seconds
    await fetchAndNotify(prefs);
  });
}
Future<void> fetchAndNotify(SharedPreferences prefs) async {
  // Update thresholds before fetching readings
  await ThresholdManager().loadThresholds();

  // Get device tokens and locations
  final deviceTokens = prefs.getStringList('deviceTokens');
  final locations = prefs.getStringList('locations');

  // Check for null values
  if (deviceTokens == null || locations == null) {
    print("Device tokens or locations are null");
    return;
  }

  // Create a map to store device token-location pairs
  final deviceLocations = {};
  for (int i = 0; i < deviceTokens.length; i++) {
    deviceLocations[deviceTokens[i]] = locations[i];
  }

  // Fetch latest readings for each device
  final currentReadings = {};
  for (var deviceToken in deviceTokens) {
    try {
      final response = await http.get(
        Uri.parse(AppConfig.apiUrl),
        headers: {'device-token': deviceToken},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final latestReadings = _parseLatestReadings(data);

        currentReadings[deviceToken] = {
          'temperature': latestReadings['wifia1va'],
          'co2': latestReadings['wifia2va'],
          'location': deviceLocations[deviceToken],
        };
      } else {
        print("Failed to fetch data for device $deviceToken");
      }
    } catch (e) {
      print("Error fetching data for device $deviceToken: $e");
    }
  }

  // Get thresholds
  final thresholdsString = prefs.getString('thresholds');
  Map<String, Map<String, double>> thresholds = {};

  if (thresholdsString != null) {
    final decodedThresholds = jsonDecode(thresholdsString);

    thresholds = Map.from(decodedThresholds).map((key, value) {
      return MapEntry(
        key.toString(),
        Map.from(value).map((innerKey, innerValue) => MapEntry(innerKey.toString(), innerValue.toDouble())),
      );
    });
  }



  // Check thresholds and notify
  for (var deviceToken in currentReadings.keys) {
    final readings = currentReadings[deviceToken];
    final temperature = readings['temperature'];
    final co2 = readings['co2'];
    final location = readings['location'];

    await checkAndNotify(deviceToken, double.tryParse(temperature?.toString() ?? ''), double.tryParse(co2?.toString() ?? ''), location, thresholds);
  }
}
Map<String, dynamic> _parseLatestReadings(Map<String, dynamic> data) {
  final requiredVariables = ['wifia1va', 'wifia2va'];
  final timeGroups = {};

  for (var record in data['result']) {
    timeGroups.putIfAbsent(record['time'], () => []).add(record);
  }

  final latestGroup = timeGroups.entries
      .where((entry) => requiredVariables.toSet().difference(entry.value.map((r) => r['variable']).toSet()).isEmpty)
      .toList()
    ..sort((a, b) => b.key.compareTo(a.key));

  final result = {};

  for (var record in latestGroup.first.value) {
    if (requiredVariables.contains(record['variable'])) {
      result[record['variable'].toString()] = record['value'].toString();
    }
  }

  return Map<String, dynamic>.from(result);

}
Future<String> getDeviceLocation(String location1) async {
  // Implement your logic to get the device location based on the token.
  // For example, it could be an API call to fetch the location.
  return " $location1"; // Placeholder
}
Future<void> checkAndNotify(String deviceToken, double? currentTemp, double? currentCO2, String location, Map<String, Map<String, double>> thresholds) async {
  final threshold = thresholds[deviceToken];
  if (threshold != null) {
    List<Future<void>> notifications = [];

    if (currentTemp != null) {
      if (currentTemp < threshold['minTemp']!) {
        notifications.add(showNotification("Temperature Alert", "$location: Temp is low!", id: deviceToken.hashCode ^ "TempLow".hashCode));
      } else if (currentTemp > threshold['maxTemp']!) {
        notifications.add(showNotification("Temperature Alert", "$location: Temp is high!", id: deviceToken.hashCode ^ "TempHigh".hashCode));
      }
    } else {
      notifications.add(showNotification("Temperature Alert", "$location: Temp value is unavailable!", id: deviceToken.hashCode ^ "TempUnavailable".hashCode));
    }

    if (currentCO2 != null) {
      if (currentCO2 < threshold['minCO2']!) {
        notifications.add(showNotification("CO2 Alert", "$location: CO2 low!", id: deviceToken.hashCode ^ "CO2Low".hashCode));
      } else if (currentCO2 > threshold['maxCO2']!) {
        notifications.add(showNotification("CO2 Alert", "$location: CO2 high!", id: deviceToken.hashCode ^ "CO2High".hashCode));
      }
    } else {
      notifications.add(showNotification("CO2 Alert", "$location: CO2 value is unavailable!", id: deviceToken.hashCode ^ "CO2Unavailable".hashCode));
    }

    for (var notification in notifications) {
      await notification;
    }
  } else {
    print("No thresholds found for device $deviceToken");
  }
}
Future<void> showNotification(String title, String body, {int id = 0}) async {
  const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
    'channel_id',
    'Temperature-Alert-TMClass',
    channelDescription: 'channel_description',
    importance: Importance.max,
    priority: Priority.high,
    showWhen: false,
  );
  const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
  await flutterLocalNotificationsPlugin.show(id, title, body, platformChannelSpecifics);
}

class ThresholdManager {
  final Map<String, Map<String, double>> thresholds = {};
  final PersistentThresholdManager persistentThresholdManager = PersistentThresholdManager();

  Future<void> loadThresholds() async {
    thresholds.clear(); // Clear existing thresholds
    thresholds.addAll(await persistentThresholdManager.loadThresholds());
  }

  Future<void> setThreshold(String deviceToken, double minTemp, double maxTemp, double minCO2, double maxCO2) async {
    thresholds[deviceToken] = {
      'minTemp': minTemp,
      'maxTemp': maxTemp,
      'minCO2': minCO2,
      'maxCO2': maxCO2,
    };
    await persistentThresholdManager.saveThresholds(thresholds);
    await loadThresholds();
    thresholds[deviceToken] = {
      'minTemp': minTemp,
      'maxTemp': maxTemp,
      'minCO2': minCO2,
      'maxCO2': maxCO2,
    };
  }

  Map<String, double>? getThresholds(String deviceToken) {
    return thresholds[deviceToken];
  }

  Future<void> checkAllDevices(Map<String, Map<String, double>> currentReadings, Map<String, String> deviceLocations) async {}
}
class PersistentThresholdManager {

  static const String _thresholdsKey = 'thresholds';

  // Save thresholds
  Future<Map<String, Map<String, double>>> saveThresholds(Map<String, Map<String, double>> thresholds) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String jsonString = jsonEncode(thresholds);
    bool success = await prefs.setString(_thresholdsKey, jsonString);
    print(jsonString);

    // Ensure that the save operation succeeded
    if (success) {
      return thresholds;
    } else {
      throw Exception('Failed to save thresholds');
    }
  }

  // Load thresholds
  Future<Map<String, Map<String, double>>> loadThresholds() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();

    // Removed reload to avoid loading old values
    String? jsonString = prefs.getString(_thresholdsKey);

    // Check if the stored value exists and is valid
    if (jsonString != null && jsonString.isNotEmpty) {
      Map<String, dynamic> jsonMap = jsonDecode(jsonString);

      // Convert the dynamic map to the required format
      return jsonMap.map((key, value) => MapEntry(key, Map<String, double>.from(value)));
    }

    // Return an empty map if no value is found
    return {};
  }
}
class ThresholdSettingsScreen extends StatefulWidget {
  final ThresholdManager thresholdManager;
  final String deviceToken;
  final String deviceLocation;
  final Function(double minTemp, double maxTemp, double minCO2, double maxCO2) onThresholdUpdated;

  const ThresholdSettingsScreen({
    super.key,
    required this.thresholdManager,
    required this.deviceToken,
    required this.deviceLocation,
    required this.onThresholdUpdated,
  });

  @override
  State<ThresholdSettingsScreen> createState() => _ThresholdSettingsScreenState();
}
class _ThresholdSettingsScreenState extends State<ThresholdSettingsScreen> {
  final TextEditingController minTempController = TextEditingController();
  final TextEditingController maxTempController = TextEditingController();
  final TextEditingController minCO2Controller = TextEditingController();
  final TextEditingController maxCO2Controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    final thresholds = widget.thresholdManager.getThresholds(widget.deviceToken);
    if (thresholds != null) {
      minTempController.text = thresholds['minTemp'].toString();
      maxTempController.text = thresholds['maxTemp'].toString();
      minCO2Controller.text = thresholds['minCO2'].toString();
      maxCO2Controller.text = thresholds['maxCO2'].toString();
    }
  }

  Future<void> saveThresholds() async {
    // Notify the threshold manager of updates
    final double minTemp = double.tryParse(minTempController.text) ?? 0;
    final double maxTemp = double.tryParse(maxTempController.text) ?? 100;
    final double minCO2 = double.tryParse(minCO2Controller.text) ?? 0;
    final double maxCO2 = double.tryParse(maxCO2Controller.text) ?? 2000;

    try {
      await widget.thresholdManager.setThreshold(widget.deviceToken, minTemp, maxTemp, minCO2, maxCO2);
      widget.onThresholdUpdated(minTemp, maxTemp, minCO2, maxCO2);
      setState(() {});
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      // Handle any errors that occur during the save process
      print('Error saving thresholds: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save thresholds. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set Thresholds'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device: ${widget.deviceLocation} ',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            TextField(
              controller: minTempController,
              decoration: const InputDecoration(labelText: 'Minimum Temperature (°C)'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: maxTempController,
              decoration: const InputDecoration(labelText: 'Maximum Temperature (°C)'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: minCO2Controller,
              decoration: const InputDecoration(labelText: 'Minimum CO2 (ppm)'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: maxCO2Controller,
              decoration: const InputDecoration(labelText: 'Maximum CO2 (ppm)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: saveThresholds,
              child: const Text('Save Thresholds'),
            ),
          ],
        ),
      ),
    );
  }
}
class NotificationService {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    WidgetsFlutterBinding.ensureInitialized();
    await initializeNotificationService();
  }
}
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}
class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
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
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Temperature Readings',
      home: SplashScreen(),
    );
  }
}


class TemperatureReadings extends StatefulWidget {
  const TemperatureReadings({super.key});

  @override
  State<TemperatureReadings> createState() => _TemperatureReadingsState();
}
class _TemperatureReadingsState extends State<TemperatureReadings> {
  Map<String, dynamic>? latestReading;
  List<Map<String, String>> uniqueEntries = [];
  String? selectedDeviceToken;
  String? selectedLocation;
  Map<String, String> deviceStatus = {};
  Timer? refreshTimer;
  final ThresholdManager thresholdManager = ThresholdManager();
  Map<String, dynamic>? thresholds;

  @override
  void initState() {
    super.initState();
    loadDevices();
    thresholdManager.loadThresholds();

    refreshTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (mounted) {
        fetchData();
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> loadDevices() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? deviceTokens = prefs.getStringList('deviceTokens');
    List<String>? locations = prefs.getStringList('locations');

    if (deviceTokens != null && locations != null) {
      uniqueEntries.clear();
      for (int i = 0; i < deviceTokens.length; i++) {
        uniqueEntries.add({
          'token': deviceTokens[i],
          'location': locations[i],
        });
      }
      if (selectedDeviceToken == null && uniqueEntries.isNotEmpty) {
        selectedDeviceToken = uniqueEntries.first['token'];
        selectedLocation = uniqueEntries.first['location'];
      }

      if (selectedDeviceToken != null) {
        fetchData();
      }
    }
  }

  Future<void> fetchData() async {
    if (!mounted) return;
    if (selectedDeviceToken == null || selectedLocation == null) return;

    var connectivityResult = await (Connectivity().checkConnectivity());
    if (connectivityResult == ConnectivityResult.none) {
      print("No internet connection");
      setState(() {
        latestReading = {
          'time': 'N/A',
          'readings': {'status': 'No Internet Connection'},
        };
        thresholds = null;
      });
      return;
    }

    final Map<String, String> headers = {'device-token': selectedDeviceToken!};

    try {
      final response = await http.get(Uri.parse(AppConfig.apiUrl), headers: headers);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic> && data.containsKey('result')) {
          final records = data['result'];

          var timeGroups = <String, List<dynamic>>{};
          for (var record in records) {
            timeGroups.putIfAbsent(record['time'], () => []).add(record);
          }

          const requiredVariables = ['wifia1va', 'wifia2va', 'wifia3va'];
          final latestGroup = timeGroups.entries
              .where((entry) => requiredVariables.toSet().difference(entry.value.map((r) => r['variable']).toSet()).isEmpty)
              .toList()
            ..sort((a, b) => b.key.compareTo(a.key));

          if (latestGroup.isNotEmpty) {
            final latestTime = latestGroup.first.key;
            final result = <String, dynamic>{};

            for (var record in latestGroup.first.value) {
              if (requiredVariables.contains(record['variable'])) {
                result[record['variable']] = record['value'];
              }
            }

            setState(() {
              latestReading = {
                'time': latestTime,
                'readings': result,
              };
              thresholds = thresholdManager.getThresholds(selectedDeviceToken!);
            });

            final currentReadings = <String, Map<String, double>>{};
            final deviceLocations = <String, String>{};

            for (var device in uniqueEntries) {
              final deviceToken = device['token'];
              final deviceLocation = device['location'];

              final Map<String, String> headers = {'device-token': deviceToken!};

              try {
                final response = await http.get(Uri.parse(AppConfig.apiUrl), headers: headers);

                if (response.statusCode == 200) {
                  final data = jsonDecode(response.body);
                  if (data is Map<String, dynamic> && data.containsKey('result')) {
                    final records = data['result'];

                    var timeGroups = <String, List<dynamic>>{};
                    for (var record in records) {
                      timeGroups.putIfAbsent(record['time'], () => []).add(record);
                    }

                    const requiredVariables = ['wifia1va', 'wifia2va'];
                    final latestGroup = timeGroups.entries
                        .where((entry) => requiredVariables.toSet().difference(entry.value.map((r) => r['variable']).toSet()).isEmpty)
                        .toList()
                      ..sort((a, b) => b.key.compareTo(a.key));

                    if (latestGroup.isNotEmpty) {
                      final latestTime = latestGroup.first.key;
                      final result = <String, dynamic>{};

                      for (var record in latestGroup.first.value) {
                        if (requiredVariables.contains(record['variable'])) {
                          result[record['variable']] = record['value'];
                        }
                      }

                      currentReadings[deviceToken] = {
                        'temperature': (result['wifia1va'] as num).toDouble(),
                        'co2': (result['wifia2va'] as num).toDouble(),
                      };

                      deviceLocations[deviceToken] = deviceLocation!;
                    }
                  }
                }
              } catch (e) {
                print('Error fetching data for device: $deviceToken. Error: $e');
              }
            }

            await thresholdManager.checkAllDevices(currentReadings, deviceLocations);
          } else {
            setState(() {
              latestReading = {
                'time': 'N/A',
                'readings': {'status': 'Device is Offline'},
              };
              thresholds = null;
            });
          }
        } else {
          setState(() {
            latestReading = {
              'time': 'N/A',
              'readings': {'status': 'Device is Offline'},
            };
            thresholds = null;
          });
        }
      } else {
        setState(() {
          latestReading = {
            'time': 'N/A',
            'readings': {'status': 'Device is Offline'},
          };
          thresholds = null;
        });
      }
    } catch (e) {
      print('Error fetching data: $e');
      setState(() {
        latestReading = {
          'time': 'N/A',
          'readings': {'status': 'LogPro Not Connected'},
        };
      });
    }

    await checkDeviceStatus();
  }

  Future<void> checkDeviceStatus() async {
    for (var device in uniqueEntries) {
      final token = device['token'];
      final location = device['location'];

      final response = await http.get(Uri.parse(AppConfig.apiUrl), headers: {'device-token': token!});

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic> && data.containsKey('result')) {
          final records = data['result'];

          if (records.isNotEmpty) {
            final latestTimestamp = records.last['time'];
            final DateTime lastUpdateTime = DateTime.parse(latestTimestamp);
            final DateTime currentTime = DateTime.now();

            deviceStatus[token] = currentTime.difference(lastUpdateTime).inMinutes < 2
                ? "$location is Online"
                : "$location is Offline";
          } else {
            deviceStatus[token] = "$location is Offline";
          }
        } else {
          deviceStatus[token] = "$location is Offline";
        }
      }
    }
    setState(() {});
  }

  Future<void> saveDevices() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> deviceTokens = uniqueEntries.map((device) => device['token']!).toList();
    List<String> locations = uniqueEntries.map((device) => device['location']!).toList();

    await prefs.setStringList('deviceTokens', deviceTokens);
    await prefs.setStringList('locations', locations);
  }

  void clearAllData() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (context) => const OnboardingScreen(),
    ));
  }

  void deleteDevice(String token) async {
    setState(() {
      uniqueEntries.removeWhere((device) => device['token'] == token);
    });

    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? deviceTokens = prefs.getStringList('deviceTokens');
    List<String>? locations = prefs.getStringList('locations');

    if (deviceTokens != null && locations != null) {
      int index = deviceTokens.indexWhere((t) => t == token);
      if (index != -1) {
        deviceTokens.removeAt(index);
        locations.removeAt(index);
        await prefs.setStringList('deviceTokens', deviceTokens);
        await prefs.setStringList('locations', locations);
      }
    }

    if (uniqueEntries.isEmpty) {
      clearAllData();
    }
  }

  String formatTimestamp(String timestamp) {
    try {
      DateTime dateTime = DateTime.parse(timestamp).add(const Duration(hours: 5));
      return DateFormat('hh:mm a, dd MMM yyyy').format(dateTime);
    } catch (e) {
      return "No Connection/Wifi";
    }
  }

  void updateDeviceTokens() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? deviceTokens = prefs.getStringList('deviceTokens');
    if (deviceTokens != null && deviceTokens.isNotEmpty) {
      fetchData();
    }
  }

  void navigateToThresholdSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ThresholdSettingsScreen(
          thresholdManager: thresholdManager,
          deviceToken: selectedDeviceToken!,
          deviceLocation: selectedLocation!,
          onThresholdUpdated: (minTemp, maxTemp, minCO2, maxCO2) {
            thresholdManager.setThreshold(selectedDeviceToken!, minTemp, maxTemp, minCO2, maxCO2);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: SizedBox(
          height: kToolbarHeight,
          child: Image.asset(
            'assets/FATRONIC LOGO.png',
            fit: BoxFit.contain,
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (String result) {
              if (result == 'Onboarding') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const OnboardingScreen()),
                );
              } else if (result == 'Delete Devices') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AddedDevicesScreen(
                      existingDevices: uniqueEntries,
                      onDeviceDeleted: (String token) {
                        deleteDevice(token);
                      },
                    ),
                  ),
                );
              } else if (result == 'Manage Thresholds') {
                navigateToThresholdSettings();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<String>(
                value: 'Onboarding',
                child: Row(
                  children: [
                    Icon(Icons.add_box),
                    SizedBox(width: 8),
                    Text('Add Device'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'Delete Devices',
                child: Row(
                  children: [
                    Icon(Icons.delete),
                    SizedBox(width: 8),
                    Text('Delete Devices'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'Manage Thresholds',
                child: Row(
                  children: [
                    Icon(Icons.data_thresholding),
                    SizedBox(width: 8),
                    Text('Manage Thresholds'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButton<String>(
              value: selectedDeviceToken,
              hint: const Text('Select a Device'),
              items: uniqueEntries.map((device) {
                return DropdownMenuItem<String>(
                  value: device['token'],
                  child: Text('${device['location']}'),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  final selected = uniqueEntries.firstWhere((device) => device['token'] == value);
                  setState(() {
                    selectedDeviceToken = selected['token'];
                    selectedLocation = selected['location'];
                    fetchData();
                  });
                }
              },
            ),
            const SizedBox(height: 0),
            Text(
              selectedLocation != null ? 'Selected Location: $selectedLocation' : 'No location selected',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            latestReading == null
                ? const Center(child: CircularProgressIndicator())
                : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  elevation: 5,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Parameters',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Card(
                              elevation: 3,
                              margin: const EdgeInsets.only(left: 8, right: 8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                                child: Text(
                                  '${latestReading!['readings']['status'] ?? 'LogPro Connected'}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: latestReading!['readings']['status'] == 'LogPro Not Connected' ? Colors.red : Colors.green,
                                  ),
                                ),
                              ),
                            )
                          ],
                        ),
                        const SizedBox(height: 5),
                        _buildTemperatureCard('Temperature', latestReading!['readings']['wifia1va']),
                        const SizedBox(height: 5),
                        _buildCO2Card('CO2', latestReading!['readings']['wifia2va']),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Card(
                                elevation: 3,
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                child: Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Text(
                                        'Last Updated: ',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        formatTimestamp(latestReading!['time']),
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.black,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          ],
                        )
                      ],
                    ),
                  ),
                ),
                if (thresholds != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 0),
                    child: Container(
                      padding: const EdgeInsets.all(4.0),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: Colors.grey[10],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Center(
                            child: Text(
                              'Thresholds',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'MinT = ${thresholds!['minTemp'] != null ? thresholds!['minTemp'] : 'N/A'}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: thresholds!['minTemp'] != null ? Colors.black : Colors.grey,
                                ),
                              ),
                              Text(
                                'MaxT = ${thresholds!['maxTemp'] != null ? thresholds!['maxTemp'] : 'N/A'}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: thresholds!['maxTemp'] != null ? Colors.black : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'MinCO2 = ${thresholds!['minCO2'] != null ? thresholds!['minCO2'] : 'N/A'}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: thresholds!['minCO2'] != null ? Colors.black : Colors.grey,
                                ),
                              ),
                              Text(
                                'MaxCO2 = ${thresholds!['maxCO2'] != null ? thresholds!['maxCO2'] : 'N/A'}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: thresholds!['maxCO2'] != null ? Colors.black : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Card(
                      elevation: 8,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const Text(
                              'Devices Status',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            ...uniqueEntries.map((device) {
                              final token = device['token'];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 0),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      deviceStatus[token] ?? 'Status: N/A',
                                      style: TextStyle(
                                        color: deviceStatus[token] == "${device['location']} is Online" ? Colors.green : Colors.red,
                                        fontSize: 14,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTemperatureCard(String label, dynamic value) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(
              value != null ? '${value is int ? (value).toDouble() : value} °C' : 'N/A',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: value != null ? Colors.black : Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCO2Card(String label, dynamic value) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(
              value != null ? '${value is int ? (value).toDouble() : value} ppm' : 'N/A',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: value != null ? Colors.black : Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
// OnboardingScreen Class
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}
class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController tokenController = TextEditingController();
  final TextEditingController locationController = TextEditingController();

  Future<bool> validateDeviceToken(String deviceToken) async {
    try {
      final response = await http.get(Uri.parse(AppConfig.apiUrl), headers: {'device-token': deviceToken});
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  void navigateToMainScreen() async {
    final String deviceToken = tokenController.text.trim().toLowerCase();
    final String location = locationController.text;

    if (deviceToken.isNotEmpty && location.isNotEmpty) {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      List<String>? existingTokens = prefs.getStringList('deviceTokens');
      List<String>? existingLocations = prefs.getStringList('locations');

      if (existingTokens != null && existingLocations != null) {
        if (existingTokens.contains(deviceToken) && existingLocations[existingTokens.indexOf(deviceToken)] == location) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("This device token already exists with the same location.")),
          );
          return;
        } else if (existingLocations.contains(location) && existingTokens[existingLocations.indexOf(location)] != deviceToken) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("This location already exists for another device token.")),
          );
          return;
        }
      }

      existingTokens ??= [];
      existingLocations ??= [];
      existingTokens.add(deviceToken);
      existingLocations.add(location);
      await prefs.setStringList('deviceTokens', existingTokens);
      await prefs.setStringList('locations', existingLocations);
      await prefs.setString('location_$deviceToken', location);

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const TemperatureReadings(),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter both device token and location.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Setup Device'),
        backgroundColor: Colors.teal,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12.0),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 8.0,
                  spreadRadius: 2.0,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 20),
                const Icon(Icons.device_hub, size: 80, color: Colors.teal),
                const SizedBox(height: 20),
                const Text('Add Your Device', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.teal)),
                const SizedBox(height: 20),
                const Text('Please enter the device token and location below:', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.grey)),
                const SizedBox(height: 30),
                TextField(
                  controller: tokenController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Device Token',
                    labelText: 'Device Token',
                    prefixIcon: Icon(Icons.token),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: locationController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Location',
                    labelText: 'Location',
                    prefixIcon: Icon(Icons.location_on),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 30),
                ElevatedButton(
                  onPressed: navigateToMainScreen,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                    textStyle: const TextStyle(fontSize: 18),
                  ),
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
// SplashScreen Class
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}
class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 3), _navigate);
  }

  Future<void> _navigate() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? existingTokens = prefs.getStringList('deviceTokens');

    if (existingTokens == null || existingTokens.isEmpty) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const OnboardingScreen(),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const InitialScreen(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/SplashLogo.png'),
            const SizedBox(height: 20),
            const Text(
              'LogPro V1.0',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black),
            ),
          ],
        ),
      ),
    );
  }
}
// InitialScreen Class
class InitialScreen extends StatefulWidget {
  const InitialScreen({super.key});

  @override
  State<InitialScreen> createState() => _InitialScreenState();
}
class _InitialScreenState extends State<InitialScreen> {
  @override
  void initState() {
    super.initState();
    _checkForExistingDevice();
    _checkInternetConnection();
  }

  Future<void> _checkForExistingDevice() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? deviceTokens = prefs.getStringList('deviceTokens');

    if (deviceTokens != null && deviceTokens.isNotEmpty) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const TemperatureReadings(),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const OnboardingScreen(),
        ),
      );
    }
  }

  Future<void> _checkInternetConnection() async {
    var connectivityResult = await (Connectivity().checkConnectivity());
    if (connectivityResult == ConnectivityResult.none) {
      _showNoConnectionDialog();
    }
  }

  void _showNoConnectionDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("No Internet Connection"),
          content: const Text("Please check your internet connection and try again."),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text("OK"),
            )
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}
// AddedDevicesScreen Class
class AddedDevicesScreen extends StatefulWidget {
  final List<Map<String, String>> existingDevices;
  final Function(String) onDeviceDeleted;

  const AddedDevicesScreen({
    super.key,
    required this.existingDevices,
    required this.onDeviceDeleted,
  });

  @override
  _AddedDevicesScreenState createState() => _AddedDevicesScreenState();
}
class _AddedDevicesScreenState extends State<AddedDevicesScreen> {
  late List<Map<String, String>> _devices;

  @override
  void initState() {
    super.initState();
    _devices = List.from(widget.existingDevices);
  }

  void _deleteDevice(String token) {
    setState(() {
      _devices.removeWhere((device) => device['token'] == token);
    });
    widget.onDeviceDeleted(token); // Call the callback to delete the device from storage
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Delete Devices'),
      ),
      body: ListView.builder(
        itemCount: _devices.length,
        itemBuilder: (context, index) {
          final device = _devices[index];
          return Card(
            elevation: 3,
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: ListTile(
              title: Text('${device['location']}'),
              subtitle: Text('Device Token: ${device['token']}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return AlertDialog(
                        title: const Text("Confirm Delete"),
                        content: const Text("Are you sure you want to delete this device?"),
                        actions: [
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                            },
                            child: const Text("Cancel"),
                          ),
                          TextButton(
                            onPressed: () {
                              _deleteDevice(device['token']!);
                              Navigator.of(context).pop();
                            },
                            child: const Text("Delete"),
                          )
                        ],
                      );
                    },
                  );
                },
                color: Colors.red,
              ),
            ),
          );
        },
      ),
    );
  }
}