# ClearCore Firmware

Motion control and camera timing firmware for the **Teknik ClearCore** controller in the Xylosome main box.

## Responsibilities

- Drive **Panasonic servo** axis
- Drive **NEMA 17 stepper** axis
- Coordinate motion timing with the **line scanner camera** (trigger I/O)
- Accept motion commands from the Raspberry Pi over **TCP/Ethernet**
- Report position, velocity, and status back to the Pi

## Communication

The ClearCore accepts commands from the Pi over TCP on the local Ethernet network (CAT6 STP, shared with PoE).  
Protocol to be defined when Pi ↔ ClearCore interface is developed.

## Status

Stub — firmware to be written.
