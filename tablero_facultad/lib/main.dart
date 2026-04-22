import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  runApp(const TableroApp());
}

class TableroApp extends StatelessWidget {
  const TableroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PoliBoard',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      ),
      home: const PantallaBienvenida(),
    );
  }
}

class PantallaTablero extends StatefulWidget {
  const PantallaTablero({super.key});

  @override
  State<PantallaTablero> createState() => _PantallaTableroState();
}

class _PantallaTableroState extends State<PantallaTablero> {
  // Variables de control para la conexión Bluetooth
  BluetoothDevice? tableroDevice;
  BluetoothCharacteristic? controlCharacteristic;
  bool isConnected = false;
  bool isScanning = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  final String SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String CHARACTERISTIC_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  // Almacenamiento de puntajes principales
  int puntajeL = 0;
  int puntajeV = 0;

  // Almacenamiento de faltas y control de periodos
  int faltasL = 0;
  int faltasV = 0;
  int periodo = 1;

  // Variables para la sincronización del reloj en la app
  int minutos = 0;
  int segundos = 0;
  bool cronometroCorriendo = false;
  Timer? _timerEspejo;

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _timerEspejo?.cancel();
    super.dispose();
  }

  // --- LÓGICA BLUETOOTH ---
  void accionBotonBluetooth() {
    if (isConnected) {
      desconectarBluetooth();
    } else if (!isScanning) {
      conectarBluetooth();
    }
  }

  void desconectarBluetooth() async {
    if (tableroDevice != null) {
      try {
        if (tableroDevice!.isConnected) {
          await tableroDevice!.clearGattCache();
        }
        await tableroDevice!.disconnect();
      } catch (e) {
        print("Error al desconectar: $e");
      }

      setState(() {
        isConnected = false;
        tableroDevice = null;
        controlCharacteristic = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tablero desconectado correctamente.')),
      );
    }
  }

  void conectarBluetooth() async {
    setState(() {
      isScanning = true;
    });

    bool todosConcedidos =
        await Permission.location.isGranted &&
        await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted;

    if (!todosConcedidos) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

      if (statuses[Permission.location]!.isDenied ||
          statuses[Permission.bluetoothScan]!.isDenied ||
          statuses[Permission.bluetoothConnect]!.isDenied) {
        setState(() {
          isScanning = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Se requieren permisos de ubicación y Bluetooth para operar el tablero.')),
        );
        return;
      }
    }

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Es necesario encender el Bluetooth para continuar.')),
          );
          setState(() {
            isScanning = false;
          });
        }
        return;
      }

      await Future.delayed(const Duration(milliseconds: 500));
      if (await FlutterBluePlus.adapterState.first !=
          BluetoothAdapterState.on) {
        if (mounted) {
          setState(() {
            isScanning = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No fue posible activar el Bluetooth automáticamente. Por favor, actívelo de forma manual.')),
          );
        }
        return;
      }
    }

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      _scanSubscription?.cancel();

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          String nombreDetectado = r.device.platformName;
          if (nombreDetectado.isEmpty)
            nombreDetectado = r.advertisementData.advName;

          if (nombreDetectado == "Tablero_Cancha") {
            await FlutterBluePlus.stopScan();
            try {
              await Future.delayed(const Duration(milliseconds: 500));
              await r.device.connect(autoConnect: false, license: License.free);

              r.device.connectionState.listen((BluetoothConnectionState state) {
                if (state == BluetoothConnectionState.disconnected) {
                  if (mounted && isConnected) {
                    setState(() {
                      isConnected = false;
                      controlCharacteristic = null;
                    });
                  }
                }
              });

              setState(() {
                tableroDevice = r.device;
                isConnected = true;
                isScanning = false;
              });

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Conexión establecida con el tablero.')),
              );

              await Future.delayed(const Duration(milliseconds: 500));
              descubrirServicios(r.device);
            } catch (e) {
              if (mounted)
                setState(() {
                  isScanning = false;
                });
            }
            break;
          }
        }
      });

      Future.delayed(const Duration(milliseconds: 4500), () {
        if (mounted && !isConnected && isScanning) {
          setState(() {
            isScanning = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo encontrar ningún tablero en el área cercana.')),
          );
        }
      });
    } catch (e) {
      setState(() {
        isScanning = false;
      });
    }
  }

  void descubrirServicios(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (var service in services) {
      if (service.uuid.toString() == SERVICE_UUID) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == CHARACTERISTIC_UUID) {
            controlCharacteristic = characteristic;
          }
        }
      }
    }
  }

  void enviarComando(String comando) async {
    if (controlCharacteristic != null && isConnected) {
      await controlCharacteristic!.write(utf8.encode(comando));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La aplicación requiere conexión Bluetooth para enviar este comando.')),
      );
    }
  }

  // --- LÓGICA DEL MARCADOR ---
  void cambiarPuntajeL(int valor, String comando) {
    setState(() {
      if (puntajeL + valor >= 0) puntajeL += valor;
    });
    enviarComando(comando);
  }

  void cambiarPuntajeV(int valor, String comando) {
    setState(() {
      if (puntajeV + valor >= 0) puntajeV += valor;
    });
    enviarComando(comando);
  }

  void cambiarFaltasL(int valor, String comando) {
    setState(() {
      if (faltasL + valor >= 0 && faltasL + valor <= 9) faltasL += valor;
    });
    enviarComando(comando);
  }

  void cambiarFaltasV(int valor, String comando) {
    setState(() {
      if (faltasV + valor >= 0 && faltasV + valor <= 9) faltasV += valor;
    });
    enviarComando(comando);
  }

  void avanzarPeriodo() {
    setState(() {
      periodo++;
      if (periodo > 9) periodo = 1;
    });
    enviarComando("P+");
  }

  void reiniciarTodo() {
    _timerEspejo?.cancel();
    setState(() {
      puntajeL = 0;
      puntajeV = 0;
      faltasL = 0;
      faltasV = 0;
      periodo = 1;
      minutos = 0;
      segundos = 0;
      cronometroCorriendo = false;
    });
    enviarComando("R");
  }

  // --- LÓGICA DEL RELOJ ESPEJO ---
  void accionPlayPausa() {
    if (cronometroCorriendo) {
      // PAUSAR
      enviarComando("PAUSA");
      _timerEspejo?.cancel();
      setState(() {
        cronometroCorriendo = false;
      });
    } else {
      // PLAY
      if (minutos == 0 && segundos == 0) return; // No iniciar si está en cero

      enviarComando("PLAY");
      setState(() {
        cronometroCorriendo = true;
      });

      _timerEspejo = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          if (segundos == 0) {
            if (minutos > 0) {
              minutos--;
              segundos = 59;
            } else {
              // Fin del tiempo
              cronometroCorriendo = false;
              timer.cancel();
            }
          } else {
            segundos--;
          }
        });
      });
    }
  }

  void ajustarMinutos(int cantidad, String comando) {
    enviarComando(comando);
    setState(() {
      minutos += cantidad;
      if (minutos < 0) minutos = 0;
      if (minutos > 99) minutos = 99;
    });
  }

  void resetearReloj() {
    enviarComando("T_RESET");
    _timerEspejo?.cancel();
    setState(() {
      minutos = 0;
      segundos = 0;
      cronometroCorriendo = false;
    });
  }

  // Cuadro de diálogo para ingresar tiempo con el teclado
  void mostrarDialogoTiempo() {
    TextEditingController controlador = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF003366),
          title: const Text(
            "Fijar Minutos",
            style: TextStyle(color: Colors.white),
          ),
          content: TextField(
            controller: controlador,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.amber, fontSize: 24),
            decoration: const InputDecoration(
              hintText: "Ej. 15",
              hintStyle: TextStyle(color: Colors.white54),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancelar",
                style: TextStyle(color: Colors.white70),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              onPressed: () {
                int? valorIngresado = int.tryParse(controlador.text);
                if (valorIngresado != null &&
                    valorIngresado >= 0 &&
                    valorIngresado <= 99) {
                  enviarComando("T:$valorIngresado");
                  setState(() {
                    minutos = valorIngresado;
                    segundos = 0;
                  });
                }
                Navigator.pop(context);
              },
              child: const Text(
                "Fijar Tiempo",
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }

  // --- INTERFAZ DE USUARIO (UI) ---
  @override
  Widget build(BuildContext context) {
    // Damos formato al texto (ej. 05:09 en vez de 5:9)
    String tiempoFormateado =
        '${minutos.toString().padLeft(2, '0')}:${segundos.toString().padLeft(2, '0')}';

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildCustomHeader(),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // --- SECCIÓN DEL RELOJ ---
                      GestureDetector(
                        onTap: mostrarDialogoTiempo,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 20),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B0F19),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: cronometroCorriendo
                                  ? Colors.cyanAccent.withOpacity(0.5)
                                  : Colors.white10,
                              width: 2,
                            ),
                            boxShadow: [
                              if (cronometroCorriendo)
                                BoxShadow(
                                  color: Colors.cyanAccent.withOpacity(0.2),
                                  blurRadius: 15,
                                  spreadRadius: 2,
                                ),
                              const BoxShadow(
                                color: Colors.black54,
                                blurRadius: 10,
                                spreadRadius: -5,
                                offset: Offset(0, 5),
                              ),
                            ],
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              tiempoFormateado,
                              style: GoogleFonts.shareTechMono(
                                fontSize: 90,
                                color: Colors.cyanAccent,
                                fontWeight: FontWeight.bold,
                                shadows: [
                                  const Shadow(
                                    color: Colors.cyanAccent,
                                    blurRadius: 15,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "TOCA EL RELOJ PARA AJUSTAR MANUALMENTE",
                        style: GoogleFonts.inter(
                          color: Colors.white38,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),

                      const SizedBox(height: 25),

                      // BOTONES DE CONTROL DE TIEMPO
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _botonTiempo("-1", () => ajustarMinutos(-1, "T-")),
                          const SizedBox(width: 12),
                          _botonTiempo("+1", () => ajustarMinutos(1, "T+")),
                          const SizedBox(width: 12),
                          _botonTiempo("+5", () => ajustarMinutos(5, "T+5")),
                          const SizedBox(width: 12),
                          _botonTiempo("+10", () => ajustarMinutos(10, "T+10")),
                        ],
                      ),

                      const SizedBox(height: 25),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildBotonPrincipal(
                            cronometroCorriendo ? "PAUSA" : "PLAY",
                            cronometroCorriendo
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            cronometroCorriendo,
                            accionPlayPausa,
                          ),
                          const SizedBox(width: 20),
                          _buildBotonSecundario("RT", resetearReloj),
                        ],
                      ),

                      const SizedBox(height: 35),

                      // --- INDICADOR DE PERIODO ---
                      _buildIndicadorPeriodo(),

                      const SizedBox(height: 35),
                      const Divider(
                        color: Colors.white12,
                        height: 1,
                        indent: 40,
                        endIndent: 40,
                      ),
                      const SizedBox(height: 35),

                      // --- SECCIÓN DE MARCADOR Y FALTAS ---
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _crearContador(
                                  "Local",
                                  puntajeL,
                                  () => cambiarPuntajeL(1, "L+"),
                                  () => cambiarPuntajeL(-1, "L-"),
                                  Colors.amberAccent,
                                ),
                                _crearContador(
                                  "Visitante",
                                  puntajeV,
                                  () => cambiarPuntajeV(1, "V+"),
                                  () => cambiarPuntajeV(-1, "V-"),
                                  Colors.redAccent,
                                ),
                              ],
                            ),
                            const SizedBox(height: 15),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _crearContadorFaltas(
                                  "Faltas",
                                  faltasL,
                                  () => cambiarFaltasL(1, "FL+"),
                                  () => cambiarFaltasL(-1, "FL-"),
                                ),
                                _crearContadorFaltas(
                                  "Faltas",
                                  faltasV,
                                  () => cambiarFaltasV(1, "FV+"),
                                  () => cambiarFaltasV(-1, "FV-"),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 40),

                      // BOTÓN REINICIO TOTAL
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: const LinearGradient(
                              colors: [Color(0xFF8B0000), Color(0xFF5C0000)],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.red.withOpacity(0.2),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              minimumSize: const Size(double.infinity, 60),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            icon: const Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.white70,
                            ),
                            label: Text(
                              "REINICIAR TABLERO",
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.5,
                              ),
                            ),
                            onPressed: reiniciarTodo,
                          ),
                        ),
                      ),
                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Componentes modulares de la interfaz de usuario

  Widget _buildCustomHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            Icons.sports_basketball,
            color: Colors.cyanAccent.withOpacity(0.8),
            size: 24,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                "POLIBOARD",
                style: GoogleFonts.orbitron(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: isScanning ? null : accionBotonBluetooth,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              decoration: BoxDecoration(
                color: isConnected
                    ? Colors.green.withOpacity(0.15)
                    : isScanning
                    ? Colors.amber.withOpacity(0.15)
                    : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isConnected
                      ? Colors.greenAccent
                      : isScanning
                      ? Colors.amberAccent
                      : Colors.white24,
                  width: 1.5,
                ),
                boxShadow: isConnected
                    ? [
                        BoxShadow(
                          color: Colors.greenAccent.withOpacity(0.2),
                          blurRadius: 8,
                          spreadRadius: 0,
                        ),
                      ]
                    : isScanning
                    ? [
                        BoxShadow(
                          color: Colors.amberAccent.withOpacity(0.2),
                          blurRadius: 8,
                          spreadRadius: 0,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isScanning)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        color: Colors.amberAccent,
                        strokeWidth: 2,
                      ),
                    )
                  else
                    Icon(
                      isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                      color: isConnected ? Colors.greenAccent : Colors.white54,
                      size: 16,
                    ),
                  const SizedBox(width: 8),
                  Text(
                    isConnected
                        ? "CONECTADO"
                        : isScanning
                        ? "BUSCANDO..."
                        : "DESCONECTADO",
                    style: GoogleFonts.inter(
                      color: isConnected
                          ? Colors.greenAccent
                          : isScanning
                          ? Colors.amberAccent
                          : Colors.white54,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBotonPrincipal(
    String texto,
    IconData icono,
    bool esPausa,
    VoidCallback accion,
  ) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: LinearGradient(
          colors: esPausa
              ? [const Color(0xFFFF8F00), const Color(0xFFD84315)]
              : [const Color(0xFF00C853), const Color(0xFF00897B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: esPausa
                ? Colors.orange.withOpacity(0.3)
                : Colors.greenAccent.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
        icon: Icon(icono, color: Colors.white, size: 26),
        label: Text(
          texto,
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
        onPressed: accion,
      ),
    );
  }

  Widget _buildBotonSecundario(String texto, VoidCallback accion) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        color: const Color(0xFF1E293B),
        border: Border.all(color: Colors.white12),
      ),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
        onPressed: accion,
        child: Text(
          texto,
          style: GoogleFonts.inter(
            color: Colors.white70,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _botonTiempo(String texto, VoidCallback accion) {
    return InkWell(
      onTap: accion,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Text(
          texto,
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _crearContador(
    String titulo,
    int valor,
    VoidCallback sumar,
    VoidCallback restar,
    Color colorResaltado,
  ) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white10, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: colorResaltado.withOpacity(0.05),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              titulo.toUpperCase(),
              style: GoogleFonts.inter(
                fontSize: 15,
                color: Colors.white60,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 15),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  valor.toString(),
                  style: GoogleFonts.shareTechMono(
                    fontSize: 55,
                    color: colorResaltado,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        color: colorResaltado.withOpacity(0.6),
                        blurRadius: 15,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _botonCircular(
                  Icons.remove,
                  restar,
                  Colors.white10,
                  Colors.white60,
                ),
                _botonCircular(
                  Icons.add,
                  sumar,
                  colorResaltado.withOpacity(0.2),
                  colorResaltado,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _botonCircular(
    IconData icono,
    VoidCallback accion,
    Color bgColor,
    Color iconColor, {
    double size = 48,
    double iconSize = 28,
  }) {
    return InkWell(
      onTap: accion,
      borderRadius: BorderRadius.circular(30),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bgColor,
          border: Border.all(color: iconColor.withOpacity(0.3), width: 1.5),
        ),
        child: Icon(icono, color: iconColor, size: iconSize),
      ),
    );
  }

  Widget _buildIndicadorPeriodo() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 40),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.greenAccent.withOpacity(0.05),
            blurRadius: 15,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "PERIODO",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: Colors.white60,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                periodo.toString(),
                style: GoogleFonts.shareTechMono(
                  fontSize: 36,
                  color: Colors.greenAccent,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(
                      color: Colors.greenAccent.withOpacity(0.5),
                      blurRadius: 10,
                    ),
                  ],
                ),
              ),
            ],
          ),
          InkWell(
            onTap: avanzarPeriodo,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.greenAccent.withOpacity(0.3),
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Text(
                    "SIGUIENTE",
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: Colors.greenAccent,
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _crearContadorFaltas(
    String titulo,
    int valor,
    VoidCallback sumar,
    VoidCallback restar,
  ) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.02),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              titulo.toUpperCase(),
              style: GoogleFonts.inter(
                fontSize: 12,
                color: Colors.white54,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _botonCircular(
                  Icons.remove,
                  restar,
                  Colors.transparent,
                  Colors.white38,
                  size: 32,
                  iconSize: 18,
                ),
                Text(
                  valor.toString(),
                  style: GoogleFonts.shareTechMono(
                    fontSize: 32,
                    color: Colors.orangeAccent,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        color: Colors.orangeAccent.withOpacity(0.5),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                ),
                _botonCircular(
                  Icons.add,
                  sumar,
                  Colors.orangeAccent.withOpacity(0.1),
                  Colors.orangeAccent,
                  size: 32,
                  iconSize: 18,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class PantallaBienvenida extends StatelessWidget {
  const PantallaBienvenida({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0F172A), Color(0xFF020617)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo o Icono brillante
              Container(
                padding: const EdgeInsets.all(30),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.cyanAccent.withOpacity(0.05),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.cyanAccent.withOpacity(0.15),
                      blurRadius: 40,
                      spreadRadius: 10,
                    ),
                  ],
                  border: Border.all(
                    color: Colors.cyanAccent.withOpacity(0.3),
                    width: 2,
                  ),
                ),
                child: const Icon(
                  Icons.sports_score_rounded,
                  size: 80,
                  color: Colors.cyanAccent,
                ),
              ),
              const SizedBox(height: 40),

              // Título
              Text(
                "POLIBOARD",
                textAlign: TextAlign.center,
                style: GoogleFonts.orbitron(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.w900,
                  height: 1.2,
                  letterSpacing: 2,
                  shadows: [
                    Shadow(
                      color: Colors.cyanAccent.withOpacity(0.5),
                      blurRadius: 20,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 15),

              // Versión
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.greenAccent.withOpacity(0.3),
                  ),
                ),
                child: Text(
                  "v1.0",
                  style: GoogleFonts.shareTechMono(
                    color: Colors.greenAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ),

              const SizedBox(height: 50),

              // Créditos
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  "App desarrollada en la\nFacultad Politécnica de la UNE",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    color: Colors.white54,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                  ),
                ),
              ),

              const SizedBox(height: 60),

              // Botón Entrar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Container(
                  width: double.infinity,
                  height: 60,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF00C853), Color(0xFF00897B)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.greenAccent.withOpacity(0.4),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const PantallaTablero(),
                        ),
                      );
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          "ENTRAR",
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
