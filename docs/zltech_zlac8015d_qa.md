# ZLTECH Q&A — ZLAC8015D driver + ZLLG50ASM200-HY hub motor

Vendor answers received 2026-09-16 via the "Cheng, Rada and ZLTECH" chat
(screenshot transcribed below). These answer the question list we sent ZLTECH
about pairing the ZLLG50ASM200-HY hub motor with the ZLAC8015D dual-channel
driver.

> Note: this correspondence belongs to the hub-motor / cart-drive side project,
> not the xylosome scanner itself. It is filed here because this repo is the
> session's working repo; move it to the motion project repo (motionbox /
> motosome) if that becomes its home.

## The parameter set (ZLTECH message 1)

> For hub motor ZLLG50ASM200-HY, poles pair is 10, encoder is 1024 lines, hall
> offset is 240. Please set above parameters, click Save to EEPROM, and power
> off, then re-power on driver, run motor again. If it doesn't work, take a
> picture of the software interface for our check and take a video to show
> your wiring connection between hub motor and driver.

| Parameter    | Value      |
| ------------ | ---------- |
| Pole pairs   | 10         |
| Encoder      | 1024 lines |
| Hall offset  | 240        |

Procedure: set parameters → Save to EEPROM → power driver off and back on →
run motor again.

## Answers

**(a) Is there a parameter to invert the velocity feedback or the motor
direction on the ZLAC8015D? We found no 0x607E polarity object and nothing in
the CANopen V1.07 or RS485 V1.04 manuals.**

> No, just take reference of the motor default rotate direction, and check the
> value.

→ There is **no polarity/invert parameter**. Direction handling must be done on
our side (negate the command/feedback in software), using the motor's default
rotation direction as the reference.

**(b) Is there a firmware version that handles this motor (ZLLG50ASM200-HY)
correctly, and can it be supplied?**

> Firmware 26057 is no problem, just adjust the parameters we told you.

→ **No firmware update needed.** Firmware 26057 is declared compatible; the fix
is the parameter set above (pole pairs 10, encoder 1024 lines, hall offset
240), saved to EEPROM and power-cycled.

**(c) What does the "-HY" suffix denote, and is this motor the intended pairing
for the ZLAC8015D, or for another driver (e.g. ZLAC706)?**

> -HY means it's a customized version for one customer. You can take it as
> ZLLG50ASM200 V1.0 single shaft. It's recommended to us ZLAC8015D V4.2 as
> ZLAC706 has stopped production.

→ Treat the motor as a **standard ZLLG50ASM200 V1.0 single shaft**. The
customization is for some other customer, not a different electrical interface.
**ZLAC8015D V4.2 is the recommended driver**; ZLAC706 is discontinued.

**(d) Is there a hall/encoder self-learning procedure (host software or
register) for this driver that we should run?**

> At present we don't supply such file.

→ **No self-learning procedure exists.** Hall/encoder alignment cannot be
auto-calibrated; correct behavior depends entirely on wiring order and the
parameter set from (b).

## Takeaways / next steps

1. Apply the parameter set (pole pairs 10, encoder 1024 lines, hall offset
   240), save to EEPROM, power-cycle, retest.
2. If direction is wrong, invert in our host software — the driver cannot.
3. If the retest still fails, capture the tuning-software screen and a wiring
   video for ZLTECH.
4. Motor is electrically a stock ZLLG50ASM200 V1.0 single shaft — use the
   standard ZLLG50ASM200 datasheet/wiring, on ZLAC8015D V4.2.
