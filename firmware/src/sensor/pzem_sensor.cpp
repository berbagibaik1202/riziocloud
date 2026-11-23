#include "runtime.h"

#ifdef ESP32
#include <HardwareSerial.h>
static HardwareSerial *pzemSerial = nullptr;
#else
#include <SoftwareSerial.h>
static SoftwareSerial *pzemSerial = nullptr;
#endif

static int pzemRxPin = -1;
static int pzemTxPin = -1;
static float voltageV = NAN;
static float currentA = NAN;
static float powerW = NAN;
static float energyKwh = NAN;
static float frequencyHz = NAN;
static float powerFactor = NAN;
static uint32_t lastPzemRead = 0;

static uint16_t calculateCrc(const uint8_t *buf, size_t len) {
  uint16_t crc = 0xFFFF;
  for (size_t pos = 0; pos < len; pos++) {
    crc ^= (uint16_t)buf[pos];
    for (int i = 8; i != 0; i--) {
      if ((crc & 0x0001) != 0) {
        crc >>= 1;
        crc ^= 0xA001;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc;
}

void beginPowerSensor() {
  pzemRxPin = identity["pzem_rx_pin"] | -1;
  pzemTxPin = identity["pzem_tx_pin"] | -1;

  if (pzemRxPin < 0 || pzemTxPin < 0 || pzemRxPin == pzemTxPin) {
    Serial.println(F("[PZEM] Disabled: pzem_rx_pin and pzem_tx_pin not set or identical."));
    return;
  }

  // Check pin conflicts with reset button
  int resetPin = identity["reset_pin"] | 0;
  if (pzemRxPin == resetPin || pzemTxPin == resetPin) {
    Serial.println(F("[PZEM] Disabled: conflict with reset_pin."));
    pzemRxPin = -1;
    pzemTxPin = -1;
    return;
  }

#ifdef ESP32
  pzemSerial = new HardwareSerial(2);
  pzemSerial->begin(9600, SERIAL_8N1, pzemRxPin, pzemTxPin);
  Serial.printf("[PZEM] ESP32 HardwareSerial(2) ready on RX=%d, TX=%d\n", pzemRxPin, pzemTxPin);
#else
  pzemSerial = new SoftwareSerial(pzemRxPin, pzemTxPin);
  pzemSerial->begin(9600);
  Serial.printf("[PZEM] ESP8266 SoftwareSerial ready on RX=%d, TX=%d\n", pzemRxPin, pzemTxPin);
#endif
}

void tickPowerSensor() {
  if (!pzemSerial || millis() - lastPzemRead < 2500) return;
  lastPzemRead = millis();

  // Flush any lingering RX bytes
  while (pzemSerial->available()) {
    pzemSerial->read();
  }

  // Modbus-RTU command: Read 10 Input Registers starting from 0x0000
  // [Slave=0x01, Func=0x04, Start=0x0000, Count=0x000A, CRC=0x70 0x0D]
  static const uint8_t queryCmd[8] = {0x01, 0x04, 0x00, 0x00, 0x00, 0x0A, 0x70, 0x0D};
  pzemSerial->write(queryCmd, 8);

  // Response is 25 bytes: Addr(1) + Func(1) + ByteCount(1) + Data(20) + CRC(2)
  uint8_t response[25];
  size_t bytesRead = 0;
  uint32_t startWait = millis();

  while (bytesRead < 25 && (millis() - startWait) < 200) {
    if (pzemSerial->available()) {
      response[bytesRead++] = (uint8_t)pzemSerial->read();
    } else {
      delay(2);
    }
  }

  if (bytesRead < 25) {
    // Timeout or PZEM not connected / no AC power
    return;
  }

  // Validate Modbus header
  if (response[0] != 0x01 || response[1] != 0x04 || response[2] != 0x14) {
    return;
  }

  // Validate CRC16
  uint16_t expectedCrc = (uint16_t)response[23] | ((uint16_t)response[24] << 8);
  uint16_t actualCrc = calculateCrc(response, 23);
  if (expectedCrc != actualCrc) {
    return;
  }

  // Parse Voltage (0.1V)
  uint16_t rawVoltage = ((uint16_t)response[3] << 8) | response[4];
  voltageV = rawVoltage * 0.1f;

  // Parse Current (0.001A, 32-bit: Low word first, High word second)
  uint32_t rawCurrent = (((uint32_t)response[7] << 8) | response[8]) << 16 |
                        (((uint32_t)response[5] << 8) | response[6]);
  currentA = rawCurrent * 0.001f;

  // Parse Power (0.1W, 32-bit: Low word first, High word second)
  uint32_t rawPower = (((uint32_t)response[11] << 8) | response[12]) << 16 |
                      (((uint32_t)response[9] << 8) | response[10]);
  powerW = rawPower * 0.1f;

  // Parse Energy (1Wh, 32-bit: Low word first, High word second) -> converted to kWh
  uint32_t rawEnergy = (((uint32_t)response[15] << 8) | response[16]) << 16 |
                       (((uint32_t)response[13] << 8) | response[14]);
  energyKwh = rawEnergy * 0.001f;

  // Parse Frequency (0.1Hz)
  uint16_t rawFreq = ((uint16_t)response[17] << 8) | response[18];
  frequencyHz = rawFreq * 0.1f;

  // Parse Power Factor (0.01)
  uint16_t rawPf = ((uint16_t)response[19] << 8) | response[20];
  powerFactor = rawPf * 0.01f;
}

void addPowerSensorState(JsonObject state) {
  if (!pzemSerial || isnan(voltageV)) return;
  state["voltage_v"] = voltageV;
  state["current_a"] = currentA;
  state["power_w"] = powerW;
  state["energy_kwh"] = energyKwh;
  state["frequency_hz"] = frequencyHz;
  state["power_factor"] = powerFactor;
}
