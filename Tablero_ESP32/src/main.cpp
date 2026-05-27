#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <FastLED.h>

// Definición de pines y configuraciones físicas del hardware
#define PIN_CRONOMETRO 5
#define PIN_PUNTAJE_LOCAL 13
#define PIN_PUNTAJE_VISITANTE 14
#define PIN_FALTAS_LOCAL 18
#define PIN_FALTAS_VISITANTE 19
#define PIN_PERIODO 21

#define NUM_DIGITOS_CRONOMETRO 4
#define NUM_DIGITOS_PUNTAJE 3
#define NUM_DIGITOS_CONTADORES 1

#define LEDS_POR_DIGITO 35
#define NUM_LEDS_CRONOMETRO (NUM_DIGITOS_CRONOMETRO * LEDS_POR_DIGITO)
#define NUM_LEDS_PUNTAJE (NUM_DIGITOS_PUNTAJE * LEDS_POR_DIGITO)
#define NUM_LEDS_CONTADORES (NUM_DIGITOS_CONTADORES * LEDS_POR_DIGITO)

// SOLUCIÓN 1: Nivel de brillo aumentado para la cancha (máximo 255)
#define BRIGHTNESS 200

// Arreglos de memoria para controlar cada segmento LED individualmente
CRGB leds_cronometro[NUM_LEDS_CRONOMETRO];
CRGB leds_puntaje_L[NUM_LEDS_PUNTAJE];
CRGB leds_puntaje_V[NUM_LEDS_PUNTAJE];
CRGB leds_faltas_L[NUM_LEDS_CONTADORES];
CRGB leds_faltas_V[NUM_LEDS_CONTADORES];
CRGB leds_periodo[NUM_LEDS_CONTADORES];

// Variables de estado del marcador y el partido
int golesLocal = 0;
int golesVisitante = 0;
int faltasLocal = 0;
int faltasVisitante = 0;
int periodo = 1;

int minutos = 0;
int segundos = 0;
bool cronometroCorriendo = false;
unsigned long tiempoAnterior = 0;

// SOLUCIÓN 2: Variables para el parpadeo del reloj en pausa
unsigned long tiempoUltimoParpadeo = 0;
bool estadoLedsReloj = true;

// Representación binaria de los números del 0 al 9 para displays de 7 segmentos
const byte digitos[10] = {
    0b00111111, // 0
    0b00000110, // 1
    0b01011011, // 2
    0b01001111, // 3
    0b01100110, // 4
    0b01101101, // 5
    0b01111101, // 6
    0b00000111, // 7
    0b01111111, // 8
    0b01101111  // 9
};

// Asignación de los índices de los LEDs físicos a cada segmento (A-G)
const uint8_t SEGMENTOS_LEDS[7][5] = {
    {5, 6, 7, 8, 9},      // A
    {0, 1, 2, 3, 4},      // B
    {20, 21, 22, 23, 24}, // C
    {25, 26, 27, 28, 29}, // D
    {30, 31, 32, 33, 34}, // E
    {10, 11, 12, 13, 14}, // F
    {15, 16, 17, 18, 19}  // G
};

// Funciones de renderizado para traducir números a señales de luz
void dibujarDigito(CRGB *tiraLeds, int posicionDigito, int numero, CRGB color) {
  int offsetLED = posicionDigito * LEDS_POR_DIGITO;
  byte mapaSegmentos = digitos[numero];

  for (int segmento = 0; segmento < 7; segmento++) {
    bool encender = bitRead(mapaSegmentos, segmento);

    for (int i = 0; i < 5; i++) {
      int indiceFisico = offsetLED + SEGMENTOS_LEDS[segmento][i];
      tiraLeds[indiceFisico] = encender ? color : CRGB::Black;
    }
  }
}

void actualizarMarcador() {
  // Limpiamos los colores de los arreglos específicos (Evita borrar el reloj cuando parpadea)
  fill_solid(leds_puntaje_L, NUM_LEDS_PUNTAJE, CRGB::Black);
  fill_solid(leds_puntaje_V, NUM_LEDS_PUNTAJE, CRGB::Black);
  fill_solid(leds_faltas_L, NUM_LEDS_CONTADORES, CRGB::Black);
  fill_solid(leds_faltas_V, NUM_LEDS_CONTADORES, CRGB::Black);
  fill_solid(leds_periodo, NUM_LEDS_CONTADORES, CRGB::Black);

  // SOLUCIÓN 3: Lógica de 3 dígitos (Centenas, Decenas, Unidades) para Local
  if (golesLocal >= 100) dibujarDigito(leds_puntaje_L, 2, golesLocal / 100, CRGB::Yellow);
  if (golesLocal >= 10)  dibujarDigito(leds_puntaje_L, 1, (golesLocal / 10) % 10, CRGB::Yellow);
  dibujarDigito(leds_puntaje_L, 0, golesLocal % 10, CRGB::Yellow);

  // SOLUCIÓN 3: Lógica de 3 dígitos (Centenas, Decenas, Unidades) para Visitante
  if (golesVisitante >= 100) dibujarDigito(leds_puntaje_V, 2, golesVisitante / 100, CRGB::Red);
  if (golesVisitante >= 10)  dibujarDigito(leds_puntaje_V, 1, (golesVisitante / 10) % 10, CRGB::Red);
  dibujarDigito(leds_puntaje_V, 0, golesVisitante % 10, CRGB::Red);

  dibujarDigito(leds_periodo, 0, periodo % 10, CRGB::Green);
  dibujarDigito(leds_faltas_L, 0, faltasLocal % 10, CRGB::Orange);
  dibujarDigito(leds_faltas_V, 0, faltasVisitante % 10, CRGB::Orange);

  FastLED.show();
}

void actualizarRelojFisico() {
  fill_solid(leds_cronometro, NUM_LEDS_CRONOMETRO, CRGB::Black); // Limpiamos solo el reloj
  
  dibujarDigito(leds_cronometro, 3, (minutos / 10) % 10, CRGB::Cyan);
  dibujarDigito(leds_cronometro, 2, minutos % 10, CRGB::Cyan);
  dibujarDigito(leds_cronometro, 1, (segundos / 10) % 10, CRGB::Cyan);
  dibujarDigito(leds_cronometro, 0, segundos % 10, CRGB::Cyan);
  
  FastLED.show();
}

// Configuración y callbacks del servidor Bluetooth Low Energy (BLE)
#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLEServer *pServer = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

class MisCallbacksServidor : public BLEServerCallbacks {
  void onConnect(BLEServer *pServer) { deviceConnected = true; };
  void onDisconnect(BLEServer *pServer) { deviceConnected = false; }
};

class MisCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String valor = pCharacteristic->getValue().c_str();

    if (valor.length() > 0) {
      if (valor == "L+") golesLocal++;
      else if (valor == "L-") { if (golesLocal > 0) golesLocal--; }
      else if (valor == "V+") golesVisitante++;
      else if (valor == "V-") { if (golesVisitante > 0) golesVisitante--; }
      else if (valor == "FL+") { if (faltasLocal < 9) faltasLocal++; }
      else if (valor == "FL-") { if (faltasLocal > 0) faltasLocal--; }
      else if (valor == "FV+") { if (faltasVisitante < 9) faltasVisitante++; }
      else if (valor == "FV-") { if (faltasVisitante > 0) faltasVisitante--; }
      else if (valor == "P+") {
        periodo++;
        if (periodo > 9) periodo = 1;
      }

      else if (valor == "T+") {
        minutos++;
        if (minutos > 99) minutos = 99;
        estadoLedsReloj = true;
        actualizarRelojFisico();
      } else if (valor == "T-") {
        minutos--;
        if (minutos < 0) minutos = 0;
        estadoLedsReloj = true;
        actualizarRelojFisico();
      } else if (valor == "T+5") {
        minutos += 5;
        if (minutos > 99) minutos = 99;
        estadoLedsReloj = true;
        actualizarRelojFisico();
      } else if (valor == "T+10") {
        minutos += 10;
        if (minutos > 99) minutos = 99;
        estadoLedsReloj = true;
        actualizarRelojFisico();
      } else if (valor.startsWith("T:")) {
        minutos = valor.substring(2).toInt();
        if (minutos >= 0 && minutos <= 99) {
          segundos = 0;
          estadoLedsReloj = true;
          actualizarRelojFisico();
        }
      } else if (valor == "T_RESET") {
        minutos = 0;
        segundos = 0;
        cronometroCorriendo = false;
        estadoLedsReloj = true;
        actualizarRelojFisico();
      } else if (valor == "PLAY") {
        cronometroCorriendo = true;
        estadoLedsReloj = true;
      } else if (valor == "PAUSA") {
        cronometroCorriendo = false;
      }

      else if (valor == "R") {
        golesLocal = golesVisitante = faltasLocal = faltasVisitante = minutos = segundos = 0;
        periodo = 1;
        cronometroCorriendo = false;
        estadoLedsReloj = true;
        actualizarRelojFisico();
      }
      
      // Actualiza los puntajes sin borrar el reloj
      actualizarMarcador(); 
    }
  }
};

void setup() {
  Serial.begin(115200);

  // Inicialización de las tiras de LEDs en la librería FastLED
  FastLED.addLeds<WS2813, PIN_CRONOMETRO, GRB>(leds_cronometro, NUM_LEDS_CRONOMETRO);
  FastLED.addLeds<WS2813, PIN_PUNTAJE_LOCAL, GRB>(leds_puntaje_L, NUM_LEDS_PUNTAJE);
  FastLED.addLeds<WS2813, PIN_PUNTAJE_VISITANTE, GRB>(leds_puntaje_V, NUM_LEDS_PUNTAJE);
  FastLED.addLeds<WS2813, PIN_FALTAS_LOCAL, GRB>(leds_faltas_L, NUM_LEDS_CONTADORES);
  FastLED.addLeds<WS2813, PIN_FALTAS_VISITANTE, GRB>(leds_faltas_V, NUM_LEDS_CONTADORES);
  FastLED.addLeds<WS2813, PIN_PERIODO, GRB>(leds_periodo, NUM_LEDS_CONTADORES);
  
  FastLED.setBrightness(BRIGHTNESS);

  actualizarMarcador();
  actualizarRelojFisico();

  // Inicialización del módulo Bluetooth y configuración de características
  BLEDevice::init("Tablero_Cancha");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MisCallbacksServidor());
  BLEService *pService = pServer->createService(SERVICE_UUID);
  BLECharacteristic *pCharacteristic = pService->createCharacteristic(
      CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_WRITE);
  pCharacteristic->setCallbacks(new MisCallbacks());
  pService->start();
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  BLEDevice::startAdvertising();
}

void loop() {
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }

  // Lógica de actualización del cronómetro y parpadeo
  if (cronometroCorriendo) {
    estadoLedsReloj = true; // Asegura que esté encendido mientras corre
    unsigned long tiempoActual = millis();
    
    if (tiempoActual - tiempoAnterior >= 1000) {
      tiempoAnterior = tiempoActual;

      if (segundos == 0) {
        if (minutos > 0) {
          minutos--;
          segundos = 59;
        } else {
          // Efecto visual de parpadeo rojo al finalizar el tiempo del cronómetro
          cronometroCorriendo = false;
          for (int i = 0; i < 3; i++) {
            fill_solid(leds_cronometro, NUM_LEDS_CRONOMETRO, CRGB::Black);
            dibujarDigito(leds_cronometro, 0, 0, CRGB::Red);
            dibujarDigito(leds_cronometro, 1, 0, CRGB::Red);
            dibujarDigito(leds_cronometro, 2, 0, CRGB::Red);
            dibujarDigito(leds_cronometro, 3, 0, CRGB::Red);
            FastLED.show();
            delay(400);
            
            fill_solid(leds_cronometro, NUM_LEDS_CRONOMETRO, CRGB::Black);
            FastLED.show();
            delay(400);
          }
          actualizarMarcador(); 
          actualizarRelojFisico(); 
        }
      } else {
        segundos--;
      }
      actualizarRelojFisico();
    }
  } else {
    // SOLUCIÓN 2: Lógica de parpadeo en Pausa
    if (minutos > 0 || segundos > 0) {
      if (millis() - tiempoUltimoParpadeo >= 500) {
        tiempoUltimoParpadeo = millis();
        estadoLedsReloj = !estadoLedsReloj; // Invierte el estado (Encendido/Apagado)

        if (estadoLedsReloj) {
          actualizarRelojFisico(); // Muestra los números
        } else {
          fill_solid(leds_cronometro, NUM_LEDS_CRONOMETRO, CRGB::Black); // Pinta de negro solo el reloj
          FastLED.show();
        }
      }
    } else {
      // Si el reloj está en 00:00 y no corre, lo mantenemos encendido fijo
      if (!estadoLedsReloj) {
        estadoLedsReloj = true;
        actualizarRelojFisico();
      }
    }
  }
  
  delay(10);
}